defmodule TvplayerWeb.WatchLiveTest do
  use TvplayerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tvplayer.Tvheadend.{Cache, Channel, Programme, Recording}

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

    now = %Programme{
      event_id: 1,
      channel_uuid: "live-channel",
      channel_name: "ORF 1",
      channel_number: 1,
      title: "Evening News",
      subtitle: nil,
      summary: nil,
      description: "Daily news",
      starts_at: DateTime.utc_now() |> DateTime.add(-600, :second),
      ends_at: DateTime.utc_now() |> DateTime.add(1800, :second),
      next_event_id: 2,
      image: nil
    }

    next = %Programme{
      event_id: 2,
      channel_uuid: "live-channel",
      channel_name: "ORF 1",
      channel_number: 1,
      title: "Tatort",
      subtitle: nil,
      summary: nil,
      description: nil,
      starts_at: DateTime.utc_now() |> DateTime.add(1800, :second),
      ends_at: DateTime.utc_now() |> DateTime.add(5400, :second),
      next_event_id: nil,
      image: nil
    }

    load_watch_fixture(channel, now, next)

    %{channel: channel, now: now, next: next}
  end

  test "renders custom video player controls", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#player-stage")
    assert has_element?(view, "#tv-video")
    refute has_element?(view, "#tv-video[controls]")
    assert has_element?(view, "[data-player-ui]")
    assert has_element?(view, "[data-play-pause]")
    assert has_element?(view, "[data-mute]")
    assert has_element?(view, "[data-fullscreen]")
    assert has_element?(view, ".tv-player-live")
  end

  test "renders channel list and now/next", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    assert html =~ "TV Player"
    assert html =~ "ORF 1"
    assert html =~ "Evening News"
    assert html =~ "Tatort"
    assert has_element?(view, "#channel-live-channel")
    assert has_element?(view, "#channel-live-channel .tv-encoder-dot")
  end

  test "encoder status dot turns ready when session is ready", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?channel=live-channel")

    assert has_element?(view, "#channel-live-channel .tv-encoder-dot-starting") or
             has_element?(view, "#channel-live-channel .tv-encoder-dot-ready") or
             has_element?(view, "#channel-live-channel .tv-encoder-dot-idle")

    send(
      view.pid,
      {:stream_status,
       %{
         channel_uuid: "live-channel",
         status: :ready,
         playlist_url: "/hls/live-channel/index.m3u8",
         error: nil
       }}
    )

    assert has_element?(view, "#channel-live-channel .tv-encoder-dot-ready")

    send(
      view.pid,
      {:stream_status,
       %{
         channel_uuid: "live-channel",
         status: :idle,
         playlist_url: "/hls/live-channel/index.m3u8",
         error: nil
       }}
    )

    assert has_element?(view, "#channel-live-channel .tv-encoder-dot-idle")
  end

  test "pushes stream_state when playback becomes ready", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?channel=live-channel")

    send(
      view.pid,
      {:stream_status,
       %{
         channel_uuid: "live-channel",
         status: :ready,
         playlist_url: "/hls/live-channel/index.m3u8",
         error: nil
       }}
    )

    assert_push_event(view, "stream_state", %{
      status: "ready",
      playlist_url: "/hls/live-channel/index.m3u8"
    })
  end

  test "guide page renders epg grid", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/guide")

    assert has_element?(view, "#tv-epg")
    assert has_element?(view, "#epg-row-live-channel")
    assert has_element?(view, "#epg-prog-1")
    assert render(view) =~ "ORF 1"
    assert render(view) =~ "Evening News"
  end

  test "guide marks planned recordings with a recording class", %{
    conn: conn,
    channel: channel,
    now: now,
    next: next
  } do
    load_watch_fixture(channel, now, next, [
      recording_fixture(next, :scheduled, "rec-next")
    ])

    {:ok, view, _html} = live(conn, ~p"/guide")

    assert has_element?(view, "#epg-prog-2.tv-epg-programme-recording")
    refute has_element?(view, "#epg-prog-1.tv-epg-programme-recording")
  end

  test "selecting a channel scrolls back to the player", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?channel=live-channel")

    view |> element("#channel-live-channel") |> render_click()

    assert_push_event(view, "scroll_to_player", %{})
  end

  test "player shows record button for current show", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/?channel=live-channel")

    assert has_element?(view, "#now-record-btn")
    refute has_element?(view, "#player-rec-badge")
    refute has_element?(view, "#now-stop-record-btn")
    assert has_element?(view, "a[href='/recordings']")
  end

  test "planned recording for the next show does not look like a live recording", %{
    conn: conn,
    channel: channel,
    now: now,
    next: next
  } do
    load_watch_fixture(channel, now, next, [
      recording_fixture(next, :scheduled, "rec-next")
    ])

    {:ok, view, html} = live(conn, ~p"/?channel=live-channel")

    assert has_element?(view, "#now-record-btn")
    refute has_element?(view, "#player-rec-badge")
    refute has_element?(view, "#now-stop-record-btn")
    refute has_element?(view, "#now-planned-link")
    refute html =~ "Geplant · Abbrechen"
  end

  test "planned recording for the current show is a status, not REC or cancel", %{
    conn: conn,
    channel: channel,
    now: now,
    next: next
  } do
    load_watch_fixture(channel, now, next, [
      recording_fixture(now, :scheduled, "rec-now")
    ])

    {:ok, view, html} = live(conn, ~p"/?channel=live-channel")

    assert has_element?(view, "#now-planned-link")
    refute has_element?(view, "#player-rec-badge")
    refute has_element?(view, "#now-record-btn")
    refute has_element?(view, "#now-stop-record-btn")
    refute html =~ "Geplant · Abbrechen"
  end

  test "active recording shows REC badge and stop control", %{
    conn: conn,
    channel: channel,
    now: now,
    next: next
  } do
    load_watch_fixture(channel, now, next, [
      recording_fixture(now, :recording, "rec-live")
    ])

    {:ok, view, _html} = live(conn, ~p"/?channel=live-channel")

    assert has_element?(view, "#player-rec-badge")
    assert has_element?(view, "#now-stop-record-btn")
    refute has_element?(view, "#now-record-btn")
    refute has_element?(view, "#now-planned-link")
  end

  test "guide detail offers record action", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/guide")

    view |> element("#epg-prog-1") |> render_click()
    assert has_element?(view, "#programme-detail")
    assert has_element?(view, "#detail-record-btn")

    view |> element("#detail-record-btn") |> render_click()
    assert has_element?(view, "#record-padding-panel")
    assert has_element?(view, "#detail-confirm-record-btn")
  end

  defp load_watch_fixture(channel, now, next, recordings \\ []) do
    Cache.load_fixture(
      [channel],
      %{"live-channel" => %{now: now, next: next}},
      %{"live-channel" => [now, next]},
      recordings
    )
  end

  defp recording_fixture(programme, state, uuid) do
    %Recording{
      uuid: uuid,
      title: programme.title,
      subtitle: nil,
      channel_uuid: programme.channel_uuid,
      channel_name: programme.channel_name,
      starts_at: programme.starts_at,
      ends_at: programme.ends_at,
      start_extra: 0,
      stop_extra: 0,
      sched_status: to_string(state),
      status: if(state == :recording, do: "Recording", else: "Scheduled for recording"),
      filesize: 0,
      url: nil,
      filename: nil,
      enabled: true,
      event_id: programme.event_id,
      file_removed: false,
      state: state
    }
  end
end
