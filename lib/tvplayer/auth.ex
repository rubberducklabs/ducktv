defmodule Tvplayer.Auth do
  @moduledoc """
  Shared-secret authentication for the TV Player UI.

  The secret is configured via `AUTH_KEY`. Verification uses Argon2 so
  password checks are intentionally slow, which limits brute-force attempts.
  """

  @hash_key {__MODULE__, :password_hash}
  @session_key :authenticated

  @doc """
  Hashes the configured auth key and stores it for later verification.

  Called once at application boot.
  """
  def init! do
    key = Application.fetch_env!(:tvplayer, :auth_key)

    if not is_binary(key) or key == "" do
      raise """
      AUTH_KEY is missing or empty.
      Set AUTH_KEY in the environment (see .env.example).
      """
    end

    :persistent_term.put(@hash_key, Argon2.hash_pwd_salt(key))
    :ok
  end

  @doc false
  def session_key, do: @session_key

  @doc """
  Returns true when `password` matches the configured AUTH_KEY.
  """
  def valid_password?(password) when is_binary(password) and password != "" do
    Argon2.verify_pass(password, password_hash())
  end

  def valid_password?(_password) do
    Argon2.no_user_verify()
    false
  end

  @doc """
  Marks the session as authenticated.
  """
  def log_in(conn) do
    conn
    |> Plug.Conn.configure_session(renew: true)
    |> Plug.Conn.put_session(@session_key, true)
  end

  @doc """
  Clears authentication from the session.
  """
  def log_out(conn) do
    conn
    |> Plug.Conn.configure_session(renew: true)
    |> Plug.Conn.clear_session()
  end

  @doc """
  Returns true when the connection session is authenticated.
  """
  def authenticated?(conn) do
    Plug.Conn.get_session(conn, @session_key) == true
  end

  defp password_hash do
    :persistent_term.get(@hash_key)
  end
end
