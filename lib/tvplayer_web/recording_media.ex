defmodule TvplayerWeb.RecordingMedia do
  @moduledoc false

  import Plug.Conn

  @doc """
  Streams an MP4 inline with HTTP Range support (for in-browser playback).
  """
  def serve_inline(conn, path, filename) when is_binary(path) and is_binary(filename) do
    %{size: size} = File.stat!(path)

    conn =
      conn
      |> put_resp_content_type("video/mp4")
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header(
        "content-disposition",
        ~s(inline; filename="#{escape_disposition(filename)}")
      )

    case parse_range(get_req_header(conn, "range"), size) do
      {:ok, start_pos, end_pos} ->
        length = end_pos - start_pos + 1

        conn
        |> put_resp_header("content-range", "bytes #{start_pos}-#{end_pos}/#{size}")
        |> put_resp_header("content-length", Integer.to_string(length))
        |> send_file(206, path, start_pos, length)

      :no_range ->
        conn
        |> put_resp_header("content-length", Integer.to_string(size))
        |> send_file(200, path)

      :invalid ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "Range Not Satisfiable")
    end
  end

  @doc """
  Streams an MP4 as a download attachment.
  """
  def serve_attachment(conn, path, filename) when is_binary(path) and is_binary(filename) do
    conn
    |> put_resp_content_type("video/mp4")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{escape_disposition(filename)}")
    )
    |> send_file(200, path)
  end

  defp parse_range([], _size), do: :no_range

  defp parse_range(["bytes=" <> range | _], size) do
    case String.split(range, "-", parts: 2) do
      ["", suffix] ->
        case Integer.parse(suffix) do
          {n, ""} when n > 0 and size > 0 ->
            start_pos = max(size - n, 0)
            {:ok, start_pos, size - 1}

          _ ->
            :invalid
        end

      [start_str, ""] ->
        case Integer.parse(start_str) do
          {start_pos, ""} when start_pos >= 0 and start_pos < size ->
            {:ok, start_pos, size - 1}

          _ ->
            :invalid
        end

      [start_str, end_str] ->
        with {start_pos, ""} <- Integer.parse(start_str),
             {end_pos, ""} <- Integer.parse(end_str),
             true <- start_pos >= 0 and end_pos >= start_pos and start_pos < size do
          {:ok, start_pos, min(end_pos, size - 1)}
        else
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  defp parse_range(_, _size), do: :no_range

  defp escape_disposition(filename) do
    String.replace(filename, "\"", "\\\"")
  end
end
