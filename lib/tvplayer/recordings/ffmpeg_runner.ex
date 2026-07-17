defmodule Tvplayer.Recordings.FFmpegRunner do
  @moduledoc """
  Spawns ffmpeg to convert a DVR recording into a streaming-friendly MP4.

  Progress is reported via `-progress pipe:1` by sending
  `{:transcode_progress, uuid, percent}` messages to the notify pid.
  On completion (or failure) it sends `{:transcode_done, uuid}` or
  `{:transcode_failed, uuid, reason}`.
  """

  @behaviour Tvplayer.Recordings.Runner

  use GenServer

  require Logger

  alias Tvplayer.Streams.FFmpeg, as: StreamsFFmpeg

  defstruct [
    :port,
    :os_pid,
    :uuid,
    :notify,
    :output_path,
    :part_path,
    :duration_us,
    :last_percent,
    :last_broadcast_at,
    buffer: ""
  ]

  @progress_throttle_ms 1_000

  # Keys emitted by `-progress pipe:1` that are not used for percent calculation.
  @progress_keys ~w(
    frame fps stream_0_0_q bitrate total_size out_time dup_frames drop_frames
    speed flush_packets
  )

  @impl true
  def start(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 5_000)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  @doc """
  Probe media duration in milliseconds via ffprobe. Returns `nil` on failure.
  """
  def probe_duration_ms(input_url, config \\ []) when is_binary(input_url) do
    ffprobe =
      System.find_executable(Keyword.get(config, :ffprobe_path, "ffprobe")) || "ffprobe"

    args = [
      "-v",
      "error",
      "-show_entries",
      "format=duration",
      "-of",
      "default=noprint_wrappers=1:nokey=1",
      input_url
    ]

    case System.cmd(ffprobe, args, stderr_to_stdout: true) do
      {out, 0} ->
        out
        |> String.trim()
        |> Float.parse()
        |> case do
          {seconds, _} when seconds > 0 -> round(seconds * 1000)
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc false
  def build_args(opts, config) do
    threads = to_string(Keyword.get(config, :threads, 4))
    crf = to_string(Keyword.get(config, :crf, 23))
    preset = Keyword.get(config, :preset, "veryfast")
    audio_bitrate = Keyword.get(config, :audio_bitrate, "160k")

    [
      "-hide_banner",
      "-loglevel",
      "warning",
      "-y",
      "-probesize",
      "10M",
      "-analyzeduration",
      "10M",
      "-fflags",
      "+genpts+discardcorrupt",
      "-i",
      opts.input_url,
      "-map",
      "0:v:0",
      "-map",
      "0:a:0?",
      "-c:v",
      "libx264",
      "-preset",
      preset,
      "-profile:v",
      "high",
      "-level:v",
      "4.1",
      "-pix_fmt",
      "yuv420p",
      "-crf",
      crf,
      "-c:a",
      "aac",
      "-b:a",
      audio_bitrate,
      "-ac",
      "2",
      "-ar",
      "48000",
      "-movflags",
      "+faststart",
      "-threads",
      threads,
      "-progress",
      "pipe:1",
      "-nostats",
      # Explicit format: temp path ends in `.mp4.part` which ffmpeg cannot sniff.
      "-f",
      "mp4",
      opts.part_path
    ]
  end

  @doc false
  def parse_progress_line(line) when is_binary(line) do
    case String.split(line, "=", parts: 2) do
      ["out_time_us", value] ->
        parse_out_time_us(value)

      # ffmpeg names this poorly: out_time_ms is actually microseconds (same as out_time_us).
      ["out_time_ms", value] ->
        parse_out_time_us(value)

      ["progress", "end"] ->
        :progress_end

      ["progress", _] ->
        :progress_continue

      [key, _] when key in @progress_keys ->
        :progress_noise

      _ ->
        :ignore
    end
  end

  defp parse_out_time_us(value) do
    case Integer.parse(String.trim(value)) do
      {us, _} when us >= 0 -> {:out_time_us, us}
      _ -> :ignore
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    config = Map.get(opts, :config, Application.get_env(:tvplayer, :transcodes, []))
    ffmpeg = System.find_executable(Keyword.get(config, :ffmpeg_path, "ffmpeg")) || "ffmpeg"

    File.mkdir_p!(Path.dirname(opts.part_path))
    _ = File.rm(opts.part_path)
    _ = File.rm(opts.output_path)

    duration_us =
      case Map.get(opts, :duration_ms) do
        ms when is_integer(ms) and ms > 0 -> ms * 1000
        _ -> nil
      end

    args = build_args(opts, config)

    Logger.info("starting recording transcode for #{opts.uuid}")

    port =
      Port.open(
        {:spawn_executable, ffmpeg},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          line: 2048
        ]
      )

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} when is_integer(pid) and pid > 1 -> pid
        _ -> nil
      end

    {:ok,
     %__MODULE__{
       port: port,
       os_pid: os_pid,
       uuid: opts.uuid,
       notify: opts.notify,
       output_path: opts.output_path,
       part_path: opts.part_path,
       duration_us: duration_us,
       last_percent: -1,
       last_broadcast_at: 0
     }}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    {:noreply, handle_progress_line(line, state)}
  end

  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: state.buffer <> chunk}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    {complete, rest} = split_lines(state.buffer <> data)

    state =
      Enum.reduce(complete, %{state | buffer: rest}, fn line, acc ->
        handle_progress_line(line, acc)
      end)

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | port: nil, os_pid: nil}

    if status == 0 do
      case finalize(state) do
        :ok ->
          send(state.notify, {:transcode_done, state.uuid})
          {:stop, :normal, state}

        {:error, reason} ->
          cleanup_part(state.part_path)
          send(state.notify, {:transcode_failed, state.uuid, reason})
          {:stop, :normal, state}
      end
    else
      cleanup_part(state.part_path)
      send(state.notify, {:transcode_failed, state.uuid, {:ffmpeg_exit, status}})
      {:stop, :normal, state}
    end
  end

  def handle_info({:EXIT, port, _reason}, %{port: port} = state) when is_port(port) do
    {:noreply, state}
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_port(state.port)
    StreamsFFmpeg.kill_os_process(state.os_pid)
    cleanup_part(state.part_path)
    :ok
  end

  defp handle_progress_line(line, state) do
    trimmed = String.trim(line)

    case parse_progress_line(trimmed) do
      {:out_time_us, us} ->
        maybe_broadcast_progress(state, us)

      :progress_end ->
        # Encoding finished; final :done comes from exit_status. Don't spike to 99%.
        state

      :progress_continue ->
        state

      :progress_noise ->
        state

      :ignore when trimmed == "" ->
        state

      :ignore ->
        Logger.warning("ffmpeg[#{state.uuid}]: #{trimmed}")
        state
    end
  end

  defp maybe_broadcast_progress(state, out_time_us) do
    percent = percent_for(out_time_us, state.duration_us)
    now = System.monotonic_time(:millisecond)
    elapsed = now - state.last_broadcast_at

    if percent != state.last_percent and
         (elapsed >= @progress_throttle_ms or percent in [0, 100]) do
      send(state.notify, {:transcode_progress, state.uuid, percent})
      %{state | last_percent: percent, last_broadcast_at: now}
    else
      state
    end
  end

  defp percent_for(_out, nil), do: 0
  defp percent_for(_out, duration) when duration <= 0, do: 0

  defp percent_for(out_time_us, duration_us) do
    out_time_us
    |> Kernel.*(100)
    |> div(duration_us)
    |> min(99)
    |> max(0)
  end

  defp finalize(%{part_path: part, output_path: output}) do
    if File.exists?(part) and File.stat!(part).size > 0 do
      File.rename!(part, output)
      :ok
    else
      {:error, :empty_output}
    end
  rescue
    e -> {:error, e}
  end

  defp cleanup_part(path) when is_binary(path) do
    _ = File.rm(path)
    :ok
  end

  defp cleanup_part(_), do: :ok

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp close_port(_), do: :ok

  defp split_lines(data) do
    parts = String.split(data, "\n")

    case parts do
      [only] ->
        {[], only}

      list ->
        {complete, [rest]} = Enum.split(list, -1)
        {complete, rest}
    end
  end
end
