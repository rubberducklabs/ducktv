defmodule Tvplayer.Streams.FakeRunner do
  @moduledoc false
  @behaviour Tvplayer.Streams.Runner

  @impl true
  def start(opts) do
    File.mkdir_p!(opts.output_dir)

    pid =
      spawn_link(fn ->
        File.write!(opts.playlist_path, """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:6
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:6.0,
        segment_00000.ts
        #EXTINF:6.0,
        segment_00001.ts
        #EXTINF:6.0,
        segment_00002.ts
        #EXTINF:6.0,
        segment_00003.ts
        """)

        for i <- 0..3 do
          name = "segment_" <> String.pad_leading(Integer.to_string(i), 5, "0") <> ".ts"
          File.write!(Path.join(opts.output_dir, name), :crypto.strong_rand_bytes(32))
        end

        receive do
          :stop -> :ok
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
