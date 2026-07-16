defmodule Tvplayer.Tvheadend.Client do
  @moduledoc """
  HTTP client for the TVHeadend JSON API.
  """

  alias Tvplayer.Tvheadend.{Channel, Programme}

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

    case request(url, %{}, opts) do
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

  defp get(path, params, opts) do
    config = config(opts)
    url = String.trim_trailing(config[:url], "/") <> path

    case request(url, params, opts) do
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

  defp request(url, params, opts) do
    config = config(opts)
    timeout = Keyword.get(opts, :timeout_ms, config[:timeout_ms] || 10_000)

    auth =
      case config[:auth] do
        :digest -> {:digest, "#{config[:username]}:#{config[:password]}"}
        _ -> {:basic, "#{config[:username]}:#{config[:password]}"}
      end

    req_opts = [
      url: url,
      params: params,
      auth: auth,
      receive_timeout: timeout,
      connect_options: [timeout: timeout],
      retry: false,
      decode_body: true
    ]

    req_opts =
      case Keyword.get(opts, :plug) do
        nil -> req_opts
        plug -> Keyword.put(req_opts, :plug, plug)
      end

    Req.new(req_opts) |> Req.request()
  end

  defp config(opts) do
    Application.get_env(:tvplayer, :tvheadend, [])
    |> Keyword.merge(Keyword.take(opts, [:url, :username, :password, :auth, :timeout_ms]))
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
