defmodule TvplayerWeb.RecordingMedia do
  @moduledoc false

  import Plug.Conn

  # Browsers open playback with `Range: bytes=0-`, which means "the rest of
  # the file". Answering that with a multi-GB MP4 makes the player buffer the
  # whole recording before it will play. Each response is capped so playback
  # starts from the first slice and the browser asks for the next slice as
  # the playhead moves.
  @range_chunk_bytes 8 * 1024 * 1024

  @doc false
  def range_chunk_bytes, do: @range_chunk_bytes

  @doc """
  Streams an MP4 inline with HTTP Range support (for in-browser playback).
  """
  def serve_inline(conn, path, filename) when is_binary(path) and is_binary(filename) do
    serve(conn, path, filename, "video/mp4", "inline", @range_chunk_bytes)
  end

  @doc """
  Sends a file as a download attachment via `sendfile`, with HTTP Range
  support so downloads can resume or be fetched in parallel segments.
  """
  def serve_attachment(conn, path, filename, content_type \\ "video/mp4")
      when is_binary(path) and is_binary(filename) do
    serve(conn, path, filename, content_type, "attachment", nil)
  end

  defp serve(conn, path, filename, content_type, disposition, max_slice) do
    %{size: size} = File.stat!(path)

    conn =
      conn
      |> put_resp_content_type(content_type, nil)
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("cache-control", "private, no-transform")
      |> put_resp_header(
        "content-disposition",
        ~s(#{disposition}; filename="#{escape_disposition(filename)}")
      )

    case parse_range(get_req_header(conn, "range"), size) do
      {:ok, start_pos, end_pos} ->
        end_pos = clamp_end(start_pos, end_pos, max_slice)
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

  # Cap every read at one slice that starts where the client asked. Players
  # continue and seek with open-ended ranges (`bytes=N-`); those already end
  # at EOF, so snapping them to the file tail would return the wrong bytes.
  # A short suffix (`bytes=-N`) stays intact when it fits in one slice, which
  # keeps a moov atom at the end of the file reachable.
  defp clamp_end(_start_pos, end_pos, nil), do: end_pos
  defp clamp_end(start_pos, end_pos, max_slice), do: min(end_pos, start_pos + max_slice - 1)

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
