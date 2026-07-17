defmodule TvplayerWeb.SharedRecordingController do
  use TvplayerWeb, :controller

  alias Tvplayer.Recordings.{ShareLink, Transcoder}
  alias Tvplayer.Tvheadend.{Cache, Recording}
  alias TvplayerWeb.RecordingMedia

  def media(conn, %{"token" => token}) do
    with {:ok, recording, path} <- load_shared(token) do
      RecordingMedia.serve_inline(conn, path, Recording.web_download_filename(recording))
    else
      {:error, status, message} -> send_resp(conn, status, message)
    end
  end

  def download(conn, %{"token" => token}) do
    with {:ok, recording, path} <- load_shared(token) do
      RecordingMedia.serve_attachment(conn, path, Recording.web_download_filename(recording))
    else
      {:error, status, message} -> send_resp(conn, status, message)
    end
  end

  defp load_shared(token) do
    with {:ok, uuid} <- ShareLink.verify(token),
         %Recording{} = recording <- Cache.recording(uuid),
         true <- Recording.downloadable?(recording),
         path = Transcoder.output_path(uuid),
         true <- File.exists?(path) do
      {:ok, recording, path}
    else
      {:error, :expired} ->
        {:error, 410, "Freigabelink abgelaufen"}

      {:error, _} ->
        {:error, 404, "Freigabelink ungültig"}

      nil ->
        {:error, 404, "Aufnahme nicht gefunden"}

      false ->
        {:error, 404, "Web-Version nicht verfügbar"}
    end
  end
end
