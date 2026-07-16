defmodule Tvplayer.Tvheadend.ChannelTest do
  use ExUnit.Case, async: true

  alias Tvplayer.Tvheadend.Channel

  test "from_api normalizes channel entries" do
    channel =
      Channel.from_api(%{
        "uuid" => "abc",
        "name" => "ORF 1",
        "number" => 1,
        "enabled" => true,
        "icon_public_url" => "imagecache/1",
        "tags" => ["HD"],
        "services" => ["svc"]
      })

    assert channel.uuid == "abc"
    assert channel.name == "ORF 1"
    assert channel.number == 1
    assert channel.icon_path == "imagecache/1"
    assert channel.tags == ["HD"]
  end
end
