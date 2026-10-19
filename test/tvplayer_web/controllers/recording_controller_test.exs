defmodule TvplayerWeb.RecordingControllerTest do
  use TvplayerWeb.ConnCase, async: false

  alias Tvplayer.Recordings.Transcoder
  alias Tvplayer.Tvheadend.{Cache, Channel, Recording}

  setup do
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

    Cache.load_fixture([channel], %{}, %{}, [completed, scheduled])
    Transcoder.delete_output("rec-done")

    previous = Application.get_env(:tvplayer, :tvheadend)

    Req.Test.stub(TvplayerWeb.RecordingControllerTest.DvrFile, fn conn ->
      assert conn.request_path == "/dvrfile/rec-done"

      conn
      |> Plug.Conn.put_resp_content_type("video/mp2t")
      |> Req.Test.text("mpegts-bytes")
    end)

    Application.put_env(
      :tvplayer,
      :tvheadend,
      Keyword.merge(previous || [], plug: {Req.Test, TvplayerWeb.RecordingControllerTest.DvrFile})
    )

    on_exit(fn ->
      Application.put_env(:tvplayer, :tvheadend, previous)
      Transcoder.delete_output("rec-done")
    end)

    :ok
  end

  test "downloads completed recording file", %{conn: conn} do
    conn = get(conn, ~p"/recordings/rec-done/download")

    assert conn.status == 200
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="ZIB.ts")]
    assert get_resp_header(conn, "content-length") == ["12"]
    assert conn.resp_body == "mpegts-bytes"
  end

  test "downloads compressed variant when available", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "compressed-mp4")

    conn = get(conn, ~p"/recordings/rec-done/download?variant=compressed")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["video/mp4"]
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="ZIB.mp4")]
    assert conn.resp_body == "compressed-mp4"
  end

  test "returns 404 for compressed variant when missing", %{conn: conn} do
    conn = get(conn, ~p"/recordings/rec-done/download?variant=compressed")
    assert conn.status == 404
  end

  test "serves the hls playlist and a segment", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "web-mp4")

    dir = Tvplayer.Recordings.Hls.dir("rec-done")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "index.m3u8"), "#EXTM3U\n#EXT-X-ENDLIST\nseg_00000.ts\n")
    File.write!(Path.join(dir, "seg_00000.ts"), "segment-bytes")

    playlist = get(conn, ~p"/recordings/rec-done/hls/index.m3u8")
    assert playlist.status == 200
    assert get_resp_header(playlist, "content-type") == ["application/vnd.apple.mpegurl"]
    assert playlist.resp_body =~ "seg_00000.ts"

    segment = get(conn, ~p"/recordings/rec-done/hls/seg_00000.ts")
    assert segment.status == 200
    assert get_resp_header(segment, "content-type") == ["video/mp2t"]
    assert segment.resp_body == "segment-bytes"
  end

  test "rejects hls files outside the playlist", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "web-mp4")

    conn = get(conn, ~p"/recordings/rec-done/hls/other.mp4")
    assert conn.status == 404
  end

  test "returns 404 for hls when the web version is missing", %{conn: conn} do
    conn = get(conn, ~p"/recordings/rec-done/hls/index.m3u8")
    assert conn.status == 404
  end

  test "resumes a compressed download from a byte range", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, String.duplicate("a", 100) <> "TAIL")

    conn =
      conn
      |> put_req_header("range", "bytes=-4")
      |> get(~p"/recordings/rec-done/download?variant=compressed")

    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 100-103/104"]
    assert conn.resp_body == "TAIL"
  end

  describe "original download from a mounted recordings directory" do
    setup do
      root =
        Path.join(System.tmp_dir!(), "tvplayer-recordings-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      File.write!(Path.join(root, "ZIB.ts"), "local-mpegts-bytes")

      previous = Application.get_env(:tvplayer, :recording_files)
      Application.put_env(:tvplayer, :recording_files, local_root: root, tvheadend_root: "/video")

      on_exit(fn ->
        Application.put_env(:tvplayer, :recording_files, previous || [])
        File.rm_rf!(root)
      end)

      :ok
    end

    test "sends the file from disk with range support", %{conn: conn} do
      conn = get(conn, ~p"/recordings/rec-done/download")

      assert conn.status == 200
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "content-type") == ["video/mp2t"]
      assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="ZIB.ts")]
      assert conn.resp_body == "local-mpegts-bytes"
    end

    test "resumes an open-ended range without a slice cap", %{conn: conn} do
      conn =
        conn
        |> put_req_header("range", "bytes=6-")
        |> get(~p"/recordings/rec-done/download")

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") == ["bytes 6-17/18"]
      assert conn.resp_body == "mpegts-bytes"
    end
  end

  test "returns 404 for non-downloadable recording", %{conn: conn} do
    conn = get(conn, ~p"/recordings/rec-scheduled/download")
    assert conn.status == 404
  end

  test "returns 404 for unknown uuid", %{conn: conn} do
    conn = get(conn, ~p"/recordings/missing/download")
    assert conn.status == 404
  end
end
