defmodule Tvplayer.Recordings.TranscoderTest do
  use ExUnit.Case, async: false

  alias Tvplayer.Recordings.Transcoder
  alias Tvplayer.Tvheadend.{Cache, Channel, Recording}

  setup do
    root =
      Application.get_env(:tvplayer, :transcodes, [])
      |> Keyword.get(:root, "tmp/transcodes_test")
      |> Path.expand()

    File.rm_rf!(root)
    File.mkdir_p!(root)

    channel = %Channel{
      uuid: "live-channel",
      name: "ORF 1",
      number: 1,
      enabled: true,
      icon_path: nil,
      tags: [],
      services: []
    }

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    completed = %Recording{
      uuid: "rec-done",
      title: "ZIB",
      subtitle: nil,
      channel_uuid: "live-channel",
      channel_name: "ORF 1",
      starts_at: DateTime.add(now, -7200, :second),
      ends_at: DateTime.add(now, -3600, :second),
      start_extra: 0,
      stop_extra: 0,
      sched_status: "completed",
      status: "Completed OK",
      filesize: 12,
      url: "dvrfile/rec-done",
      filename: "/video/ZIB.ts",
      enabled: true,
      event_id: nil,
      file_removed: false,
      state: :completed
    }

    completed2 = %{completed | uuid: "rec-done-2", title: "ZIB 2", url: "dvrfile/rec-done-2"}

    scheduled = %Recording{
      uuid: "rec-scheduled",
      title: "Tatort",
      subtitle: nil,
      channel_uuid: "live-channel",
      channel_name: "ORF 1",
      starts_at: DateTime.add(now, 3600, :second),
      ends_at: DateTime.add(now, 7200, :second),
      start_extra: 0,
      stop_extra: 0,
      sched_status: "scheduled",
      status: "Scheduled for recording",
      filesize: 0,
      url: nil,
      filename: nil,
      enabled: true,
      event_id: nil,
      file_removed: false,
      state: :scheduled
    }

    Cache.load_fixture([channel], %{}, %{}, [completed, completed2, scheduled])

    # Reset transcoder state between tests by deleting outputs and cancelling jobs.
    for uuid <- ["rec-done", "rec-done-2", "rec-scheduled"] do
      Transcoder.delete_output(uuid)
    end

    on_exit(fn ->
      for uuid <- ["rec-done", "rec-done-2", "rec-scheduled"] do
        Transcoder.delete_output(uuid)
      end
    end)

    %{completed: completed, completed2: completed2}
  end

  test "runs a single job and reports done", %{completed: completed} do
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Transcoder.topic())
    uuid = completed.uuid

    assert :queued = Transcoder.request(uuid)

    assert_receive {:transcode, ^uuid, :queued}, 500
    assert_receive {:transcode, ^uuid, {:running, percent}} when percent >= 0, 500

    assert_receive {:transcode, ^uuid, :done}, 1_000
    assert Transcoder.status(uuid) == :done
    assert File.exists?(Transcoder.output_path(uuid))
  end

  test "queues a second job until the first finishes", %{
    completed: completed,
    completed2: completed2
  } do
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Transcoder.topic())
    uuid1 = completed.uuid
    uuid2 = completed2.uuid

    assert :queued = Transcoder.request(uuid1)
    assert :queued = Transcoder.request(uuid2)

    assert_receive {:transcode, ^uuid1, :done}, 1_000
    assert_receive {:transcode, ^uuid2, {:running, _}}, 1_000
    assert_receive {:transcode, ^uuid2, :done}, 1_000
  end

  test "duplicate request is a no-op while running", %{completed: completed} do
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Transcoder.topic())
    uuid = completed.uuid

    assert :queued = Transcoder.request(uuid)
    assert_receive {:transcode, ^uuid, {:running, _}}, 500

    assert {:running, percent} = Transcoder.request(uuid)
    assert is_integer(percent)
  end

  test "detects existing output file as done", %{completed: completed} do
    path = Transcoder.output_path(completed.uuid)
    File.write!(path, "already-done")
    assert Transcoder.status(completed.uuid) == :done
    assert Transcoder.request(completed.uuid) == :done
  end

  test "fails for non-downloadable recordings" do
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Transcoder.topic())

    assert :queued = Transcoder.request("rec-scheduled")
    assert_receive {:transcode, "rec-scheduled", {:failed, :not_downloadable}}, 500
  end

  test "delete_output removes file and status", %{completed: completed} do
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Transcoder.topic())
    uuid = completed.uuid
    Transcoder.request(uuid)
    assert_receive {:transcode, ^uuid, :done}, 1_000

    assert :ok = Transcoder.delete_output(uuid)
    refute File.exists?(Transcoder.output_path(uuid))
    assert Transcoder.status(uuid) == nil
  end

  test "cancel stops a running job", %{completed: completed} do
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Transcoder.topic())
    uuid = completed.uuid

    assert :queued = Transcoder.request(uuid)
    assert_receive {:transcode, ^uuid, {:running, _}}, 500

    assert :ok = Transcoder.cancel(uuid)
    assert_receive {:transcode, ^uuid, nil}, 500
    assert Transcoder.status(uuid) == nil
    refute File.exists?(Transcoder.output_path(uuid))
  end

  test "cancel removes a queued job without starting it", %{
    completed: completed,
    completed2: completed2
  } do
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Transcoder.topic())
    uuid1 = completed.uuid
    uuid2 = completed2.uuid

    assert :queued = Transcoder.request(uuid1)
    assert :queued = Transcoder.request(uuid2)
    assert_receive {:transcode, ^uuid1, {:running, _}}, 500

    assert :ok = Transcoder.cancel(uuid2)
    assert_receive {:transcode, ^uuid2, nil}, 500
    assert Transcoder.status(uuid2) == nil

    assert_receive {:transcode, ^uuid1, :done}, 1_000
    refute_receive {:transcode, ^uuid2, {:running, _}}, 200
  end
end

defmodule Tvplayer.Recordings.FFmpegRunnerTest do
  use ExUnit.Case, async: true

  alias Tvplayer.Recordings.FFmpegRunner

  test "parses out_time_us progress lines" do
    assert FFmpegRunner.parse_progress_line("out_time_us=1500000") == {:out_time_us, 1_500_000}
    # out_time_ms is a misnomer in ffmpeg — value is microseconds, not ms.
    assert FFmpegRunner.parse_progress_line("out_time_ms=1500000") == {:out_time_us, 1_500_000}
    assert FFmpegRunner.parse_progress_line("progress=end") == :progress_end
    assert FFmpegRunner.parse_progress_line("progress=continue") == :progress_continue
    assert FFmpegRunner.parse_progress_line("frame=1901") == :progress_noise
    assert FFmpegRunner.parse_progress_line("bitrate=1.2kbits/s") == :progress_noise
  end

  test "build_args includes threads, crf, faststart, and explicit mp4 format" do
    opts = %{
      input_url: "http://user:pass@tvh/dvrfile/abc",
      part_path: "/tmp/abc.mp4.part"
    }

    args = FFmpegRunner.build_args(opts, threads: 4, crf: 23, preset: "veryfast")

    assert "-threads" in args
    assert "4" in args
    assert "-crf" in args
    assert "23" in args
    assert "+faststart" in args
    assert "pipe:1" in args
    assert "-f" in args
    assert "mp4" in args
    assert opts.part_path in args
  end
end
