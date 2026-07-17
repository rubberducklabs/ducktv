defmodule Tvplayer.AuthTest do
  use ExUnit.Case, async: false

  alias Tvplayer.Auth

  test "accepts the configured auth key" do
    key = Application.fetch_env!(:tvplayer, :auth_key)
    assert Auth.valid_password?(key)
  end

  test "rejects wrong passwords" do
    refute Auth.valid_password?("wrong-password")
    refute Auth.valid_password?("")
    refute Auth.valid_password?(nil)
  end
end
