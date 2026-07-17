defmodule Tvplayer.Tvheadend.Client do
  @moduledoc """
  HTTP client for the TVHeadend JSON API.
  """

  alias Tvplayer.Tvheadend.{Channel, Programme, Recording}

  @type error :: {:error, term()}

  @doc """
  Returns server information.
  """
  def server_info(opts \\ []) do
    get("/api/serverinfo", %{}, opts)
  end

  @doc """
  Lists enabled channels sorted by channel number.
  """
  def list_channels(opts \\ []) do
    params = %{
      "start" => 0,
      "limit" => Keyword.get(opts, :limit, 10_000)
    }

    with {:ok, body} <- get("/api/channel/grid", params, opts) do
      channels =
        body
        |> Map.get("entries", [])
        |> Enum.map(&Channel.from_api/1)
        |> Enum.filter(& &1.enabled)
        |> Enum.sort_by(fn channel -> {channel.number || 999_999, channel.name} end)

      {:ok, channels}
    end
  end

  @doc """
  Lists EPG events currently airing.
  """
  def list_now(opts \\ []) do
    params = %{
      "mode" => "now",
      "start" => 0,
      "limit" => Keyword.get(opts, :limit, 10_000)
    }

    with {:ok, body} <- get("/api/epg/events/grid", params, opts) do
      {:ok, Enum.map(Map.get(body, "entries", []), &Programme.from_api/1)}
    end
  end

  @doc """
  Lists EPG events in a time window.

  Options:
    * `:channel` - channel uuid or name
    * `:start` - unix seconds lower bound (via `filter`)
    * `:limit` - page size
  """
  def list_events(opts \\ []) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    params =
      %{
        "start" => Keyword.get(opts, :offset, 0),
        "limit" => Keyword.get(opts, :limit, 500),
        "sort" => "start",
        "dir" => "ASC"
      }
      |> maybe_put("channel", Keyword.get(opts, :channel))
      |> maybe_put_time_filter(from, to)

    with {:ok, body} <- get("/api/epg/events/grid", params, opts) do
      programmes = Enum.map(Map.get(body, "entries", []), &Programme.from_api/1)

      programmes =
        case from do
          %DateTime{} ->
            Enum.filter(programmes, &(DateTime.compare(&1.ends_at, from) == :gt))

          _ ->
            programmes
        end

      programmes =
        case to do
          %DateTime{} ->
            Enum.filter(programmes, &(DateTime.compare(&1.starts_at, to) == :lt))

          _ ->
            programmes
        end

      {:ok, programmes}
    end
  end

  @doc """
  Searches EPG events by title/subtitle/summary/description.
  """
  def search_events(query, opts \\ []) when is_binary(query) do
    filter =
      Jason.encode!([
        %{
          "type" => "string",
          "value" => query,
          "field" => "title"
        }
      ])

    params = %{
      "start" => 0,
      "limit" => Keyword.get(opts, :limit, 100),
      "sort" => "start",
      "dir" => "ASC",
      "filter" => filter,
      "full" => 1
    }

    with {:ok, body} <- get("/api/epg/events/grid", params, opts) do
      {:ok, Enum.map(Map.get(body, "entries", []), &Programme.from_api/1)}
    end
  end

  @doc """
  Builds an authenticated TVHeadend stream URL for a channel UUID.
  """
  def stream_url(channel_uuid, opts \\ []) when is_binary(channel_uuid) do
    config = config(opts)
    profile = Keyword.get(opts, :profile, "pass")
    base = String.trim_trailing(config[:url], "/")

    userinfo =
      URI.encode_www_form(config[:username]) <> ":" <> URI.encode_www_form(config[:password])

    uri = URI.parse(base)

    %URI{
      uri
      | userinfo: userinfo,
        path: Path.join(["/", "stream", "channel", channel_uuid]),
        query: URI.encode_query(%{"profile" => profile})
    }
    |> URI.to_string()
  end

  @doc """
  Builds an authenticated TVHeadend URL for a DVR recording file.
  Accepts a `Recording` struct or a relative `/dvrfile/<uuid>` path.
  """
  def dvrfile_url(recording_or_path, opts \\ [])

  def dvrfile_url(%Recording{} = recording, opts) do
    dvrfile_url(Recording.dvrfile_path(recording), opts)
  end

  def dvrfile_url(path, opts) when is_binary(path) do
    config = config(opts)
    base = String.trim_trailing(config[:url], "/")

    userinfo =
      URI.encode_www_form(config[:username]) <> ":" <> URI.encode_www_form(config[:password])

    uri = URI.parse(base)
    path = "/" <> String.trim_leading(path, "/")

    %URI{uri | userinfo: userinfo, path: path}
    |> URI.to_string()
  end

  @doc """
  Fetches a channel icon/image from TVHeadend.
  """
  def fetch_icon(icon_path, opts \\ []) when is_binary(icon_path) do
    path =
      if String.starts_with?(icon_path, "/") do
        icon_path
      else
        "/" <> icon_path
      end

    config = config(opts)
    url = String.trim_trailing(config[:url], "/") <> path

    case request(:get, url, %{}, opts) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        content_type =
          Enum.find_value(headers, "image/png", fn
            {"content-type", value} -> value
            {"Content-Type", value} -> value
            _ -> nil
          end)

        {:ok, %{body: body, content_type: content_type}}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Streams a DVR recording file from TVHeadend into `conn`.

  All `Plug.Conn` adapter calls run in the calling process (required by Bandit).
  Supports Req `:plug` stubs in tests.
  """
  def stream_dvrfile(path, %Plug.Conn{} = conn, opts \\ []) when is_binary(path) do
    path = "/" <> String.trim_leading(path, "/")
    config = config(opts)
    url = String.trim_trailing(config[:url], "/") <> path
    timeout = Keyword.get(opts, :timeout_ms, :infinity)
    receive_timeout = if timeout == :infinity, do: 60_000 * 60, else: timeout

    auth =
      case config[:auth] do
        :digest -> {:digest, "#{config[:username]}:#{config[:password]}"}
        _ -> {:basic, "#{config[:username]}:#{config[:password]}"}
      end

    content_type = Keyword.get(opts, :content_type, "application/octet-stream")
    filename = Keyword.get(opts, :filename, "aufnahme.ts")
    disposition = ~s(attachment; filename="#{escape_disposition(filename)}")

    case Keyword.get(opts, :plug) || config[:plug] do
      nil ->
        stream_dvrfile_live(url, auth, conn, content_type, disposition, receive_timeout)

      plug ->
        stream_dvrfile_buffered(url, auth, plug, conn, content_type, disposition, receive_timeout)
    end
  end

  # Test/plug path: body arrives fully buffered; chunk from this process.
  defp stream_dvrfile_buffered(url, auth, plug, conn, content_type, disposition, receive_timeout) do
    case Req.get(url,
           auth: auth,
           plug: plug,
           decode_body: false,
           receive_timeout: receive_timeout,
           retry: false
         ) do
      {:ok, %{status: status, body: body, headers: headers}} when status in 200..299 ->
        type = header_value(headers, "content-type") || content_type

        conn =
          conn
          |> put_download_headers(disposition, type)
          |> Plug.Conn.send_chunked(200)

        chunk_body(normalize_body(body), conn)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Live path: stream into the request process via `into: :self`, then chunk here.
  # Never call Plug.Conn from Finch/Req callbacks — Bandit requires the stream owner.
  defp stream_dvrfile_live(url, auth, conn, content_type, disposition, receive_timeout) do
    case Req.get(url,
           auth: auth,
           into: :self,
           decode_body: false,
           receive_timeout: receive_timeout,
           connect_options: [timeout: connect_timeout(receive_timeout)],
           retry: false
         ) do
      {:ok, %{status: status, headers: headers, body: body}} when status in 200..299 ->
        type = header_value(headers, "content-type") || content_type

        conn =
          conn
          |> put_download_headers(disposition, type)
          |> Plug.Conn.send_chunked(200)

        chunk_body(body, conn)

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp chunk_body(body, conn) when is_binary(body) do
    case Plug.Conn.chunk(conn, body) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
    end
  end

  defp chunk_body(body, conn) do
    Enum.reduce_while(body, {:ok, conn}, fn chunk, {:ok, conn} ->
      data = normalize_body(chunk)

      case Plug.Conn.chunk(conn, data) do
        {:ok, conn} -> {:cont, {:ok, conn}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_body(body) when is_binary(body), do: body
  defp normalize_body(body), do: IO.iodata_to_binary(List.wrap(body))

  defp put_download_headers(conn, disposition, content_type) do
    conn
    |> Plug.Conn.put_resp_header("content-disposition", disposition)
    |> Plug.Conn.put_resp_header("cache-control", "private, max-age=0")
    |> Plug.Conn.put_resp_content_type(content_type)
  end

  defp header_value(headers, name) when is_map(headers) do
    target = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == target do
        case value do
          [first | _] -> first
          other when is_binary(other) -> other
          _ -> nil
        end
      end
    end)
  end

  defp header_value(headers, name) when is_list(headers) do
    target = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == target, do: header_first(value)

      {key, value} when is_atom(key) ->
        if String.downcase(Atom.to_string(key)) == target, do: header_first(value)

      _ ->
        nil
    end)
  end

  defp header_value(_, _), do: nil

  defp header_first([first | _]), do: first
  defp header_first(value) when is_binary(value), do: value
  defp header_first(_), do: nil

  defp escape_disposition(filename) do
    filename
    |> String.replace("\\", "_")
    |> String.replace("\"", "")
  end

  defp connect_timeout(:infinity), do: 30_000
  defp connect_timeout(timeout) when is_integer(timeout), do: min(timeout, 30_000)

  @doc """
  Lists DVR configuration profiles.
  """
  def dvr_configs(opts \\ []) do
    params = %{
      "start" => 0,
      "limit" => Keyword.get(opts, :limit, 50)
    }

    with {:ok, body} <- get("/api/dvr/config/grid", params, opts) do
      {:ok, Map.get(body, "entries", [])}
    end
  end

  @doc """
  Returns the default DVR config uuid (first entry, or empty-name profile).
  """
  def default_dvr_config_uuid(opts \\ []) do
    with {:ok, configs} <- dvr_configs(opts) do
      config =
        Enum.find(configs, &(Map.get(&1, "name") in [nil, ""])) ||
          List.first(configs)

      case config do
        %{"uuid" => uuid} when is_binary(uuid) -> {:ok, uuid}
        _ -> {:error, :no_dvr_config}
      end
    end
  end

  @doc """
  Lists all DVR entries (upcoming, recording, finished, failed).
  """
  def list_recordings(opts \\ []) do
    params = %{
      "start" => 0,
      "limit" => Keyword.get(opts, :limit, 500),
      "sort" => Keyword.get(opts, :sort, "start"),
      "dir" => Keyword.get(opts, :dir, "ASC")
    }

    with {:ok, body} <- get("/api/dvr/entry/grid", params, opts) do
      recordings =
        body
        |> Map.get("entries", [])
        |> Enum.map(&Recording.from_api/1)

      {:ok, recordings}
    end
  end

  @doc """
  Schedules a recording from an EPG event id.
  """
  def record_event(event_id, opts \\ []) when is_integer(event_id) or is_binary(event_id) do
    with {:ok, config_uuid} <- config_uuid_opt(opts),
         {:ok, body} <-
           post(
             "/api/dvr/entry/create_by_event",
             %{
               "config_uuid" => config_uuid,
               "event_id" => to_string(event_id)
             },
             opts
           ) do
      {:ok, extract_uuid(body)}
    end
  end

  @doc """
  Creates a manual DVR timer.

  `attrs` keys: `:channel` (uuid), `:channel_name`, `:start`, `:stop`,
  `:title`, `:start_extra`, `:stop_extra`, `:config_uuid`.
  """
  def create_recording(attrs, opts \\ []) when is_map(attrs) do
    conf =
      %{}
      |> maybe_put_conf("channel", Map.get(attrs, :channel) || Map.get(attrs, "channel"))
      |> maybe_put_conf(
        "channelname",
        Map.get(attrs, :channel_name) || Map.get(attrs, "channelname")
      )
      |> maybe_put_conf_unix("start", Map.get(attrs, :start) || Map.get(attrs, "start"))
      |> maybe_put_conf_unix("stop", Map.get(attrs, :stop) || Map.get(attrs, "stop"))
      |> maybe_put_conf(
        "start_extra",
        Map.get(attrs, :start_extra) || Map.get(attrs, "start_extra")
      )
      |> maybe_put_conf("stop_extra", Map.get(attrs, :stop_extra) || Map.get(attrs, "stop_extra"))
      |> maybe_put_title(Map.get(attrs, :title) || Map.get(attrs, "title"))
      |> maybe_put_conf(
        "config_name",
        Map.get(attrs, :config_uuid) || Map.get(attrs, "config_uuid")
      )

    with {:ok, body} <- post("/api/dvr/entry/create", %{"conf" => Jason.encode!(conf)}, opts) do
      {:ok, extract_uuid(body)}
    end
  end

  @doc """
  Updates an existing DVR entry via idnode/save.
  """
  def update_recording(uuid, attrs, opts \\ []) when is_binary(uuid) and is_map(attrs) do
    node =
      %{"uuid" => uuid}
      |> maybe_put_conf_unix("start", Map.get(attrs, :start) || Map.get(attrs, "start"))
      |> maybe_put_conf_unix("stop", Map.get(attrs, :stop) || Map.get(attrs, "stop"))
      |> maybe_put_conf(
        "start_extra",
        Map.get(attrs, :start_extra) || Map.get(attrs, "start_extra")
      )
      |> maybe_put_conf("stop_extra", Map.get(attrs, :stop_extra) || Map.get(attrs, "stop_extra"))
      |> maybe_put_conf("enabled", Map.get(attrs, :enabled) || Map.get(attrs, "enabled"))
      |> maybe_put_title(Map.get(attrs, :title) || Map.get(attrs, "title"))

    with {:ok, _body} <- post("/api/idnode/save", %{"node" => Jason.encode!(node)}, opts) do
      {:ok, uuid}
    end
  end

  @doc """
  Cancels a scheduled or incomplete recording.
  """
  def cancel_recording(uuid, opts \\ []) when is_binary(uuid) do
    with {:ok, _body} <- post("/api/dvr/entry/cancel", %{"uuid" => uuid}, opts) do
      {:ok, uuid}
    end
  end

  @doc """
  Stops a currently running recording.
  """
  def stop_recording(uuid, opts \\ []) when is_binary(uuid) do
    with {:ok, _body} <- post("/api/dvr/entry/stop", %{"uuid" => uuid}, opts) do
      {:ok, uuid}
    end
  end

  @doc """
  Removes a finished recording file from disk.
  """
  def remove_recording(uuid, opts \\ []) when is_binary(uuid) do
    with {:ok, _body} <- post("/api/dvr/entry/remove", %{"uuid" => uuid}, opts) do
      {:ok, uuid}
    end
  end

  defp config_uuid_opt(opts) do
    case Keyword.get(opts, :config_uuid) do
      uuid when is_binary(uuid) and uuid != "" -> {:ok, uuid}
      _ -> default_dvr_config_uuid(opts)
    end
  end

  defp extract_uuid(%{"uuid" => uuid}) when is_binary(uuid), do: uuid
  defp extract_uuid(%{"uuid" => [uuid | _]}) when is_binary(uuid), do: uuid

  defp extract_uuid(%{"entries" => [%{"uuid" => uuid} | _]}) when is_binary(uuid), do: uuid

  defp extract_uuid(body) when is_map(body) do
    # create_by_event often returns {"uuid": ["..."]} via idnode create list
    case Map.get(body, "uuid") do
      list when is_list(list) -> List.first(list)
      other -> other
    end
  end

  defp extract_uuid(_), do: nil

  defp maybe_put_conf(map, _key, nil), do: map
  defp maybe_put_conf(map, _key, ""), do: map
  defp maybe_put_conf(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_conf_unix(map, _key, nil), do: map

  defp maybe_put_conf_unix(map, key, %DateTime{} = dt) do
    Map.put(map, key, DateTime.to_unix(dt))
  end

  defp maybe_put_conf_unix(map, key, value) when is_integer(value), do: Map.put(map, key, value)

  defp maybe_put_title(map, nil), do: map
  defp maybe_put_title(map, ""), do: map

  defp maybe_put_title(map, title) when is_binary(title) do
    Map.put(map, "title", %{"ger" => title, "eng" => title})
  end

  defp get(path, params, opts) do
    config = config(opts)
    url = String.trim_trailing(config[:url], "/") <> path

    case request(:get, url, params, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp post(path, form, opts) do
    config = config(opts)
    url = String.trim_trailing(config[:url], "/") <> path

    case request(:post, url, form, opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %{status: status, body: body}} when status in 200..299 and is_binary(body) ->
        case Jason.decode(body) do
          {:ok, decoded} -> {:ok, decoded}
          # TVH action endpoints sometimes return empty / bare uuid strings
          {:error, _} when body in ["", "{}"] -> {:ok, %{}}
          {:error, reason} -> {:error, {:invalid_json, reason}}
        end

      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body || %{}}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request(method, url, params_or_form, opts) do
    config = config(opts)
    timeout = Keyword.get(opts, :timeout_ms, config[:timeout_ms] || 10_000)

    auth =
      case config[:auth] do
        :digest -> {:digest, "#{config[:username]}:#{config[:password]}"}
        _ -> {:basic, "#{config[:username]}:#{config[:password]}"}
      end

    req_opts = [
      method: method,
      url: url,
      auth: auth,
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      retry: false,
      decode_body: true
    ]

    req_opts =
      case method do
        :get -> Keyword.put(req_opts, :params, params_or_form)
        :post -> Keyword.put(req_opts, :form, params_or_form)
      end

    req_opts =
      case Keyword.get(opts, :plug) || config[:plug] do
        nil -> req_opts
        plug -> Keyword.put(req_opts, :plug, plug)
      end

    Req.new(req_opts) |> Req.request()
  end

  defp config(opts) do
    Application.get_env(:tvplayer, :tvheadend, [])
    |> Keyword.merge(Keyword.take(opts, [:url, :username, :password, :auth, :timeout_ms, :plug]))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_time_filter(params, nil, nil), do: params

  defp maybe_put_time_filter(params, from, to) do
    filters =
      []
      |> then(fn filters ->
        if match?(%DateTime{}, from) do
          [
            %{
              "type" => "numeric",
              "value" => DateTime.to_unix(from),
              "field" => "stop",
              "comparison" => "gt"
            }
            | filters
          ]
        else
          filters
        end
      end)
      |> then(fn filters ->
        if match?(%DateTime{}, to) do
          [
            %{
              "type" => "numeric",
              "value" => DateTime.to_unix(to),
              "field" => "start",
              "comparison" => "lt"
            }
            | filters
          ]
        else
          filters
        end
      end)

    case filters do
      [] -> params
      _ -> Map.put(params, "filter", Jason.encode!(filters))
    end
  end
end
