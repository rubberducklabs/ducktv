defmodule TvplayerWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  By default the connection is authenticated. Tag a test with
  `@tag :guest` to keep it logged out.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint TvplayerWeb.Endpoint

      use TvplayerWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import TvplayerWeb.ConnCase
    end
  end

  setup tags do
    conn = Phoenix.ConnTest.build_conn()
    conn = if tags[:guest], do: conn, else: log_in(conn)
    {:ok, conn: conn}
  end

  @doc """
  Logs the test connection in with a long-lived auth session cookie.
  """
  def log_in(conn) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:authenticated, true)
  end
end
