defmodule Tvplayer.Streams.Probe do
  @moduledoc """
  Per-channel ffprobe cache.

  TVHeadend channel codecs are effectively static, so we probe once and reuse
  the result to choose remux vs transcode and which filters to apply.
  """

  require Logger

  @table :tvplayer_stream_probe
  # MPEG-2 SD from TVHeadend often needs >2.5s before codec params appear.
  @probe_timeout_ms 6_000

  defmodule Result do
    @moduledoc false
    defstruct has_video?: true,
              video_codec: nil,
              pix_fmt: nil,
              width: nil,
              height: nil,
              field_order: nil,
              profile: nil,
              audio_codec: nil,
              copy_blocked?: false

    @type t :: %__MODULE__{
            has_video?: boolean(),
            video_codec: String.t() | nil,
            pix_fmt: String.t() | nil,
            width: non_neg_integer() | nil,
            height: non_neg_integer() | nil,
            field_order: String.t() | nil,
            profile: String.t() | nil,
            audio_codec: String.t() | nil,
            copy_blocked?: boolean()
          }
  end

  @doc """
  Ensures the probe ETS table exists. Safe to call multiple times.
  """
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _tid ->
        @table
    end
  end

  @doc """
  Returns a cached probe result or probes `input_url` and stores it under `channel_uuid`.
  """
  def get(channel_uuid, input_url)
      when is_binary(channel_uuid) and is_binary(input_url) do
    ensure_table!()

    case :ets.lookup(@table, channel_uuid) do
      [{^channel_uuid, %Result{} = result}] ->
        if cacheable?(result) do
          result
        else
          # Drop inconclusive leftovers from older short probes.
          :ets.delete(@table, channel_uuid)
          fetch_and_maybe_cache(channel_uuid, input_url)
        end

      _ ->
        fetch_and_maybe_cache(channel_uuid, input_url)
    end
  end

  defp fetch_and_maybe_cache(channel_uuid, input_url) do
    result = probe(input_url)

    # Only cache conclusive probes. Timeouts/errors return a blank
    # conservative_default that would permanently skip yadif/scale decisions
    # and leave interlaced SD looking like it jumps forward/back.
    if cacheable?(result) do
      :ets.insert(@table, {channel_uuid, result})
    end

    result
  end

  @doc """
  Marks a channel as unsuitable for stream-copy so the next start transcodes.
  """
  def block_copy(channel_uuid) when is_binary(channel_uuid) do
    ensure_table!()

    case :ets.lookup(@table, channel_uuid) do
      [{^channel_uuid, %Result{} = result}] ->
        updated = %{result | copy_blocked?: true}
        :ets.insert(@table, {channel_uuid, updated})
        Logger.warning("demoting channel #{channel_uuid} from stream-copy to transcode")
        updated

      _ ->
        fallback = %Result{copy_blocked?: true}
        :ets.insert(@table, {channel_uuid, fallback})
        Logger.warning("demoting channel #{channel_uuid} from stream-copy to transcode")
        fallback
    end
  end

  @doc """
  Whether stream-copy (video remux) is allowed for this probe result and config.
  """
  def copy_eligible?(%Result{} = result, config \\ []) do
    copy_mode = Keyword.get(config, :copy, :auto)

    copy_mode != :off and
      not result.copy_blocked? and
      result.has_video? and
      result.video_codec == "h264" and
      result.pix_fmt in ["yuv420p", "yuvj420p"] and
      (is_nil(result.height) or result.height <= 1080)
  end

  @doc """
  Whether the source is interlaced (needs deinterlace).
  Unknown field_order is treated as potentially interlaced (conservative).
  """
  def interlaced?(%Result{has_video?: false}), do: false
  def interlaced?(%Result{field_order: "progressive"}), do: false
  def interlaced?(%Result{field_order: nil}), do: true
  def interlaced?(%Result{field_order: order}) when is_binary(order), do: true

  @doc """
  Whether the source exceeds the 1080p width cap and needs downscale.
  Unknown width is treated as needing scale (conservative).
  """
  def needs_scale?(%Result{has_video?: false}), do: false
  def needs_scale?(%Result{width: nil}), do: true
  def needs_scale?(%Result{width: width}) when is_integer(width), do: width > 1920

  @doc """
  Runs ffprobe against `input_url` and returns a `Result`.
  On timeout/error returns a conservative default (assume video, unknown codec).
  """
  def probe(input_url) when is_binary(input_url) do
    ffprobe = System.find_executable("ffprobe") || "ffprobe"

    args = [
      "-v",
      "error",
      "-probesize",
      "5M",
      "-analyzeduration",
      "3M",
      "-rw_timeout",
      "5000000",
      "-show_entries",
      "stream=index,codec_type,codec_name,pix_fmt,width,height,field_order,profile",
      "-of",
      "json",
      input_url
    ]

    task = Task.async(fn -> System.cmd(ffprobe, args, stderr_to_stdout: true) end)

    case Task.yield(task, @probe_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} ->
        parse_ffprobe_json(output)

      {:ok, {output, status}} ->
        Logger.warning("ffprobe exited with status #{status}: #{String.slice(output, 0, 200)}")
        conservative_default()

      nil ->
        Logger.warning("ffprobe timed out for #{String.slice(input_url, 0, 80)}")
        conservative_default()
    end
  rescue
    error ->
      Logger.warning("ffprobe failed: #{Exception.message(error)}")
      conservative_default()
  end

  @doc false
  def parse_ffprobe_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"streams" => streams}} when is_list(streams) ->
        video = Enum.find(streams, &(&1["codec_type"] == "video"))
        audio = Enum.find(streams, &(&1["codec_type"] == "audio"))

        %Result{
          has_video?: not is_nil(video),
          video_codec: video && video["codec_name"],
          pix_fmt: video && video["pix_fmt"],
          width: video && video["width"],
          height: video && video["height"],
          field_order: video && video["field_order"],
          profile: video && to_string_or_nil(video["profile"]),
          audio_codec: audio && audio["codec_name"],
          copy_blocked?: false
        }

      _ ->
        conservative_default()
    end
  end

  @doc false
  def put_for_test(channel_uuid, %Result{} = result) when is_binary(channel_uuid) do
    ensure_table!()
    :ets.insert(@table, {channel_uuid, result})
    result
  end

  @doc false
  def clear_for_test do
    ensure_table!()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp conservative_default do
    %Result{has_video?: true}
  end

  defp cacheable?(%Result{copy_blocked?: true}), do: true
  defp cacheable?(%Result{has_video?: false}), do: true
  defp cacheable?(%Result{video_codec: codec}) when is_binary(codec), do: true
  defp cacheable?(%Result{}), do: false

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: value
  defp to_string_or_nil(value), do: to_string(value)
end
