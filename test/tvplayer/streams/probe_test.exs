defmodule Tvplayer.Streams.ProbeTest do
  use ExUnit.Case, async: false

  alias Tvplayer.Streams.Probe
  alias Tvplayer.Streams.Probe.Result

  setup do
    Probe.ensure_table!()
    Probe.clear_for_test()
    :ok
  end

  @h264_json """
  {
    "streams": [
      {
        "index": 0,
        "codec_name": "h264",
        "codec_type": "video",
        "profile": "High",
        "width": 1920,
        "height": 1080,
        "pix_fmt": "yuv420p",
        "field_order": "progressive"
      },
      {
        "index": 1,
        "codec_name": "mp2",
        "codec_type": "audio"
      }
    ]
  }
  """

  @mpeg2_json """
  {
    "streams": [
      {
        "index": 0,
        "codec_name": "mpeg2video",
        "codec_type": "video",
        "width": 720,
        "height": 576,
        "pix_fmt": "yuv420p",
        "field_order": "tt"
      },
      {
        "index": 1,
        "codec_name": "mp2",
        "codec_type": "audio"
      }
    ]
  }
  """

  @audio_only_json """
  {
    "streams": [
      {
        "index": 0,
        "codec_name": "mp2",
        "codec_type": "audio"
      }
    ]
  }
  """

  test "parse_ffprobe_json extracts H.264 progressive metadata" do
    result = Probe.parse_ffprobe_json(@h264_json)

    assert result.has_video?
    assert result.video_codec == "h264"
    assert result.pix_fmt == "yuv420p"
    assert result.width == 1920
    assert result.height == 1080
    assert result.field_order == "progressive"
    assert result.audio_codec == "mp2"
    refute result.copy_blocked?
  end

  test "parse_ffprobe_json extracts interlaced MPEG-2 metadata" do
    result = Probe.parse_ffprobe_json(@mpeg2_json)

    assert result.video_codec == "mpeg2video"
    assert result.field_order == "tt"
    assert Probe.interlaced?(result)
    refute Probe.copy_eligible?(result)
  end

  test "parse_ffprobe_json handles audio-only streams" do
    result = Probe.parse_ffprobe_json(@audio_only_json)

    refute result.has_video?
    assert result.audio_codec == "mp2"
    refute Probe.copy_eligible?(result)
  end

  test "parse_ffprobe_json falls back on invalid JSON" do
    result = Probe.parse_ffprobe_json("not-json")
    assert result.has_video?
    assert is_nil(result.video_codec)
  end

  test "copy_eligible? allows H.264 yuv420p <=1080p" do
    result = Probe.parse_ffprobe_json(@h264_json)
    assert Probe.copy_eligible?(result, copy: :auto)
    refute Probe.copy_eligible?(result, copy: :off)
  end

  test "copy_eligible? rejects blocked, tall, or non-420p sources" do
    base = Probe.parse_ffprobe_json(@h264_json)

    refute Probe.copy_eligible?(%{base | copy_blocked?: true})
    refute Probe.copy_eligible?(%{base | height: 2160})
    refute Probe.copy_eligible?(%{base | pix_fmt: "yuv422p"})
    refute Probe.copy_eligible?(%{base | video_codec: "hevc"})
  end

  test "interlaced? and needs_scale? decisions" do
    progressive = %Result{has_video?: true, field_order: "progressive", width: 1280}
    refute Probe.interlaced?(progressive)
    refute Probe.needs_scale?(progressive)

    interlaced = %Result{has_video?: true, field_order: "tt", width: 720}
    assert Probe.interlaced?(interlaced)

    unknown = %Result{has_video?: true, field_order: nil, width: nil}
    assert Probe.interlaced?(unknown)
    assert Probe.needs_scale?(unknown)

    uhd = %Result{has_video?: true, field_order: "progressive", width: 3840}
    assert Probe.needs_scale?(uhd)
  end

  test "get caches probe results per channel" do
    result = Probe.parse_ffprobe_json(@h264_json)
    Probe.put_for_test("chan-a", result)

    assert Probe.get("chan-a", "http://unused") == result
  end

  test "block_copy sets demotion flag on cached entry" do
    result = Probe.parse_ffprobe_json(@h264_json)
    Probe.put_for_test("chan-b", result)

    updated = Probe.block_copy("chan-b")
    assert updated.copy_blocked?
    assert Probe.get("chan-b", "http://unused").copy_blocked?
    refute Probe.copy_eligible?(updated)
  end

  test "block_copy creates a blocked entry when cache is empty" do
    updated = Probe.block_copy("missing-chan")
    assert updated.copy_blocked?
    assert Probe.get("missing-chan", "http://unused").copy_blocked?
  end

  test "get does not permanently cache inconclusive probe failures" do
    Probe.put_for_test("chan-unknown", %Result{has_video?: true})

    # Without a reachable URL this will fail again, but the stale unknown
    # entry must be cleared so a later successful probe can replace it.
    _ = Probe.get("chan-unknown", "http://127.0.0.1:1/nope")
    assert :ets.lookup(:tvplayer_stream_probe, "chan-unknown") == []
  end
end
