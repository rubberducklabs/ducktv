defmodule Tvplayer.Recordings.Transcoder do
  @moduledoc """
  Single-worker queue that converts DVR recordings into compressed MP4 files.

  Only one ffmpeg job runs at a time. Status updates are broadcast on the
  `"transcodes"` PubSub topic as `{:transcode, uuid, status}`.
  """

  use GenServer

  require Logger

  alias Tvplayer.Recordings.FFmpegRunner
  alias Tvplayer.Tvheadend.{Cache, Client, Recording}

  @topic "transcodes"
  @progress_throttle_ms 1_000

  defstruct queue: :queue.new(),
            current: nil,
            statuses: %{},
            runner_pid: nil,
            last_progress_at: %{}

  @type status ::
          :queued
          | {:running, non_neg_integer()}
          | :done
          | {:failed, term()}

  # —— Public API ——

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def topic, do: @topic

  @doc """
  Enqueue a recording for transcoding. Returns the current status.
  Duplicate requests for the same UUID are no-ops.
  """
  def request(uuid) when is_binary(uuid) do
    GenServer.call(__MODULE__, {:request, uuid})
  end

  def status(uuid) when is_binary(uuid) do
    GenServer.call(__MODULE__, {:status, uuid})
  end

  def statuses do
    GenServer.call(__MODULE__, :statuses)
  end

  def cancel(uuid) when is_binary(uuid) do
    GenServer.call(__MODULE__, {:cancel, uuid})
  end

  def output_path(uuid) when is_binary(uuid) do
    Path.join(root(), "#{uuid}.mp4")
  end

  def part_path(uuid) when is_binary(uuid) do
    Path.join(root(), "#{uuid}.mp4.part")
  end

  def delete_output(uuid) when is_binary(uuid) do
    GenServer.call(__MODULE__, {:delete_output, uuid})
  end

  def ready?(uuid) when is_binary(uuid) do
    case status(uuid) do
      :done -> true
      _ -> false
    end
  end

  # —— GenServer ——

  @impl true
  def init(_opts) do
    File.mkdir_p!(root())
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:request, uuid}, _from, state) do
    case lookup_status(state, uuid) do
      :done ->
        {:reply, :done, state}

      :queued ->
        {:reply, :queued, state}

      {:running, percent} ->
        {:reply, {:running, percent}, state}

      _other ->
        # Reply immediately as :queued; start ffmpeg after the reply so the
        # LiveView is not blocked on ffprobe / Port.open.
        state = enqueue(state, uuid)
        {:reply, :queued, state, {:continue, :maybe_start}}
    end
  end

  def handle_call({:status, uuid}, _from, state) do
    {:reply, lookup_status(state, uuid), state}
  end

  def handle_call(:statuses, _from, state) do
    {:reply, visible_statuses(state), state}
  end

  def handle_call({:cancel, uuid}, _from, state) do
    state = do_cancel(state, uuid)
    broadcast(uuid, nil)
    {:reply, :ok, state, {:continue, :maybe_start}}
  end

  def handle_call({:delete_output, uuid}, _from, state) do
    state = do_cancel(state, uuid)
    _ = File.rm(output_path(uuid))
    _ = File.rm(part_path(uuid))
    state = put_in(state.statuses, Map.delete(state.statuses, uuid))
    broadcast(uuid, nil)
    {:reply, :ok, state, {:continue, :maybe_start}}
  end

  @impl true
  def handle_continue(:maybe_start, state) do
    {:noreply, maybe_start_next(state)}
  end

  @impl true
  def handle_info({:transcode_progress, uuid, percent}, state) do
    case state.current do
      ^uuid ->
        now = System.monotonic_time(:millisecond)
        last = Map.get(state.last_progress_at, uuid, 0)

        if now - last >= @progress_throttle_ms or percent in [0, 100] do
          status = {:running, percent}
          state = put_status(state, uuid, status)
          state = put_in(state.last_progress_at, Map.put(state.last_progress_at, uuid, now))
          broadcast(uuid, status)
          {:noreply, state}
        else
          state = put_status(state, uuid, {:running, percent})
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:transcode_done, uuid}, state) do
    case state.current do
      ^uuid ->
        state =
          state
          |> clear_runner()
          |> put_status(uuid, :done)
          |> Map.update!(:last_progress_at, &Map.delete(&1, uuid))

        broadcast(uuid, :done)
        {:noreply, state, {:continue, :maybe_start}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:transcode_failed, uuid, reason}, state) do
    case state.current do
      ^uuid ->
        Logger.warning("transcode failed for #{uuid}: #{inspect(reason)}")
        status = {:failed, reason}

        state =
          state
          |> clear_runner()
          |> put_status(uuid, status)
          |> Map.update!(:last_progress_at, &Map.delete(&1, uuid))

        _ = File.rm(part_path(uuid))
        broadcast(uuid, status)
        {:noreply, state, {:continue, :maybe_start}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %{runner_pid: pid} = state) do
    uuid = state.current

    if uuid && reason != :normal do
      Logger.warning("transcode runner crashed for #{uuid}: #{inspect(reason)}")
      status = {:failed, reason}

      state =
        state
        |> clear_runner()
        |> put_status(uuid, status)

      _ = File.rm(part_path(uuid))
      broadcast(uuid, status)
      {:noreply, state, {:continue, :maybe_start}}
    else
      {:noreply, clear_runner(state)}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # —— Internals ——

  defp enqueue(state, uuid) do
    state =
      state
      |> put_status(uuid, :queued)
      |> Map.update!(:queue, &:queue.in(uuid, &1))

    broadcast(uuid, :queued)
    state
  end

  defp maybe_start_next(%{current: current} = state) when not is_nil(current), do: state

  defp maybe_start_next(state) do
    case :queue.out(state.queue) do
      {{:value, uuid}, queue} ->
        state = %{state | queue: queue}
        start_job(state, uuid)

      {:empty, _} ->
        state
    end
  end

  defp start_job(state, uuid) do
    case Cache.recording(uuid) do
      %Recording{} = recording ->
        if Recording.downloadable?(recording) do
          do_start(state, recording)
        else
          status = {:failed, :not_downloadable}
          state = put_status(state, uuid, status)
          broadcast(uuid, status)
          maybe_start_next(state)
        end

      nil ->
        status = {:failed, :not_found}
        state = put_status(state, uuid, status)
        broadcast(uuid, status)
        maybe_start_next(state)
    end
  end

  defp do_start(state, %Recording{} = recording) do
    config = config()
    runner = Keyword.get(config, :runner, FFmpegRunner)
    input_url = Client.dvrfile_url(recording)
    # Prefer schedule duration for progress (instant). Optional ffprobe is slow
    # over HTTP and blocked the LiveView when done inside GenServer.call.
    duration_ms = schedule_duration_ms(recording)

    opts = %{
      uuid: recording.uuid,
      input_url: input_url,
      output_path: output_path(recording.uuid),
      part_path: part_path(recording.uuid),
      notify: self(),
      duration_ms: duration_ms,
      config: config
    }

    case runner.start(opts) do
      {:ok, pid} ->
        Process.monitor(pid)
        status = {:running, 0}

        state =
          state
          |> put_status(recording.uuid, status)
          |> Map.put(:current, recording.uuid)
          |> Map.put(:runner_pid, pid)

        broadcast(recording.uuid, status)
        state

      {:error, reason} ->
        status = {:failed, reason}
        state = put_status(state, recording.uuid, status)
        broadcast(recording.uuid, status)
        maybe_start_next(state)
    end
  end

  defp do_cancel(state, uuid) do
    cond do
      state.current == uuid ->
        stop_runner(state.runner_pid)
        _ = File.rm(part_path(uuid))

        state
        |> clear_runner()
        |> Map.update!(:statuses, &Map.delete(&1, uuid))
        |> Map.update!(:last_progress_at, &Map.delete(&1, uuid))

      true ->
        queue =
          state.queue
          |> :queue.to_list()
          |> Enum.reject(&(&1 == uuid))
          |> :queue.from_list()

        %{state | queue: queue, statuses: Map.delete(state.statuses, uuid)}
    end
  end

  defp stop_runner(nil), do: :ok

  defp stop_runner(pid) when is_pid(pid) do
    runner = Keyword.get(config(), :runner, FFmpegRunner)
    runner.stop(pid)
  end

  defp clear_runner(state) do
    %{state | current: nil, runner_pid: nil}
  end

  defp lookup_status(state, uuid) do
    cond do
      Map.has_key?(state.statuses, uuid) ->
        Map.fetch!(state.statuses, uuid)

      File.exists?(output_path(uuid)) ->
        :done

      true ->
        nil
    end
  end

  defp visible_statuses(state) do
    from_disk =
      root()
      |> Path.join("*.mp4")
      |> Path.wildcard()
      |> Enum.reduce(%{}, fn path, acc ->
        uuid = path |> Path.basename() |> Path.rootname()
        Map.put(acc, uuid, :done)
      end)

    Map.merge(from_disk, state.statuses)
  end

  defp put_status(state, uuid, status) do
    %{state | statuses: Map.put(state.statuses, uuid, status)}
  end

  defp broadcast(uuid, status) do
    Phoenix.PubSub.broadcast(Tvplayer.PubSub, @topic, {:transcode, uuid, status})
  end

  defp schedule_duration_ms(%Recording{} = recording) do
    seconds =
      DateTime.diff(recording.ends_at, recording.starts_at, :second) +
        (recording.start_extra || 0) * 60 +
        (recording.stop_extra || 0) * 60

    if seconds > 0, do: seconds * 1000, else: nil
  end

  defp config do
    Application.get_env(:tvplayer, :transcodes, [])
  end

  defp root do
    config()
    |> Keyword.get(:root, "tmp/transcodes")
    |> Path.expand()
  end
end
