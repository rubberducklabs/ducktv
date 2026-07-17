defmodule Tvplayer.Tvheadend.ClientTest do
  use ExUnit.Case, async: true

  alias Tvplayer.Tvheadend.Client

  test "list_channels parses and sorts enabled channels" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.Channels, fn conn ->
      Req.Test.json(conn, %{
        "entries" => [
          %{
            "uuid" => "b",
            "name" => "ZDF",
            "number" => 2,
            "enabled" => true,
            "icon_public_url" => "imagecache/2"
          },
          %{
            "uuid" => "a",
            "name" => "ORF",
            "number" => 1,
            "enabled" => true,
            "icon_public_url" => "imagecache/1"
          },
          %{
            "uuid" => "c",
            "name" => "Off",
            "number" => 9,
            "enabled" => false
          }
        ]
      })
    end)

    assert {:ok, [first, second]} =
             Client.list_channels(
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.Channels}
             )

    assert first.name == "ORF"
    assert second.name == "ZDF"
  end

  test "list_now returns programmes" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.Now, fn conn ->
      Req.Test.json(conn, %{
        "entries" => [
          %{
            "eventId" => 10,
            "channelUuid" => "a",
            "channelName" => "ORF",
            "title" => "News",
            "start" => 1_700_000_000,
            "stop" => 1_700_003_600
          }
        ]
      })
    end)

    assert {:ok, [programme]} =
             Client.list_now(
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.Now}
             )

    assert programme.title == "News"
  end

  test "stream_url embeds credentials and profile" do
    url =
      Client.stream_url("abc123",
        url: "http://10.0.1.10:9981",
        username: "user",
        password: "pass",
        profile: "pass"
      )

    assert url =~ "http://user:pass@10.0.1.10:9981/stream/channel/abc123"
    assert url =~ "profile=pass"
  end

  test "dvrfile_url embeds credentials for recording path" do
    url =
      Client.dvrfile_url("/dvrfile/rec-1",
        url: "http://10.0.1.10:9981",
        username: "user",
        password: "pass"
      )

    assert url == "http://user:pass@10.0.1.10:9981/dvrfile/rec-1"
  end

  test "list_recordings parses dvr entries" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.DvrList, fn conn ->
      Req.Test.json(conn, %{
        "entries" => [
          %{
            "uuid" => "rec-1",
            "disp_title" => "Tatort",
            "channel" => "a",
            "channelname" => "ORF",
            "start" => 1_700_000_000,
            "stop" => 1_700_003_600,
            "sched_status" => "scheduled",
            "status" => "Scheduled for recording",
            "start_extra" => 5,
            "stop_extra" => 5
          }
        ]
      })
    end)

    assert {:ok, [recording]} =
             Client.list_recordings(
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.DvrList}
             )

    assert recording.title == "Tatort"
    assert recording.state == :scheduled
  end

  test "record_event posts create_by_event" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.DvrCreateEvent, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "event_id=10"
      assert body =~ "config_uuid=cfg-1"
      Req.Test.json(conn, %{"uuid" => ["new-rec"]})
    end)

    assert {:ok, "new-rec"} =
             Client.record_event(10,
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               config_uuid: "cfg-1",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.DvrCreateEvent}
             )
  end

  test "create_recording posts conf json" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.DvrCreate, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "conf="
      Req.Test.json(conn, %{"uuid" => "manual-1"})
    end)

    assert {:ok, "manual-1"} =
             Client.create_recording(
               %{
                 channel: "a",
                 channel_name: "ORF",
                 start: DateTime.from_unix!(1_700_000_000),
                 stop: DateTime.from_unix!(1_700_003_600),
                 title: "Manual",
                 start_extra: 5,
                 stop_extra: 10
               },
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.DvrCreate}
             )
  end

  test "cancel_recording posts uuid" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.DvrCancel, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "uuid=rec-1"
      Req.Test.json(conn, %{})
    end)

    assert {:ok, "rec-1"} =
             Client.cancel_recording("rec-1",
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.DvrCancel}
             )
  end
end
