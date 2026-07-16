defmodule Tvplayer.Streams.FFmpegTest do
  use ExUnit.Case, async: false

  alias Tvplayer.Streams.FFmpeg
  alias Tvplayer.Streams.Probe
  alias Tvplayer.Streams.Probe.Result

  setup do
    Probe.ensure_table!()
    Probe.clear_for_test()
    :ok
  end

  defp base_opts do
    %{
      input_url: "http://example/stream",
      output_dir: "/tmp/hls/test",
      playlist_path: "/tmp/hls/test/index.m3u8",
      channel_uuid: "abc"
    }
  end

  defp base_config do
    [
      preset: "veryfast",
      crf: 20,
      maxrate: "6M",
      bufsize: "12M",
      audio_bitrate: "192k",
      hls_time: 2,
      hls_list_size: 30,
      keyframe_interval: 2,
      copy: :auto
    ]
  end

  defp h264_probe(attrs \\ []) do
    struct!(
      %Result{
        has_video?: true,
        video_codec: "h264",
        pix_fmt: "yuv420p",
        width: 1920,
        height: 1080,
        field_order: "progressive",
        audio_codec: "mp2",
        copy_blocked?: false
      },
      attrs
    )
  end

  defp mpeg2_probe(attrs \\ []) do
    struct!(
      %Result{
        has_video?: true,
        video_codec: "mpeg2video",
        pix_fmt: "yuv420p",
        width: 720,
        height: 576,
        field_order: "tt",
        audio_codec: "mp2",
        copy_blocked?: false
      },
      attrs
    )
  end

  test "build_args uses stream-copy for web-compatible H.264" do
    args = FFmpeg.build_args(base_opts(), base_config(), h264_probe())

    assert "copy" in args
    refute "libx264" in args
    refute "-vf" in args
    refute "-force_key_frames" in args
    assert "192k" in args
    assert "-hls_time" in args
    assert "2" in args
    assert "30" in args
  end

  test "build_args transcodes MPEG-2 with yadif and no scale under 1080p" do
    args = FFmpeg.build_args(base_opts(), base_config(), mpeg2_probe())

    assert "libx264" in args
    assert "4.1" in args
    assert "-sc_threshold" in args
    assert "0" in args
    assert "expr:gte(t,n_forced*2)" in args

    assert Enum.any?(
             args,
             &String.contains?(to_string(&1), "yadif=mode=send_frame:parity=auto:deint=all")
           )

    refute Enum.any?(args, &String.contains?(to_string(&1), "min(1920,iw)"))
    assert "+genpts+discardcorrupt" in args
    refute "low_delay" in args
    refute Enum.any?(args, &String.contains?(to_string(&1), "nobuffer"))
  end

  test "build_args scales only when width exceeds 1920" do
    probe = mpeg2_probe(width: 3840, height: 2160, field_order: "progressive")
    args = FFmpeg.build_args(base_opts(), base_config(), probe)

    assert Enum.any?(args, &String.contains?(to_string(&1), "min(1920,iw)"))
    refute Enum.any?(args, &String.contains?(to_string(&1), "yadif"))
  end

  test "build_args omits filters for progressive <=1080p transcode" do
    probe = mpeg2_probe(field_order: "progressive", width: 1280, height: 720)
    args = FFmpeg.build_args(base_opts(), base_config(), probe)

    refute "-vf" in args
  end

  test "build_args forces transcode when copy is blocked or disabled" do
    blocked = h264_probe(copy_blocked?: true)
    args = FFmpeg.build_args(base_opts(), base_config(), blocked)
    assert "libx264" in args
    refute "copy" in args

    args_off =
      FFmpeg.build_args(base_opts(), Keyword.put(base_config(), :copy, :off), h264_probe())

    assert "libx264" in args_off
    refute "copy" in args_off
  end

  test "build_args uses audio-only path without video filters" do
    probe = %Result{has_video?: false}
    args = FFmpeg.build_args(base_opts(), base_config(), probe)

    assert "-vn" in args
    refute "libx264" in args
    refute Enum.any?(args, &String.contains?(to_string(&1), "yadif"))
  end

  test "stop kills the OS ffmpeg process started via Port" do
    ffmpeg = System.find_executable("ffmpeg")
    assert ffmpeg

    work =
      Path.join(System.tmp_dir!(), "tvplayer_ffmpeg_kill_#{System.unique_integer([:positive])}")

    File.mkdir_p!(work)
    on_exit(fn -> File.rm_rf!(work) end)

    input = Path.join(work, "input.ts")

    {_, 0} =
      System.cmd(
        ffmpeg,
        [
          "-y",
          "-f",
          "lavfi",
          "-i",
          "testsrc=size=320x240:rate=25",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440:sample_rate=48000",
          "-t",
          "8",
          "-c:v",
          "mpeg2video",
          "-c:a",
          "mp2",
          input
        ],
        stderr_to_stdout: true
      )

    # Seed probe so init does not re-open the file via ffprobe.
    Probe.put_for_test(
      "killtest",
      mpeg2_probe(field_order: "progressive", width: 320, height: 240)
    )

    opts = %{
      channel_uuid: "killtest",
      input_url: input,
      output_dir: work,
      playlist_path: Path.join(work, "index.m3u8"),
      config: [
        ffmpeg_path: ffmpeg,
        preset: "ultrafast",
        crf: 28,
        maxrate: "1M",
        bufsize: "2M",
        audio_bitrate: "96k",
        hls_time: 2,
        copy: :auto
      ]
    }

    Process.flag(:trap_exit, true)
    assert {:ok, runner} = FFmpeg.start(opts)

    os_pid =
      case :sys.get_state(runner) do
        %{os_pid: pid} when is_integer(pid) -> pid
        other -> flunk("unexpected runner state: #{inspect(other)}")
      end

    assert FFmpeg.os_process_alive?(os_pid)

    assert :ok = FFmpeg.stop(runner)
    refute Process.alive?(runner)
    refute FFmpeg.os_process_alive?(os_pid)
  end

  test "kill_os_process terminates a lingering OS process" do
    port =
      Port.open(
        {:spawn_executable, "/bin/sleep"},
        [:binary, :exit_status, args: ["30"]]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    assert FFmpeg.os_process_alive?(os_pid)

    assert :ok = FFmpeg.kill_os_process(os_pid)
    refute FFmpeg.os_process_alive?(os_pid)

    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  test "prepare! sweeps orphans matching hls_root" do
    ffmpeg = System.find_executable("ffmpeg")
    assert ffmpeg

    hls_root =
      Path.join(System.tmp_dir!(), "tvplayer_hls_sweep_#{System.unique_integer([:positive])}")

    out = Path.join(hls_root, "chan123")
    File.mkdir_p!(out)
    on_exit(fn -> File.rm_rf!(hls_root) end)

    segment = Path.join(out, "segment_%05d.ts")
    playlist = Path.join(out, "index.m3u8")

    port =
      Port.open(
        {:spawn_executable, ffmpeg},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [
            "-hide_banner",
            "-loglevel",
            "error",
            "-re",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=160x120:rate=5",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-t",
            "60",
            "-f",
            "hls",
            "-hls_time",
            "2",
            "-hls_segment_filename",
            segment,
            playlist
          ]
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    Process.sleep(200)
    assert FFmpeg.os_process_alive?(os_pid)

    assert :ok = FFmpeg.prepare!(hls_root)
    refute FFmpeg.os_process_alive?(os_pid)

    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  test "kill_orphans returns confirmed-dead count" do
    ffmpeg = System.find_executable("ffmpeg")
    assert ffmpeg

    hls_root =
      Path.join(System.tmp_dir!(), "tvplayer_hls_count_#{System.unique_integer([:positive])}")

    out = Path.join(hls_root, "orphan-chan")
    File.mkdir_p!(out)
    on_exit(fn -> File.rm_rf!(hls_root) end)

    {port, os_pid} = spawn_hls_ffmpeg(ffmpeg, out)
    Process.sleep(200)
    assert FFmpeg.os_process_alive?(os_pid)

    assert FFmpeg.kill_orphans(hls_root) == 1
    refute FFmpeg.os_process_alive?(os_pid)
    assert FFmpeg.kill_orphans(hls_root) == 0

    close_port(port)
  end

  test "kill_orphans_except keeps live channel writers and kills others" do
    ffmpeg = System.find_executable("ffmpeg")
    assert ffmpeg

    hls_root =
      Path.join(System.tmp_dir!(), "tvplayer_hls_except_#{System.unique_integer([:positive])}")

    live_out = Path.join(hls_root, "live-chan")
    orphan_out = Path.join(hls_root, "orphan-chan")
    File.mkdir_p!(live_out)
    File.mkdir_p!(orphan_out)
    on_exit(fn -> File.rm_rf!(hls_root) end)

    {live_port, live_pid} = spawn_hls_ffmpeg(ffmpeg, live_out)
    {orphan_port, orphan_pid} = spawn_hls_ffmpeg(ffmpeg, orphan_out)
    Process.sleep(200)

    assert FFmpeg.os_process_alive?(live_pid)
    assert FFmpeg.os_process_alive?(orphan_pid)

    assert FFmpeg.kill_orphans_except(hls_root, ["live-chan"]) == 1
    assert FFmpeg.os_process_alive?(live_pid)
    refute FFmpeg.os_process_alive?(orphan_pid)

    assert :ok = FFmpeg.kill_os_process(live_pid)
    refute FFmpeg.os_process_alive?(live_pid)

    close_port(live_port)
    close_port(orphan_port)
  end

  defp spawn_hls_ffmpeg(ffmpeg, out) do
    segment = Path.join(out, "segment_%05d.ts")
    playlist = Path.join(out, "index.m3u8")

    port =
      Port.open(
        {:spawn_executable, ffmpeg},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: [
            "-hide_banner",
            "-loglevel",
            "error",
            "-re",
            "-f",
            "lavfi",
            "-i",
            "testsrc=size=160x120:rate=5",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:sample_rate=48000",
            "-c:v",
            "libx264",
            "-preset",
            "ultrafast",
            "-t",
            "60",
            "-f",
            "hls",
            "-hls_time",
            "2",
            "-hls_segment_filename",
            segment,
            playlist
          ]
        ]
      )

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    {port, os_pid}
  end

  defp close_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end
end
