defmodule Tvplayer.Streams.FFmpegSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :ffmpeg

  @tag :ffmpeg
  test "encodes synthetic 720p50 mpegts into HLS with planned flags" do
    ffmpeg = System.find_executable("ffmpeg")
    assert ffmpeg

    work =
      Path.join(System.tmp_dir!(), "tvplayer_ffmpeg_smoke_#{System.unique_integer([:positive])}")

    File.mkdir_p!(work)
    input = Path.join(work, "input.ts")
    playlist = Path.join(work, "index.m3u8")

    on_exit(fn -> File.rm_rf!(work) end)

    {_, 0} =
      System.cmd(
        ffmpeg,
        [
          "-y",
          "-f",
          "lavfi",
          "-i",
          "testsrc=size=1280x720:rate=50",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=1000:sample_rate=48000",
          "-t",
          "2",
          "-c:v",
          "mpeg2video",
          "-c:a",
          "mp2",
          input
        ],
        stderr_to_stdout: true
      )

    args =
      Tvplayer.Streams.FFmpeg.build_args(
        %{
          input_url: input,
          output_dir: work,
          playlist_path: playlist,
          channel_uuid: "smoke"
        },
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
        ],
        %Tvplayer.Streams.Probe.Result{
          has_video?: true,
          video_codec: "mpeg2video",
          pix_fmt: "yuv420p",
          width: 1280,
          height: 720,
          field_order: "progressive",
          audio_codec: "mp2"
        }
      )

    {output, status} = System.cmd(ffmpeg, args, stderr_to_stdout: true)
    assert status == 0, output
    assert File.exists?(playlist)
    assert File.read!(playlist) =~ "#EXTINF"
  end
end
