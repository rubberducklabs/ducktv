defmodule TvplayerWeb.FileSender do
  @moduledoc false

  # Players and proxies routinely hang up mid-response (seeking, cancelling a
  # range they no longer need). Bandit then raises a TransportError from
  # `sendfile` *without* marking the response as sent, so Phoenix's error
  # renderer tries to write a 500 page onto the dead socket and logs
  # "Sent 500". Flagging the response as sent skips that render; the error
  # still reaches Bandit, which closes the connection without logging.
  @spec send_file(Plug.Conn.t(), Plug.Conn.status(), Path.t(), integer(), integer() | :all) ::
          Plug.Conn.t() | no_return()
  def send_file(conn, status, path, offset \\ 0, length \\ :all) do
    Plug.Conn.send_file(conn, status, path, offset, length)
  rescue
    error in Bandit.TransportError ->
      send(self(), {:plug_conn, :sent})
      reraise %{error | error: :closed}, __STACKTRACE__
  end
end
