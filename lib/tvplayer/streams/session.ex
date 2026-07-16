defmodule Tvplayer.Streams.Session do
  @moduledoc """
  Per-channel HLS session. Owns one media runner and tracks viewers.
  """

  use GenServer

  require Logger

  alias Tvplayer.Streams.Probe
  alias Tvplayer.Tvheadend.Client

  @topic_prefix "streams:"
  @all_topic "streams:all"

  defstruct [
    :channel_uuid,
    :channel_number,
    :output_dir,
    :playlist_path,
    :runner_mod,
    :runner_pid,
    :status,
    :error,
    :hot?,
    :idle_timer,
    :idle_since,
    :startup_timer,
    :ready_check_timer,
    viewers: MapSet.new(),
    restart_attempts: 0
  ]

  def via(channel_uuid), do: {:via, Registry, {Tvplayer.Streams.Registry, channel_uuid}}

  def topic(channel_uuid), do: @topic_prefix <> channel_uuid

  def all_topic, do: @all_topic

  def start_link(opts) do
    channel_uuid = Keyword.fetch!(opts, :channel_uuid)
    GenServer.start_link(__MODULE__, opts, name: via(channel_uuid))
  end

  def watch(channel_uuid, viewer_pid) do
    GenServer.call(via(channel_uuid), {:watch, viewer_pid})
  end

  def unwatch(channel_uuid, viewer_pid) do
    GenServer.cast(via(channel_uuid), {:unwatch, viewer_pid})
  end

  def prewarm(channel_uuid) do
    GenServer.cast(via(channel_uuid), :prewarm)
  end

  def status(channel_uuid) do
    GenServer.call(via(channel_uuid), :status)
  end

  def stop(channel_uuid) do
    case Registry.lookup(Tvplayer.Streams.Registry, channel_uuid) do
      [{pid, _}] ->
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal, 5_000)
        end

        :ok

      [] ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  def playlist_url(channel_uuid) do
    "/hls/#{channel_uuid}/index.m3u8"
  end

  @impl true
  def init(opts) do
    channel_uuid = Keyword.fetch!(opts, :channel_uuid)
    config = Application.get_env(:tvplayer, :streams, [])
    hls_root = Keyword.fetch!(config, :hls_root)
    output_dir = Path.join(hls_root, channel_uuid)
    File.mkdir_p!(output_dir)
    cleanup_dir(output_dir)

    state = %__MODULE__{
      channel_uuid: channel_uuid,
      channel_number: Keyword.get(opts, :channel_number),
      output_dir: output_dir,
      playlist_path: Path.join(output_dir, "index.m3u8"),
      runner_mod: Keyword.get(config, :runner, Tvplayer.Streams.FFmpeg),
      status: :starting,
      hot?: Keyword.get(opts, :hot?, false),
      viewers: MapSet.new()
    }

    send(self(), :start_runner)
    {:ok, state}
  end

  @impl true
  def handle_call({:watch, viewer_pid}, _from, state) do
    Process.monitor(viewer_pid)
    state = %{state | viewers: MapSet.put(state.viewers, viewer_pid), idle_since: nil}
    state = cancel_idle_timer(state)

    reply = %{
      status: state.status,
      playlist_url: playlist_url(state.channel_uuid),
      error: state.error,
      radio?: radio?(state),
      idle_since: state.idle_since
    }

    {:reply, {:ok, reply}, state}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       status: state.status,
       playlist_url: playlist_url(state.channel_uuid),
       error: state.error,
       viewers: MapSet.size(state.viewers),
       hot?: state.hot?,
       radio?: radio?(state),
       idle_since: state.idle_since
     }, state}
  end

  @impl true
  def handle_cast({:unwatch, viewer_pid}, state) do
    state = %{state | viewers: MapSet.delete(state.viewers, viewer_pid)}
    {:noreply, maybe_schedule_idle(state)}
  end

  def handle_cast(:prewarm, state) do
    state = cancel_idle_timer(state)

    state =
      if state.hot? do
        state
      else
        schedule_idle(
          state,
          Application.get_env(:tvplayer, :streams, [])[:prewarm_idle_ms] || 8_000
        )
      end

    {:noreply, state}
  end

  @impl true
  def handle_info(:start_runner, state) do
    input_url = Client.stream_url(state.channel_uuid, profile: "pass")
    config = Application.get_env(:tvplayer, :streams, [])

    case state.runner_mod.start(%{
           channel_uuid: state.channel_uuid,
           input_url: input_url,
           output_dir: state.output_dir,
           playlist_path: state.playlist_path,
           config: config
         }) do
      {:ok, runner_pid} ->
        Process.monitor(runner_pid)

        # Stream-copy segments only close on source keyframes. Broadcast H.264
        # GOPs are often 5–15s, so allow a longer window when remux is enabled.
        startup_ms = startup_timeout_ms(config)
        startup_timer = Process.send_after(self(), :startup_timeout, startup_ms)
        ready_check_timer = Process.send_after(self(), :check_ready, 250)

        state = %{
          state
          | runner_pid: runner_pid,
            status: :starting,
            error: nil,
            startup_timer: startup_timer,
            ready_check_timer: ready_check_timer
        }

        broadcast(state)
        {:noreply, state}

      {:error, reason} ->
        state = %{state | status: :error, error: inspect(reason), runner_pid: nil}
        broadcast(state)
        {:noreply, maybe_restart(state)}
    end
  end

  def handle_info(:check_ready, state) do
    cond do
      state.status == :ready ->
        {:noreply, %{state | ready_check_timer: nil}}

      playlist_ready?(state.playlist_path) ->
        state =
          cancel_startup_timer(%{state | status: :ready, error: nil, ready_check_timer: nil})

        broadcast(state)
        {:noreply, state}

      true ->
        timer = Process.send_after(self(), :check_ready, 250)
        {:noreply, %{state | ready_check_timer: timer}}
    end
  end

  def handle_info(:startup_timeout, state) do
    if state.status == :ready do
      {:noreply, %{state | startup_timer: nil}}
    else
      # Stream-copy may fail to produce segments (long GOPs etc.); demote so
      # the automatic restart takes the transcode path instead.
      maybe_demote_copy(state)
      stop_runner(state)

      state = %{
        state
        | status: :error,
          error:
            "Dieser Kanal kann gerade nicht gestartet werden. Möglicherweise belegt eine Aufnahme den Tuner.",
          runner_pid: nil,
          startup_timer: nil
      }

      broadcast(state)
      {:noreply, maybe_restart(state)}
    end
  end

  def handle_info(:idle_stop, state) do
    if state.hot? or MapSet.size(state.viewers) > 0 do
      {:noreply, %{state | idle_timer: nil}}
    else
      {:stop, :normal, cleanup(state)}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    cond do
      pid == state.runner_pid ->
        state = %{state | runner_pid: nil, status: :error, error: "Encoder unerwartet gestoppt"}
        broadcast(state)
        {:noreply, maybe_restart(state)}

      MapSet.member?(state.viewers, pid) ->
        state = %{state | viewers: MapSet.delete(state.viewers, pid)}
        {:noreply, maybe_schedule_idle(state)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cleanup(state)
    broadcast(%{state | status: :idle, error: nil})
    :ok
  end

  @doc false
  def startup_timeout_ms(config) when is_list(config) do
    # When STREAM_COPY is enabled we may remux; give long-GOP sources time to
    # emit ≥2 keyframe-aligned segments. Transcode-only keeps the short timeout.
    if Keyword.get(config, :copy, :auto) == :off do
      Keyword.get(config, :startup_timeout_ms, 45_000)
    else
      Keyword.get(config, :copy_startup_timeout_ms, 120_000)
    end
  end

  defp maybe_demote_copy(state) do
    config = Application.get_env(:tvplayer, :streams, [])
    runner = Keyword.get(config, :runner, Tvplayer.Streams.FFmpeg)

    if runner == Tvplayer.Streams.FFmpeg do
      Probe.block_copy(state.channel_uuid)
    end
  end

  defp maybe_restart(%{hot?: true} = state) do
    attempts = state.restart_attempts + 1
    delay = min(30_000, 1_000 * attempts)
    Process.send_after(self(), :start_runner, delay)
    %{state | restart_attempts: attempts, status: :starting}
  end

  defp maybe_restart(%{viewers: viewers} = state) do
    if MapSet.size(viewers) > 0 do
      attempts = state.restart_attempts + 1
      delay = min(15_000, 1_000 * attempts)
      Process.send_after(self(), :start_runner, delay)
      %{state | restart_attempts: attempts, status: :starting}
    else
      maybe_schedule_idle(state)
    end
  end

  defp maybe_schedule_idle(%{hot?: true} = state) do
    cancel_idle_timer(%{state | idle_since: nil})
  end

  defp maybe_schedule_idle(state) do
    if MapSet.size(state.viewers) == 0 do
      idle_ms = Application.get_env(:tvplayer, :streams, [])[:idle_ms] || 30_000

      state
      |> Map.put(:idle_since, state.idle_since || System.monotonic_time(:millisecond))
      |> schedule_idle(idle_ms)
    else
      cancel_idle_timer(%{state | idle_since: nil})
    end
  end

  defp schedule_idle(state, ms) do
    state = cancel_idle_timer(state)
    %{state | idle_timer: Process.send_after(self(), :idle_stop, ms)}
  end

  defp cancel_idle_timer(%{idle_timer: nil} = state), do: state

  defp cancel_idle_timer(%{idle_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | idle_timer: nil}
  end

  defp cancel_startup_timer(%{startup_timer: nil} = state), do: state

  defp cancel_startup_timer(%{startup_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | startup_timer: nil}
  end

  defp stop_runner(%{runner_pid: nil} = state), do: state

  defp stop_runner(%{runner_mod: mod, runner_pid: pid} = state) do
    mod.stop(pid)
    %{state | runner_pid: nil}
  end

  defp cleanup(state) do
    state = stop_runner(state)

    if state.runner_mod == Tvplayer.Streams.FFmpeg do
      Tvplayer.Streams.FFmpeg.kill_channel_orphans(state.output_dir)
    end

    cleanup_dir(state.output_dir)
    state
  end

  defp cleanup_dir(dir) do
    if File.dir?(dir) do
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
    end
  end

  defp playlist_ready?(path) do
    case File.read(path) do
      {:ok, contents} ->
        # Wait until there is enough history that the player can sit
        # ~2 segments behind the live edge without hitting a missing file.
        # temp_file HLS flag guarantees only complete segments appear here.
        segment_count = Regex.scan(~r/\.(?:ts|m4s)\b/, contents) |> length()

        String.contains?(contents, "#EXTINF") and segment_count >= 2

      _ ->
        false
    end
  end

  defp radio?(state) do
    # Heuristic: after ready, if playlist has no video segments we still play audio.
    # For UI we treat missing video track as radio once ready; LiveView can also infer
    # from channel tags. Keep false until ready.
    state.status == :ready and not File.exists?(Path.join(state.output_dir, "segment_00000.ts"))
  end

  defp broadcast(state) do
    message =
      {:stream_status,
       %{
         channel_uuid: state.channel_uuid,
         status: state.status,
         playlist_url: playlist_url(state.channel_uuid),
         error: state.error
       }}

    Phoenix.PubSub.broadcast(Tvplayer.PubSub, topic(state.channel_uuid), message)
    Phoenix.PubSub.broadcast(Tvplayer.PubSub, all_topic(), message)
  end
end
