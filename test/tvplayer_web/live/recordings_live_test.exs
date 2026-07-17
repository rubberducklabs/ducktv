defmodule TvplayerWeb.RecordingsLiveTest do
  use TvplayerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tvplayer.Tvheadend.{Cache, Channel, Recording}

  setup do
    channel = %Channel{
      uuid: "live-channel",
      name: "ORF 1",
      number: 1,
      enabled: true,
      icon_path: "imagecache/1",
      tags: [],
      services: []
    }

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    scheduled = %Recording{
      uuid: "rec-scheduled",
      title: "Tatort",
      subtitle: nil,
      channel_uuid: "live-channel",
      channel_name: "ORF 1",
      starts_at: DateTime.add(now, 3600, :second),
      ends_at: DateTime.add(now, 7200, :second),
      start_extra: 5,
      stop_extra: 10,
      sched_status: "scheduled",
      status: "Scheduled for recording",
      filesize: 0,
      url: nil,
      filename: nil,
      enabled: true,
      event_id: 1,
      file_removed: false,
      state: :scheduled
    }

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
      filesize: 1_500_000_000,
      url: "dvrfile/rec-done",
      filename: "/video/ZIB.ts",
      enabled: true,
      event_id: nil,
      file_removed: false,
      state: :completed
    }

    failed = %Recording{
      uuid: "rec-failed",
      title: "Missed Show",
      subtitle: nil,
      channel_uuid: "live-channel",
      channel_name: "ORF 1",
      starts_at: DateTime.add(now, -10_800, :second),
      ends_at: DateTime.add(now, -9000, :second),
      start_extra: 0,
      stop_extra: 0,
      sched_status: "completedError",
      status: "Too many data errors",
      filesize: 0,
      url: nil,
      filename: nil,
      enabled: true,
      event_id: nil,
      file_removed: false,
      state: :failed
    }

    removed = %Recording{
      uuid: "rec-removed",
      title: "nano",
      subtitle: nil,
      channel_uuid: "live-channel",
      channel_name: "3sat HD",
      starts_at: DateTime.add(now, -14_400, :second),
      ends_at: DateTime.add(now, -12_600, :second),
      start_extra: 0,
      stop_extra: 0,
      sched_status: "completedError",
      status: "File missing",
      filesize: 0,
      url: nil,
      filename: nil,
      enabled: true,
      event_id: nil,
      file_removed: false,
      state: :removed
    }

    Cache.load_fixture([channel], %{}, %{}, [scheduled, completed, failed, removed])
    Tvplayer.Recordings.Transcoder.delete_output("rec-done")

    on_exit(fn -> Tvplayer.Recordings.Transcoder.delete_output("rec-done") end)

    :ok
  end

  test "renders recordings list and nav", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/recordings")

    assert html =~ "Aufnahmen"
    assert has_element?(view, "#recording-rec-scheduled")
    assert has_element?(view, "#recording-rec-done")
    assert has_element?(view, "#recordings-filter-all")
    assert has_element?(view, "#recordings-filter-removed")
    assert render(view) =~ "Tatort"
    assert render(view) =~ "Too many data errors"
    assert render(view) =~ "Gelöscht"
  end

  test "filters by state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recordings")

    view |> element("#recordings-filter-completed") |> render_click()
    assert has_element?(view, "#recording-rec-done")
    refute has_element?(view, "#recording-rec-scheduled")

    view |> element("#recordings-filter-removed") |> render_click()
    assert has_element?(view, "#recording-rec-removed")
    refute has_element?(view, "#recording-rec-failed")
    assert render(view) =~ "File missing"

    view |> element("#recordings-filter-scheduled") |> render_click()
    assert has_element?(view, "#recording-rec-scheduled")
    refute has_element?(view, "#recording-rec-done")
  end

  test "renders download menu for completed recordings", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recordings")

    assert has_element?(view, "#download-rec-done")
    assert has_element?(view, "#watch-rec-done")
    refute has_element?(view, "#download-rec-scheduled")
    assert has_element?(view, ~s|#download-menu-rec-done[phx-click-away="close_download_menu"]|)

    view |> element("#download-rec-done") |> render_click()
    assert has_element?(view, "#download-dropdown-rec-done")

    assert has_element?(
             view,
             "a#download-original-rec-done[href='/recordings/rec-done/download']"
           )

    assert has_element?(view, "#create-web-rec-done")

    render_click(view, "close_download_menu", %{})
    refute has_element?(view, "#download-dropdown-rec-done")
  end

  test "starts web version transcode from download menu", %{conn: conn} do
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Tvplayer.Recordings.Transcoder.topic())

    {:ok, view, _html} = live(conn, ~p"/recordings")

    view |> element("#download-rec-done") |> render_click()
    view |> element("#create-web-rec-done") |> render_click()

    assert has_element?(view, "#transcode-progress-rec-done")
    assert has_element?(view, "#cancel-transcode-rec-done")
    assert_receive {:transcode, "rec-done", :done}, 1_000
    assert render(view) =~ "Web-Version"
  end

  test "cancels an in-progress web version transcode", %{conn: conn} do
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Tvplayer.Recordings.Transcoder.topic())

    {:ok, view, _html} = live(conn, ~p"/recordings")

    view |> element("#download-rec-done") |> render_click()
    view |> element("#create-web-rec-done") |> render_click()
    assert has_element?(view, "#cancel-transcode-rec-done")

    view |> element("#cancel-transcode-rec-done") |> render_click()

    refute has_element?(view, "#transcode-progress-rec-done")
    refute has_element?(view, "#cancel-transcode-rec-done")
    assert render(view) =~ "Konvertierung abgebrochen"
  end

  test "opens player after watch when web version is ready", %{conn: conn} do
    path = Tvplayer.Recordings.Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "ready-mp4")

    {:ok, view, _html} = live(conn, ~p"/recordings")

    assert has_element?(view, "#watch-rec-done.tv-button-ready")
    assert has_element?(view, "#watch-rec-done", "Abspielen")
    refute has_element?(view, "#transcode-progress-rec-done")

    view |> element("#watch-rec-done") |> render_click()
    assert has_element?(view, "#recording-player-modal")
    assert has_element?(view, "#recording-video-rec-done")
    assert has_element?(view, "#recording-cinema-rec-done")
    assert has_element?(view, "#close-recording-player")
    assert has_element?(view, "#recording-seek-rec-done")
  end

  test "opens share modal with link when web version is ready", %{conn: conn} do
    path = Tvplayer.Recordings.Transcoder.output_path("rec-done")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "ready-mp4")

    {:ok, view, _html} = live(conn, ~p"/recordings")

    assert has_element?(view, "#share-rec-done")
    view |> element("#share-rec-done") |> render_click()

    assert has_element?(view, "#share-recording-modal")
    assert has_element?(view, "#share-link-input")
    assert has_element?(view, "#copy-share-link")
    assert has_element?(view, "#open-share-link")
  end

  test "watch starts transcode and opens player when done", %{conn: conn} do
    Tvplayer.Recordings.Transcoder.delete_output("rec-done")
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Tvplayer.Recordings.Transcoder.topic())

    {:ok, view, _html} = live(conn, ~p"/recordings")

    view |> element("#watch-rec-done") |> render_click()
    assert has_element?(view, "#transcode-progress-rec-done")

    assert_receive {:transcode, "rec-done", :done}, 1_000
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#recording-player-modal")
  end

  test "opens manual recording form with channel picker", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recordings")

    view |> element("#new-recording-btn") |> render_click()
    assert has_element?(view, "#recording-form")
    assert has_element?(view, "#channel-picker-search")

    view
    |> form("#recording-form", %{"q" => "ORF"})
    |> render_change()

    assert has_element?(view, "#pick-channel-live-channel")

    view |> element("#pick-channel-live-channel") |> render_click()
    assert has_element?(view, "#selected-channel-chip")
    assert render(view) =~ "ORF 1"
  end

  test "manual form requires channel", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recordings")

    view |> element("#new-recording-btn") |> render_click()

    view
    |> form("#recording-form", %{"start_time" => "20:15", "title" => "Test"})
    |> render_submit()

    assert has_element?(view, "#recording-form-error")
    assert render(view) =~ "Bitte einen Kanal wählen"
  end

  test "manual form uses 24h times, end time, and custom date", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recordings")

    view |> element("#new-recording-btn") |> render_click()

    assert has_element?(view, "#form-start-time")
    assert has_element?(view, "#form-end-time")
    refute has_element?(view, "#form-date")

    start_value = view |> element("#form-start-time") |> render()
    end_value = view |> element("#form-end-time") |> render()
    refute start_value =~ "AM"
    refute start_value =~ "PM"
    refute end_value =~ "AM"
    refute end_value =~ "PM"

    view |> element("#form-day-custom") |> render_click()
    assert has_element?(view, "#form-date")

    custom_day = Date.utc_today() |> Date.add(10) |> Date.to_iso8601()

    view
    |> form("#recording-form", %{
      "date" => custom_day,
      "start_time" => "20:15",
      "end_time" => "21:30"
    })
    |> render_change()

    assert has_element?(view, "#form-start-time[value='20:15']")
    assert has_element?(view, "#form-end-time[value='21:30']")
    assert render(view) =~ "Individuell · 75 Min"

    view |> element(~s(#form-duration-chips button[phx-value-minutes="60"])) |> render_click()
    assert has_element?(view, "#form-end-time[value='21:15']")
  end

  test "manual form rejects end-before-start instead of rolling to next day", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recordings")

    view |> element("#new-recording-btn") |> render_click()
    view |> element("#pick-channel-live-channel") |> render_click()

    view
    |> form("#recording-form", %{
      "start_time" => "12:40",
      "end_time" => "12:00",
      "title" => "NeuerORFTest"
    })
    |> render_change()

    html = render(view)
    assert html =~ "Endzeit muss nach dem Start liegen"
    refute html =~ "1400 Min"
    refute html =~ "Individuell · 23"

    view
    |> form("#recording-form", %{
      "start_time" => "12:40",
      "end_time" => "12:00",
      "title" => "NeuerORFTest"
    })
    |> render_submit()

    assert has_element?(view, "#recording-form-error")
    assert render(view) =~ "Endzeit muss nach dem Start liegen"
    assert has_element?(view, "#recording-form")
  end

  test "manual form allows short overnight end times", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/recordings")

    view |> element("#new-recording-btn") |> render_click()

    view
    |> form("#recording-form", %{
      "start_time" => "23:30",
      "end_time" => "01:00"
    })
    |> render_change()

    assert has_element?(view, "#form-start-time[value='23:30']")
    assert has_element?(view, "#form-end-time[value='01:00']")
    assert render(view) =~ "90 Min"
    refute render(view) =~ "Endzeit muss nach dem Start liegen"
  end

  test "shows next-day end date when recording spans midnight", %{conn: conn} do
    channel = %Channel{
      uuid: "live-channel",
      name: "ORF 1",
      number: 1,
      enabled: true,
      icon_path: "imagecache/1",
      tags: [],
      services: []
    }

    # 23:30–02:00 Europe/Vienna in summer (UTC+2)
    overnight = %Recording{
      uuid: "rec-overnight",
      title: "Late Show",
      subtitle: nil,
      channel_uuid: "live-channel",
      channel_name: "ORF 1",
      starts_at: ~U[2026-07-17 21:30:00Z],
      ends_at: ~U[2026-07-18 00:00:00Z],
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

    Cache.load_fixture([channel], %{}, %{}, [overnight])

    {:ok, _view, html} = live(conn, ~p"/recordings")

    assert html =~ "Late Show"
    assert html =~ "18.07. 02:00"
  end
end
