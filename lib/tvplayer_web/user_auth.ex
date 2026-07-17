defmodule TvplayerWeb.UserAuth do
  @moduledoc """
  Plugs and LiveView hooks that gate the app behind shared-secret auth.
  """

  import Plug.Conn
  import Phoenix.Controller

  alias Tvplayer.Auth

  @doc """
  Assigns `:authenticated?` from the session.
  """
  def fetch_current_auth(conn, _opts) do
    assign(conn, :authenticated?, Auth.authenticated?(conn))
  end

  @doc """
  Redirects unauthenticated browser requests to the login page.
  """
  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:authenticated?] do
      conn
    else
      conn
      |> maybe_store_return_to()
      |> redirect(to: "/login")
      |> halt()
    end
  end

  @doc """
  Rejects unauthenticated media requests with 401.
  """
  def require_authenticated_media(conn, _opts) do
    conn = fetch_session(conn)

    if Auth.authenticated?(conn) do
      assign(conn, :authenticated?, true)
    else
      conn
      |> send_resp(401, "Unauthorized")
      |> halt()
    end
  end

  @doc """
  LiveView on_mount hook that redirects guests to login.
  """
  def on_mount(:ensure_authenticated, _params, session, socket) do
    if session_authenticated?(session) do
      {:cont, Phoenix.Component.assign(socket, :authenticated?, true)}
    else
      socket =
        socket
        |> Phoenix.LiveView.put_flash(:error, "Bitte melde dich an.")
        |> Phoenix.LiveView.redirect(to: "/login")

      {:halt, socket}
    end
  end

  defp session_authenticated?(session) do
    session["authenticated"] == true or session[:authenticated] == true
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn
end
