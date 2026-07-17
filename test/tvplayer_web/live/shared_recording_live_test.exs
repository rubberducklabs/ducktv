defmodule TvplayerWeb.SharedRecordingLiveTest do
  use TvplayerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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
      subtitle: "Nachrichten",
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

  test "renders shared player when web version is ready", %{conn: conn} do
    path = Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "ready-mp4")

    token = ShareLink.sign("rec-done")
    {:ok, view, _html} = live(conn, ~p"/share/#{token}")

    assert has_element?(view, "#shared-recording-title", "ZIB")
    assert has_element?(view, "#shared-video-rec-done")
    assert has_element?(view, "#share-download-btn")
  end

  test "shows error when web version is missing", %{conn: conn} do
    token = ShareLink.sign("rec-done")
    {:ok, view, _html} = live(conn, ~p"/share/#{token}")

    assert has_element?(view, "#share-error")
    assert render(view) =~ "Web-Version"
  end

  test "shows error for invalid token", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/share/bad-token")
    assert has_element?(view, "#share-error")
    assert render(view) =~ "ungültig"
  end
end
