defmodule TvplayerWeb.SharedRecordingControllerTest do
  use TvplayerWeb.ConnCase, async: false

  alias Tvplayer.Recordings.{ShareLink, Transcoder}
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

    Cache.load_fixture([channel], %{}, %{}, [completed])
    Transcoder.delete_output("rec-done")

    on_exit(fn -> Transcoder.delete_output("rec-done") end)
    :ok
  end

  test "serves shared media for valid token when web version exists", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "shared-mp4-bytes")

    token = ShareLink.sign("rec-done")
    conn = get(conn, ~p"/share/#{token}/media")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["video/mp4; charset=utf-8"]
    assert conn.resp_body == "shared-mp4-bytes"
  end

  test "downloads shared web version for valid token", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "shared-mp4-bytes")

    token = ShareLink.sign("rec-done")
    conn = get(conn, ~p"/share/#{token}/download")

    assert conn.status == 200

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="ZIB.mp4")
           ]

    assert conn.resp_body == "shared-mp4-bytes"
  end

  test "rejects invalid share token", %{conn: conn} do
    conn = get(conn, ~p"/share/not-a-real-token/media")
    assert conn.status == 404
  end

  test "rejects valid token when web version missing", %{conn: conn} do
    token = ShareLink.sign("rec-done")
    conn = get(conn, ~p"/share/#{token}/media")
    assert conn.status == 404
  end
end
