defmodule Tvplayer.Tvheadend.IntegrationTest do
  use ExUnit.Case, async: false

  @moduletag :integration

  alias Tvplayer.Tvheadend.Client

  @tag :integration
  test "talks to the real TVHeadend server when enabled" do
    unless System.get_env("TVH_INTEGRATION") == "1" do
      assert true
    else
      opts = [
        url: System.get_env("TVHEADEND_URL", "http://10.0.1.10:9981"),
        username: System.get_env("TVHEADEND_USER", "admin"),
        password: System.get_env("TVHEADEND_PASSWORD", "admin")
      ]

      assert {:ok, info} = Client.server_info(opts)
      assert info["api_version"]
      assert {:ok, channels} = Client.list_channels(Keyword.put(opts, :limit, 5))
      assert length(channels) > 0
    end
  end
end
