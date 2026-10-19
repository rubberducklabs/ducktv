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

  test "serves media with range support", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "0123456789")

    conn =
      conn
      |> put_req_header("range", "bytes=2-5")
      |> get(~p"/recordings/rec-done/media")

    assert conn.status == 206
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "content-range") == ["bytes 2-5/10"]
    assert conn.resp_body == "2345"
  end

  test "open-ended range returns one slice so playback can start", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    chunk = TvplayerWeb.RecordingMedia.range_chunk_bytes()
    size = chunk + 100
    File.write!(path, :binary.copy(<<0>>, size))

    conn =
      conn
      |> put_req_header("range", "bytes=0-")
      |> get(~p"/recordings/rec-done/media")

    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 0-#{chunk - 1}/#{size}"]
    assert get_resp_header(conn, "content-length") == ["#{chunk}"]
    assert byte_size(conn.resp_body) == chunk
    assert get_resp_header(conn, "content-type") == ["video/mp4"]
  end

  test "open-ended range continues from the requested offset", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    chunk = TvplayerWeb.RecordingMedia.range_chunk_bytes()
    size = chunk * 3
    File.write!(path, :binary.copy(<<0>>, size))

    conn =
      conn
      |> put_req_header("range", "bytes=#{chunk}-")
      |> get(~p"/recordings/rec-done/media")

    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes #{chunk}-#{chunk * 2 - 1}/#{size}"]
    assert byte_size(conn.resp_body) == chunk
  end

  test "short suffix range keeps the end of the file", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, String.duplicate("a", 100) <> "TAIL")

    conn =
      conn
      |> put_req_header("range", "bytes=-4")
      |> get(~p"/recordings/rec-done/media")

    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 100-103/104"]
    assert conn.resp_body == "TAIL"
  end

  test "serves full media when no range header", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "full-media")

    conn = get(conn, ~p"/recordings/rec-done/media")

    assert conn.status == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert conn.resp_body == "full-media"
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
