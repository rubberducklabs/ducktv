defmodule TvplayerWeb.HLSControllerTest do
  use TvplayerWeb.ConnCase, async: true

  setup do
    root = "tmp/hls_test"
    File.mkdir_p!(Path.join(root, "channel-one"))
    File.write!(Path.join([root, "channel-one", "index.m3u8"]), "#EXTM3U\n")
    File.write!(Path.join([root, "channel-one", "segment_00000.ts"]), <<0, 1, 2, 3>>)

    on_exit(fn -> File.rm_rf!(root) end)
    :ok
  end

  test "serves playlist with correct content type", %{conn: conn} do
    conn = get(conn, ~p"/hls/channel-one/index.m3u8")
    assert response(conn, 200) =~ "#EXTM3U"
    assert get_resp_header(conn, "content-type") |> hd() =~ "mpegurl"
  end

  test "rejects path traversal", %{conn: conn} do
    conn = get(conn, "/hls/channel-one/../secret.txt")
    assert response(conn, 404)
  end
end
