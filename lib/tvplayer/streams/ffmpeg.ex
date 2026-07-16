defmodule Tvplayer.Streams.FFmpeg do
  @moduledoc """
  FFmpeg-based HLS runner.

  Chooses stream-copy (remux) for web-compatible H.264 sources, otherwise
  transcodes with libx264. Filters and keyframe cadence are driven by a
  cached per-channel probe result.

  Every Port-spawned ffmpeg OS process is tracked by pid and killed on stop,
  crash, application shutdown, and again on boot (orphan sweep).
  """

  @behaviour Tvplayer.Streams.Runner

  use GenServer

  require Logger

  alias Tvplayer.Streams.Probe
  alias Tvplayer.Streams.Probe.Result

  @pid_table :tvplayer_ffmpeg_os_pids
  @sigterm 15
  @sigkill 9
  @kill_wait_ms 500
  @kill_poll_ms 50

  defstruct [:port, :channel_uuid, :os_pid, :copy_mode?]

  @impl true
  def start(opts) do
    File.mkdir_p!(opts.output_dir)
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
  Creates the pid registry and kills any leftover ffmpeg writers under `hls_root`.
  Call once during application start.
  """
  def prepare!(hls_root) when is_binary(hls_root) do
    ensure_pid_table!()
    killed = kill_orphans(hls_root)

    if killed > 0 do
      Logger.warning(
        "killed #{killed} orphaned ffmpeg process(es) under #{Path.expand(hls_root)}"
      )
    end

    :ok
  end

  @doc """
  Kills every tracked ffmpeg pid, then sweeps orphans under `hls_root`.
  Call during application stop.
  """
  def shutdown_all(hls_root) when is_binary(hls_root) do
    ensure_pid_table!()

    tracked =
      @pid_table
      |> :ets.tab2list()
      |> Enum.map(fn {pid, _uuid} -> pid end)

    Enum.each(tracked, &kill_os_process/1)
    kill_orphans(hls_root)
    :ok
  end

  @doc """
  Kills ffmpeg processes whose command line writes under `hls_root`.
  Returns the number of processes confirmed dead.
  """
  def kill_orphans(hls_root) when is_binary(hls_root) do
    root = Path.expand(hls_root)

    matching_ffmpeg_pids(fn cmdline ->
      String.contains?(cmdline, root)
    end)
    |> Enum.count(fn pid ->
      kill_os_process(pid)
      dead? = not os_process_alive?(pid)

      unless dead? do
        Logger.error("ffmpeg pid #{pid} survived orphan kill under #{root}")
      end

      dead?
    end)
  end

  @doc """
  Kills ffmpeg processes writing HLS for a specific channel output directory.
  """
  def kill_channel_orphans(output_dir) when is_binary(output_dir) do
    marker = Path.expand(output_dir)

    matching_ffmpeg_pids(fn cmdline -> String.contains?(cmdline, marker) end)
    |> Enum.each(&kill_os_process/1)

    :ok
  end

  @doc """
  Kills ffmpeg HLS writers under `hls_root` that do not belong to any of the
  given live channel UUIDs. Returns the number of processes confirmed dead.
  """
  def kill_orphans_except(hls_root, live_uuids)
      when is_binary(hls_root) and is_list(live_uuids) do
    root = Path.expand(hls_root)
    live = MapSet.new(live_uuids)

    matching_ffmpeg_pids(fn cmdline ->
      String.contains?(cmdline, root) and not live_channel_cmdline?(cmdline, root, live)
    end)
    |> Enum.count(fn pid ->
      kill_os_process(pid)
      dead? = not os_process_alive?(pid)

      unless dead? do
        Logger.error("ffmpeg pid #{pid} survived periodic orphan sweep under #{root}")
      end

      dead?
    end)
  end

  @doc false
  def kill_os_process(pid) when is_integer(pid) and pid > 1 do
    untrack(pid)

    if os_process_alive?(pid) do
      _ = signal(pid, @sigterm)

      unless await_death(pid, div(@kill_wait_ms, @kill_poll_ms)) do
        _ = signal(pid, @sigkill)
        _ = await_death(pid, 4)
      end

      if os_process_alive?(pid) do
        Logger.error("ffmpeg pid #{pid} still alive after SIGTERM and SIGKILL")
      end
    end

    :ok
  end

  def kill_os_process(_), do: :ok

  @doc false
  def os_process_alive?(pid) when is_integer(pid) and pid > 1 do
    case File.read("/proc/#{pid}/stat") do
      {:ok, stat} ->
        # Format: "pid (comm) state ..." — comm may contain spaces/parens.
        case Regex.run(~r/\) ([A-Z]) /, stat) do
          [_, "Z"] -> false
          [_, _] -> true
          nil -> false
        end

      {:error, _} ->
        false
    end
  end

  def os_process_alive?(_), do: false

  @doc false
  def matching_ffmpeg_pids(match_fun) when is_function(match_fun, 1) do
    Path.wildcard("/proc/[0-9]*/cmdline")
    |> Enum.flat_map(fn path ->
      with {:ok, raw} <- File.read(path),
           cmdline = normalize_cmdline(raw),
           true <- ffmpeg_cmdline?(cmdline),
           true <- match_fun.(cmdline),
           {pid, ""} <- Integer.parse(Path.basename(Path.dirname(path))),
           true <- pid > 1 do
        [pid]
      else
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  def build_args(opts, config, %Result{} = probe) do
    playlist = opts.playlist_path
    segment_pattern = Path.join(opts.output_dir, "segment_%05d.ts")
    hls_time = to_string(Keyword.get(config, :hls_time, 2))
    hls_list_size = to_string(Keyword.get(config, :hls_list_size, 30))
    copy_mode? = Probe.copy_eligible?(probe, config)

    # MPEG-2 SD from TVHeadend often needs a few MB before dimensions/field
    # order are known. Avoid nobuffer/low_delay — they break B-frame reordering
    # and make interlaced frames look like they jump forward/back.
    base_input = [
      "-hide_banner",
      "-loglevel",
      "warning",
      "-probesize",
      "5M",
      "-analyzeduration",
      "3M",
      "-fflags",
      "+genpts+discardcorrupt",
      "-i",
      opts.input_url,
      "-map",
      "0:a:0?"
    ]

    video_args = video_args(probe, config, copy_mode?)

    audio_and_hls = [
      "-c:a",
      "aac",
      "-b:a",
      Keyword.get(config, :audio_bitrate, "192k"),
      "-ac",
      "2",
      "-ar",
      "48000",
      "-f",
      "hls",
      "-hls_time",
      hls_time,
      "-hls_list_size",
      hls_list_size,
      "-hls_flags",
      "delete_segments+omit_endlist+temp_file+independent_segments",
      "-hls_segment_filename",
      segment_pattern,
      playlist
    ]

    base_input ++ video_args ++ audio_and_hls
  end

  @doc false
  def video_args(%Result{has_video?: false}, _config, _copy_mode?), do: ["-vn"]

  def video_args(%Result{} = _probe, _config, true) do
    ["-map", "0:v:0", "-c:v", "copy"]
  end

  def video_args(%Result{} = probe, config, false) do
    keyframe_interval = Keyword.get(config, :keyframe_interval, 2)

    [
      "-map",
      "0:v:0",
      "-c:v",
      "libx264",
      "-preset",
      Keyword.get(config, :preset, "veryfast"),
      "-profile:v",
      "high",
      "-level:v",
      "4.1",
      "-pix_fmt",
      "yuv420p",
      "-crf",
      to_string(Keyword.get(config, :crf, 20)),
      "-maxrate",
      Keyword.get(config, :maxrate, "6M"),
      "-bufsize",
      Keyword.get(config, :bufsize, "12M"),
      "-sc_threshold",
      "0",
      "-force_key_frames",
      "expr:gte(t,n_forced*#{keyframe_interval})"
    ] ++ maybe_vf(probe)
  end

  @doc false
  def maybe_vf(%Result{} = probe) do
    filters =
      []
      |> then(fn acc ->
        # deint=all: TVH/MPEG-2 often mislabels fields as progressive when the
        # probe was short, and deint=interlaced then skips those frames — leaving
        # combing that looks like the picture jumping forward and back.
        if Probe.interlaced?(probe),
          do: acc ++ ["yadif=mode=send_frame:parity=auto:deint=all"],
          else: acc
      end)
      |> then(fn acc ->
        if Probe.needs_scale?(probe),
          do: acc ++ ["scale='min(1920,iw)':'-2':force_original_aspect_ratio=decrease"],
          else: acc
      end)

    case filters do
      [] -> []
      list -> ["-vf", Enum.join(list, ",")]
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ensure_pid_table!()
    Probe.ensure_table!()

    # Drop leftovers from a previous BEAM that wrote into this channel dir.
    kill_channel_orphans(opts.output_dir)

    config = Map.get(opts, :config, Application.get_env(:tvplayer, :streams, []))
    ffmpeg = System.find_executable(Keyword.get(config, :ffmpeg_path, "ffmpeg")) || "ffmpeg"
    probe = Probe.get(opts.channel_uuid, opts.input_url)
    copy_mode? = Probe.copy_eligible?(probe, config)
    args = build_args(opts, config, probe)

    Logger.info(
      "starting ffmpeg for channel #{opts.channel_uuid} " <>
        "(video=#{probe.has_video?} copy=#{copy_mode?} codec=#{probe.video_codec || "unknown"})"
    )

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

    if os_pid, do: track(os_pid, opts.channel_uuid)

    {:ok,
     %__MODULE__{
       port: port,
       channel_uuid: opts.channel_uuid,
       os_pid: os_pid,
       copy_mode?: copy_mode?
     }}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    Logger.debug("ffmpeg[#{state.channel_uuid}]: #{line}")
    {:noreply, state}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) when is_binary(data) do
    Logger.debug("ffmpeg[#{state.channel_uuid}]: #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    # Process already exited; drop tracking so terminate does not signal a reused pid.
    untrack(state.os_pid)

    if state.copy_mode? and status != 0 do
      Probe.block_copy(state.channel_uuid)
    end

    Logger.warning("ffmpeg for #{state.channel_uuid} exited with status #{status}")
    {:stop, {:ffmpeg_exit, status}, %{state | os_pid: nil, port: nil}}
  end

  # Port closed after the OS process exited (or Port.close). exit_status handles shutdown.
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
    kill_os_process(state.os_pid)
    :ok
  end

  defp close_port(port) when is_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp close_port(_), do: :ok

  defp ensure_pid_table! do
    case :ets.whereis(@pid_table) do
      :undefined ->
        :ets.new(@pid_table, [
          :named_table,
          :public,
          :set,
          read_concurrency: true,
          write_concurrency: true
        ])

      _tid ->
        @pid_table
    end
  end

  defp track(pid, channel_uuid) when is_integer(pid) do
    ensure_pid_table!()
    :ets.insert(@pid_table, {pid, channel_uuid})
  end

  defp untrack(pid) when is_integer(pid) do
    case :ets.whereis(@pid_table) do
      :undefined -> :ok
      _ -> :ets.delete(@pid_table, pid)
    end
  end

  defp untrack(_), do: :ok

  # Use /bin/sh so the POSIX `kill` builtin works even when procps is absent
  # (Debian slim production images have no standalone `kill` binary).
  defp signal(pid, sig) when is_integer(pid) and sig in [@sigterm, @sigkill] do
    sig_name = if sig == @sigkill, do: "KILL", else: "TERM"

    case System.cmd("/bin/sh", ["-c", "kill -#{sig_name} #{pid}"], stderr_to_stdout: true) do
      {_, 0} ->
        true

      {out, code} ->
        Logger.warning(
          "failed to signal ffmpeg pid #{pid} (#{sig_name}): exit=#{code} #{String.trim(out)}"
        )

        false
    end
  rescue
    e ->
      Logger.error("could not send #{sig} to pid #{pid}: #{Exception.message(e)}")
      false
  end

  defp signal(_pid, _sig), do: false

  defp await_death(_pid, attempts) when attempts <= 0, do: false

  defp await_death(pid, attempts) do
    if os_process_alive?(pid) do
      Process.sleep(@kill_poll_ms)
      await_death(pid, attempts - 1)
    else
      true
    end
  end

  defp normalize_cmdline(raw) when is_binary(raw) do
    raw
    |> :binary.replace(<<0>>, " ", [:global])
    |> String.trim()
  end

  defp ffmpeg_cmdline?(cmdline) do
    String.contains?(cmdline, "ffmpeg") and String.contains?(cmdline, "-hls_segment_filename")
  end

  defp live_channel_cmdline?(cmdline, root, live_uuids) do
    Enum.any?(live_uuids, fn uuid ->
      String.contains?(cmdline, Path.join(root, uuid))
    end)
  end
end
