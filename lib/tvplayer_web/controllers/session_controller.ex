defmodule TvplayerWeb.SessionController do
  use TvplayerWeb, :controller

  alias Tvplayer.Auth

  plug :put_layout, false

  def new(conn, _params) do
    if Auth.authenticated?(conn) do
      redirect(conn, to: ~p"/")
    else
      render(conn, :new, error: nil, page_title: "Anmelden")
    end
  end

  def create(conn, %{"password" => password}) do
    if Auth.valid_password?(password) do
      return_to = get_session(conn, :user_return_to) || ~p"/"

      conn
      |> Auth.log_in()
      |> delete_session(:user_return_to)
      |> put_flash(:info, "Angemeldet.")
      |> redirect(to: return_to)
    else
      conn
      |> put_flash(:error, "Falsches Passwort.")
      |> render(:new, error: "Falsches Passwort.", page_title: "Anmelden")
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Passwort erforderlich.")
    |> render(:new, error: "Passwort erforderlich.", page_title: "Anmelden")
  end

  def delete(conn, _params) do
    conn
    |> Auth.log_out()
    |> put_flash(:info, "Abgemeldet.")
    |> redirect(to: ~p"/login")
  end
end
