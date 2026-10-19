defmodule Tvplayer.Recordings.Hls do
  @moduledoc """
  VOD HLS for a transcoded recording.

  The MP4 in the transcode directory stays the download. Playback is a
  copy-only cut of that file into ~4 second MPEG-TS segments, so the player
  starts from the first segment instead of reading the whole MP4 index.

  TS rather than fragmented MP4: the MP4 keeps audio and video aligned with
  an edit list (x264 delay and AAC priming). Players ignore that list on
  fMP4 HLS, so the picture lags the sound. MPEG-TS has no edit list, and
  hls.js rebuilds the timestamps itself.

  Recordings encoded before this existed are segmented on first play.
  That pass copies packets; it does not encode again.
  """

  require Logger

  @segment_seconds "4"

  @doc "Directory holding `index.m3u8` and the `seg_#####.ts` segments."
  def dir(uuid) when is_binary(uuid) do
    Path.join(root(), uuid)
  end

  def remove(uuid) when is_binary(uuid) do
    File.rm_rf(dir(uuid))
  end

  @doc """
  Makes sure the playlist exists for an MP4 that is already on disk.
  """
  def ensure(uuid) when is_binary(uuid) do
    cond do
      ready?(uuid) ->
        :ok

      not File.regular?(mp4_path(uuid)) ->
        {:error, :missing}

      true ->
        :global.trans({__MODULE__, uuid}, fn ->
          if ready?(uuid), do: :ok, else: build(uuid)
        end)
    end
  end

  def ready?(uuid) when is_binary(uuid) do
    path = Path.join(dir(uuid), "index.m3u8")

    case File.read(path) do
      {:ok, body} ->
        String.contains?(body, "#EXT-X-ENDLIST") and
          String.contains?(body, ".ts") and
          not String.contains?(body, "#EXT-X-MAP")

      _ ->
        false
    end
  end

  @doc "Safe path of the playlist or one media segment."
  def path(uuid, file) when is_binary(uuid) and is_binary(file) do
    if valid_file?(file) do
      path = Path.join(dir(uuid), file)
      if File.regular?(path), do: {:ok, path}, else: :error
    else
      :error
    end
  end

  def valid_file?("index.m3u8"), do: true

  def valid_file?(<<"seg_", rest::binary>>) do
    String.match?(rest, ~r/^\d{5}\.ts$/)
  end

  def valid_file?(_file), do: false

  defp build(uuid) do
    tmp = dir(uuid) <> ".tmp"
    File.rm_rf!(tmp)
    File.mkdir_p!(tmp)

    ffmpeg = System.find_executable(ffmpeg_path()) || ffmpeg_path()

    args = [
      "-hide_banner",
      "-loglevel",
      "error",
      "-y",
      "-i",
      mp4_path(uuid),
      "-c",
      "copy",
      # No added mux delay. The MP4 timestamps are already aligned.
      "-muxdelay",
      "0",
      "-muxpreload",
      "0",
      "-f",
      "hls",
      "-hls_time",
      @segment_seconds,
      "-hls_playlist_type",
      "vod",
      "-hls_segment_filename",
      Path.join(tmp, "seg_%05d.ts"),
      "-hls_flags",
      "independent_segments",
      Path.join(tmp, "index.m3u8")
    ]

    case System.cmd(ffmpeg, args, stderr_to_stdout: true) do
      {_output, 0} ->
        publish(uuid, tmp)

      {output, status} ->
        File.rm_rf(tmp)
        Logger.warning("hls segmenting failed for #{uuid}: exit #{status}: #{output}")
        {:error, {:ffmpeg_exit, status}}
    end
  end

  defp publish(uuid, tmp) do
    playlist = Path.join(tmp, "index.m3u8")

    if File.regular?(playlist) and File.read!(playlist) =~ "#EXT-X-ENDLIST" do
      dest = dir(uuid)
      File.rm_rf!(dest)
      File.rename!(tmp, dest)
      :ok
    else
      File.rm_rf(tmp)
      {:error, :empty_playlist}
    end
  end

  defp mp4_path(uuid), do: Path.join(root(), "#{uuid}.mp4")

  defp root do
    Application.get_env(:tvplayer, :transcodes, [])
    |> Keyword.get(:root, "tmp/transcodes")
    |> Path.expand()
  end

  defp ffmpeg_path do
    Application.get_env(:tvplayer, :transcodes, [])
    |> Keyword.get(:ffmpeg_path, "ffmpeg")
  end
end
