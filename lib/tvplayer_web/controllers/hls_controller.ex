defmodule TvplayerWeb.HLSController do
  use TvplayerWeb, :controller

  def show(conn, %{"channel_uuid" => channel_uuid, "file" => file}) do
    with :ok <- validate_uuid(channel_uuid),
         :ok <- validate_file(file),
         path when not is_nil(path) <- resolve_path(channel_uuid, file),
         true <- File.exists?(path) do
      conn
      |> put_resp_content_type(content_type(file))
      |> put_resp_header("cache-control", cache_control(file))
      |> send_file(200, path)
    else
      _ ->
        send_resp(conn, 404, "Not found")
    end
  end

  defp resolve_path(channel_uuid, file) do
    root =
      Application.get_env(:tvplayer, :streams, [])
      |> Keyword.get(:hls_root, "tmp/hls")
      |> Path.expand()

    path = Path.expand(Path.join([root, channel_uuid, file]))

    if String.starts_with?(path, Path.join(root, channel_uuid)) do
      path
    else
      nil
    end
  end

  defp validate_uuid(uuid) when is_binary(uuid) do
    if Regex.match?(~r/^[A-Za-z0-9_-]{8,64}$/, uuid), do: :ok, else: :error
  end

  defp validate_file(file) when is_binary(file) do
    if Regex.match?(~r/^[A-Za-z0-9._-]+$/, file) and not String.contains?(file, "..") do
      :ok
    else
      :error
    end
  end

  defp content_type(file) do
    cond do
      String.ends_with?(file, ".m3u8") -> "application/vnd.apple.mpegurl"
      String.ends_with?(file, ".ts") -> "video/mp2t"
      String.ends_with?(file, ".m4s") -> "video/iso.segment"
      String.ends_with?(file, ".mp4") -> "video/mp4"
      true -> "application/octet-stream"
    end
  end

  defp cache_control(file) do
    if String.ends_with?(file, ".m3u8") do
      "no-cache, no-store, must-revalidate"
    else
      "public, max-age=2"
    end
  end
end
