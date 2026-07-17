defmodule Tvplayer.Recordings.ShareLinkTest do
  use ExUnit.Case, async: true

  alias Tvplayer.Recordings.ShareLink

  test "signs and verifies a recording uuid" do
    token = ShareLink.sign("rec-done")
    assert {:ok, "rec-done"} = ShareLink.verify(token)
  end

  test "rejects tampered tokens" do
    token = ShareLink.sign("rec-done")
    assert {:error, _} = ShareLink.verify(token <> "x")
  end

  test "rejects blank tokens" do
    assert {:error, :invalid} = ShareLink.verify("")
    assert {:error, :invalid} = ShareLink.verify(nil)
  end

  test "builds an absolute share url" do
    url = ShareLink.url_for("rec-done")
    assert String.starts_with?(url, TvplayerWeb.Endpoint.url())
    assert String.contains?(url, "/share/")
    token = url |> String.split("/share/") |> List.last()
    assert {:ok, "rec-done"} = ShareLink.verify(token)
  end
end
