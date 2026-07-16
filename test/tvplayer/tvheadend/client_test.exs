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
end
