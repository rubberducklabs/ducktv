defmodule TvplayerWeb.SessionControllerTest do
  use TvplayerWeb.ConnCase, async: false

  @tag :guest
  test "renders login form", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "Anmelden"
    assert html_response(conn, 200) =~ ~s(id="login-form")
  end

  @tag :guest
  test "logs in with the correct key and redirects home", %{conn: conn} do
    key = Application.fetch_env!(:tvplayer, :auth_key)
    conn = post(conn, ~p"/login", %{password: key})
    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :authenticated) == true
  end

  @tag :guest
  test "rejects a wrong key", %{conn: conn} do
    conn = post(conn, ~p"/login", %{password: "nope"})
    assert html_response(conn, 200) =~ "Falsches Passwort"
    refute get_session(conn, :authenticated)
  end

  @tag :guest
  test "redirects protected pages to login", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
    assert get_session(conn, :user_return_to) == "/"
  end

  @tag :guest
  test "rejects unauthenticated hls requests", %{conn: conn} do
    conn = get(conn, ~p"/hls/channel-one/index.m3u8")
    assert response(conn, 401) == "Unauthorized"
  end

  test "logs out and clears the session", %{conn: conn} do
    conn = post(conn, ~p"/logout")
    assert redirected_to(conn) == ~p"/login"
    refute get_session(conn, :authenticated)
  end

  test "redirects already authenticated users away from login", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert redirected_to(conn) == ~p"/"
  end
end
