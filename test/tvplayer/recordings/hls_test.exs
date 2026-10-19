defmodule Tvplayer.Recordings.HlsTest do
  use ExUnit.Case, async: false

  alias Tvplayer.Recordings.{Hls, Transcoder}

  setup do
    uuid = "hls#{System.unique_integer([:positive])}"
    on_exit(fn -> Transcoder.delete_output(uuid) end)
    %{uuid: uuid}
  end

  test "cuts an existing mp4 into a vod playlist without encoding again", %{uuid: uuid} do
    mp4 = Transcoder.output_path(uuid)
    File.mkdir_p!(Path.dirname(mp4))

    {_, 0} =
      System.cmd(
        "ffmpeg",
        [
          "-hide_banner",
          "-loglevel",
          "error",
          "-y",
          "-f",
          "lavfi",
          "-i",
          "testsrc=size=160x120:rate=25",
          "-f",
          "lavfi",
          "-i",
          "sine=frequency=440",
          "-t",
          "2",
          "-c:v",
          "libx264",
          "-pix_fmt",
          "yuv420p",
          "-g",
          "50",
          "-c:a",
          "aac",
          "-shortest",
          "-movflags",
          "+faststart",
          mp4
        ]
      )

    assert Hls.ensure(uuid) == :ok

    playlist = File.read!(Path.join(Hls.dir(uuid), "index.m3u8"))
    assert playlist =~ "#EXT-X-PLAYLIST-TYPE:VOD"
    assert playlist =~ "#EXT-X-ENDLIST"
    assert playlist =~ "seg_00000.ts"
    refute playlist =~ "#EXT-X-MAP"
    assert {:ok, _segment} = Hls.path(uuid, "seg_00000.ts")
    refute Hls.valid_file?("init.mp4")

    # A playlist left over from the fMP4 cut is rebuilt. Players ignore the
    # MP4 edit list on those segments, which puts the picture behind the sound.
    File.write!(Path.join(Hls.dir(uuid), "index.m3u8"), "#EXTM3U\n#EXT-X-MAP:URI=\"init.mp4\"\n")
    assert Hls.ensure(uuid) == :ok
    rebuilt = File.read!(Path.join(Hls.dir(uuid), "index.m3u8"))
    assert rebuilt =~ "seg_00000.ts"
    refute rebuilt =~ "#EXT-X-MAP"

    assert Hls.path(uuid, "../#{uuid}.mp4") == :error
  end
end
