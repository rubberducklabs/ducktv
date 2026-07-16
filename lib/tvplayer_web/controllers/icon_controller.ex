defmodule TvplayerWeb.IconController do
  use TvplayerWeb, :controller

  alias Tvplayer.Tvheadend.Client

  def show(conn, %{"path" => path_parts}) do
    icon_path = Enum.join(path_parts, "/")

    case Client.fetch_icon(icon_path) do
      {:ok, %{body: body, content_type: content_type}} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("cache-control", "public, max-age=3600")
        |> send_resp(200, body)

      {:error, _} ->
        send_resp(conn, 404, "Not found")
    end
  end
end
