defmodule TvplayerWeb.RecordingController do
  use TvplayerWeb, :controller

  require Logger

  alias Tvplayer.Recordings.Transcoder
  alias Tvplayer.Tvheadend.{Cache, Client, Recording}
  alias TvplayerWeb.RecordingMedia

  def download(conn, %{"uuid" => uuid} = params) do
    variant = Map.get(params, "variant", "original")

    case Cache.recording(uuid) do
      %Recording{} = recording ->
        if Recording.downloadable?(recording) do
          case variant do
            "compressed" -> stream_compressed(conn, recording)
            _ -> stream_original(conn, recording)
          end
        else
          send_resp(conn, 404, "Aufnahme nicht verfügbar")
        end

      nil ->
        send_resp(conn, 404, "Aufnahme nicht gefunden")
    end
  end

  def media(conn, %{"uuid" => uuid}) do
    case Cache.recording(uuid) do
      %Recording{} = recording ->
        path = Transcoder.output_path(uuid)

        if Recording.downloadable?(recording) and File.exists?(path) do
          RecordingMedia.serve_inline(conn, path, Recording.web_download_filename(recording))
        else
          send_resp(conn, 404, "Web-Version nicht verfügbar")
        end

      nil ->
        send_resp(conn, 404, "Aufnahme nicht gefunden")
    end
  end

  defp stream_compressed(conn, %Recording{} = recording) do
    path = Transcoder.output_path(recording.uuid)

    if File.exists?(path) do
      RecordingMedia.serve_attachment(conn, path, Recording.web_download_filename(recording))
    else
      send_resp(conn, 404, "Web-Version noch nicht vorhanden")
    end
  end

  defp stream_original(conn, %Recording{} = recording) do
    filename = Recording.download_filename(recording)
    path = Recording.dvrfile_path(recording)
    content_type = content_type_for(filename)

    case Client.stream_dvrfile(path, conn,
           filename: filename,
           content_type: content_type
         ) do
      {:ok, conn} ->
        conn

      {:error, {:http_error, status}} ->
        Logger.warning("DVR download failed for #{recording.uuid}: HTTP #{status}")
        maybe_error_resp(conn, 502, "Datei konnte nicht geladen werden")

      {:error, reason} ->
        Logger.warning("DVR download failed for #{recording.uuid}: #{inspect(reason)}")
        maybe_error_resp(conn, 502, "Datei konnte nicht geladen werden")
    end
  end

  defp maybe_error_resp(conn, status, message) do
    if conn.state in [:sent, :chunked] do
      conn
    else
      send_resp(conn, status, message)
    end
  end

  defp content_type_for(filename) do
    cond do
      String.ends_with?(filename, ".ts") -> "video/mp2t"
      String.ends_with?(filename, ".mkv") -> "video/x-matroska"
      String.ends_with?(filename, ".mp4") -> "video/mp4"
      String.ends_with?(filename, ".m2ts") -> "video/mp2t"
      true -> "application/octet-stream"
    end
  end
end
