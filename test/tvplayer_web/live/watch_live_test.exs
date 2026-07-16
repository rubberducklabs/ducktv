defmodule TvplayerWeb.WatchLiveTest do
  use TvplayerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Tvplayer.Tvheadend.{Cache, Channel, Programme}

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
      next_event_id: nil,
      image: nil
    }

    Cache.load_fixture([channel], %{"live-channel" => %{now: now, next: nil}}, %{
      "live-channel" => [now]
    })

    :ok
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
end
