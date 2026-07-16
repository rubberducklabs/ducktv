defmodule TvplayerWeb.WatchLive do
  use TvplayerWeb, :live_view

  alias Tvplayer.Streams.{Manager, Session}
  alias Tvplayer.Tvheadend.{Cache, Programme}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Cache.channels_topic())
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Cache.epg_topic())
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Session.all_topic())
    end

    channels = Cache.list_channels()
    now_map = Cache.now_map()

    encoder_statuses =
      if connected?(socket), do: Manager.session_statuses(), else: %{}

    socket =
      assign(socket,
        page_title: "Fernsehen",
        channels: channels,
        now_map: now_map,
        selected: nil,
        stream_status: :idle,
        playlist_url: nil,
        stream_error: nil,
        filter: "",
        watching_uuid: nil,
        encoder_statuses: encoder_statuses
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    channel =
      case params do
        %{"channel" => uuid} -> Cache.get_channel(uuid) || Cache.default_channel()
        _ -> socket.assigns.selected || Cache.default_channel()
      end

    {:noreply, maybe_start_channel(socket, channel)}
  end

  @impl true
  def handle_event("select_channel", %{"uuid" => uuid}, socket) do
    {:noreply, push_patch(socket, to: ~p"/?channel=#{uuid}")}
  end

  def handle_event("retry", _params, socket) do
    {:noreply, maybe_start_channel(socket, socket.assigns.selected)}
  end

  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, assign(socket, filter: q)}
  end

  @impl true
  def handle_info({:channels_updated, channels}, socket) do
    socket = assign(socket, channels: channels)

    socket =
      cond do
        is_nil(socket.assigns.selected) ->
          maybe_start_channel(socket, Cache.default_channel())

        true ->
          selected = Cache.get_channel(socket.assigns.selected.uuid) || Cache.default_channel()
          assign(socket, selected: selected)
      end

    {:noreply, socket}
  end

  def handle_info({:epg_updated, now_map}, socket) do
    {:noreply, assign(socket, now_map: now_map)}
  end

  def handle_info({:stream_status, info}, socket) do
    encoder_statuses = put_encoder_status(socket.assigns.encoder_statuses, info)

    socket = assign(socket, encoder_statuses: encoder_statuses)

    if socket.assigns.watching_uuid == info.channel_uuid and info.status != :idle do
      {:noreply,
       put_stream_state(socket,
         stream_status: info.status,
         playlist_url: info.playlist_url,
         stream_error: info.error
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:ensure_watch, uuid}, socket) do
    if socket.assigns.watching_uuid == uuid do
      {:noreply, attach_watch(socket, uuid)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def terminate(_reason, socket) do
    if uuid = socket.assigns[:watching_uuid] do
      Manager.unwatch(uuid, self())
    end

    :ok
  end

  defp maybe_start_channel(socket, nil) do
    put_stream_state(socket,
      selected: nil,
      stream_status: :error,
      stream_error: "Keine Kanäle von TVHeadend verfügbar.",
      playlist_url: nil
    )
  end

  defp maybe_start_channel(socket, channel) do
    if socket.assigns[:watching_uuid] == channel.uuid and
         socket.assigns[:stream_status] in [:ready, :starting] do
      assign(socket, selected: channel, page_title: channel.name)
    else
      do_start_channel(socket, channel)
    end
  end

  defp do_start_channel(socket, channel) do
    old_uuid = socket.assigns[:watching_uuid]

    if old_uuid && old_uuid != channel.uuid do
      Manager.unwatch(old_uuid, self())
    end

    # Update selection immediately so the UI does not wait on Manager.watch /
    # Session.init (disk I/O, process start). Stream attach runs asynchronously.
    socket =
      put_stream_state(socket,
        selected: channel,
        watching_uuid: channel.uuid,
        stream_status: :starting,
        playlist_url: nil,
        stream_error: nil,
        page_title: channel.name,
        encoder_statuses:
          put_encoder_status(socket.assigns.encoder_statuses, %{
            channel_uuid: channel.uuid,
            status: :starting
          })
      )

    if connected?(socket) do
      send(self(), {:ensure_watch, channel.uuid})
    end

    socket
  end

  defp attach_watch(socket, uuid) do
    case Manager.watch(uuid, self()) do
      {:ok, info} ->
        put_stream_state(socket,
          stream_status: info.status,
          playlist_url: info.playlist_url,
          stream_error: info.error,
          encoder_statuses:
            put_encoder_status(socket.assigns.encoder_statuses, %{
              channel_uuid: uuid,
              status: info.status
            })
        )

      {:error, :too_many_streams} ->
        put_stream_state(socket,
          watching_uuid: nil,
          stream_status: :error,
          stream_error: "Zu viele Kanäle laufen. Bitte versuche es in einem Moment erneut.",
          playlist_url: nil
        )

      {:error, reason} ->
        put_stream_state(socket,
          watching_uuid: nil,
          stream_status: :error,
          stream_error: "Kanal konnte nicht gestartet werden: #{inspect(reason)}",
          playlist_url: nil
        )
    end
  end

  # Assign stream fields and notify the VideoPlayer hook without relying on
  # DOM data-attribute patches (those re-triggered HLS reload / stutter).
  defp put_stream_state(socket, attrs) do
    socket
    |> assign(attrs)
    |> push_stream_state()
  end

  defp push_stream_state(socket) do
    if connected?(socket) do
      push_event(socket, "stream_state", %{
        status: to_string(socket.assigns.stream_status),
        playlist_url: socket.assigns.playlist_url
      })
    else
      socket
    end
  end

  defp filtered_channels(channels, ""), do: channels

  defp filtered_channels(channels, filter) do
    q = String.downcase(filter)

    Enum.filter(channels, fn channel ->
      String.contains?(String.downcase(channel.name), q) or
        String.contains?(to_string(channel.number || ""), q)
    end)
  end

  defp now_next(now_map, channel) do
    Map.get(now_map, channel.uuid, %{now: nil, next: nil})
  end

  defp icon_url(nil), do: nil

  defp icon_url(path) when is_binary(path) do
    "/icons/" <> String.trim_leading(path, "/")
  end

  defp programme_title(nil), do: "Keine Programminformation"
  defp programme_title(programme), do: Programme.display_text(programme)

  defp format_time(nil), do: ""

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Europe/Vienna")
    |> Calendar.strftime("%H:%M")
  end

  defp put_encoder_status(statuses, %{channel_uuid: uuid, status: :idle}) do
    Map.delete(statuses, uuid)
  end

  defp put_encoder_status(statuses, %{channel_uuid: uuid, status: status}) do
    Map.put(statuses, uuid, status)
  end

  defp encoder_status(statuses, channel_uuid) do
    Map.get(statuses, channel_uuid)
  end

  defp encoder_dot_class(:ready), do: "tv-encoder-dot-ready"
  defp encoder_dot_class(:starting), do: "tv-encoder-dot-starting"
  defp encoder_dot_class(:recording), do: "tv-encoder-dot-recording"
  defp encoder_dot_class(:error), do: "tv-encoder-dot-error"
  defp encoder_dot_class(_), do: "tv-encoder-dot-idle"

  defp encoder_dot_label(:ready), do: "Encoder läuft"
  defp encoder_dot_label(:starting), do: "Encoder startet"
  defp encoder_dot_label(:recording), do: "Aufnahme"
  defp encoder_dot_label(:error), do: "Encoder-Fehler"
  defp encoder_dot_label(_), do: "Encoder inaktiv"
end
