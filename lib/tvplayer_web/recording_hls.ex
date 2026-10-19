defmodule TvplayerWeb.RecordingHls do
  @moduledoc false

  import Plug.Conn

  alias Tvplayer.Recordings.Hls
  alias TvplayerWeb.FileSender

  @doc """
  Sends one file of a recording's VOD playlist.

  Segments the MP4 on first request when the playlist is not there yet.
  """
  def serve(conn, uuid, file) when is_binary(uuid) and is_binary(file) do
    with true <- Hls.valid_file?(file),
         :ok <- Hls.ensure(uuid),
         {:ok, path} <- Hls.path(uuid, file) do
      conn
      |> put_resp_content_type(content_type(file), nil)
      |> put_resp_header("cache-control", cache_control(file))
      |> put_resp_header("accept-ranges", "bytes")
      |> FileSender.send_file(200, path)
    else
      _ -> send_resp(conn, 404, "Web-Version nicht verfügbar")
    end
  end

  defp content_type("index.m3u8"), do: "application/vnd.apple.mpegurl"
  defp content_type(_file), do: "video/mp2t"

  defp cache_control("index.m3u8"), do: "private, max-age=60"
  defp cache_control(_file), do: "private, max-age=86400"
end
