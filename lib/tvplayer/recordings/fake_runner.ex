defmodule Tvplayer.Recordings.FakeRunner do
  @moduledoc false
  @behaviour Tvplayer.Recordings.Runner

  @impl true
  def start(opts) do
    notify = opts.notify
    uuid = opts.uuid
    output_path = opts.output_path
    part_path = opts.part_path
    fail? = Map.get(opts, :fail?, false) or Keyword.get(Map.get(opts, :config, []), :fail?, false)

    File.mkdir_p!(Path.dirname(part_path))

    pid =
      spawn(fn ->
        send(notify, {:transcode_progress, uuid, 0})
        send(notify, {:transcode_progress, uuid, 42})
        send(notify, {:transcode_progress, uuid, 85})

        receive do
          :stop ->
            _ = File.rm(part_path)
            :ok
        after
          30 ->
            if fail? do
              _ = File.rm(part_path)
              send(notify, {:transcode_failed, uuid, :fake_failure})
            else
              File.write!(part_path, "fake-mp4-bytes")
              File.rename!(part_path, output_path)
              send(notify, {:transcode_progress, uuid, 100})
              send(notify, {:transcode_done, uuid})
            end
        end
      end)

    {:ok, pid}
  end

  @impl true
  def stop(pid) when is_pid(pid) do
    if Process.alive?(pid), do: send(pid, :stop)
    :ok
  end
end
