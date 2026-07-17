defmodule TvplayerWeb.WatchLive do
  use TvplayerWeb, :live_view

  alias Tvplayer.Streams.{Manager, Session}
  alias Tvplayer.Tvheadend.{Cache, Dvr, Programme, Recording}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Cache.channels_topic())
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Cache.epg_topic())
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Cache.dvr_topic())
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Session.all_topic())
    end

    channels = Cache.list_channels()
    now_map = Cache.now_map()
    recordings = Cache.recordings()

    encoder_statuses =
      if connected?(socket), do: Manager.session_statuses(), else: %{}

    socket =
      assign(socket,
        page_title: "Fernsehen",
        channels: channels,
        now_map: now_map,
        recordings: recordings,
        recording_active?: Enum.any?(recordings, &(&1.state == :recording)),
        current_recording: nil,
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

  def handle_event("record_now", _params, socket) do
    case current_programme(socket) do
      %Programme{event_id: event_id, title: title} ->
        case Dvr.record_event(event_id) do
          {:ok, recording} ->
            {:noreply,
             socket
             |> assign_recordings(Cache.recordings())
             |> assign(current_recording: recording || Cache.recording_for_event(event_id))
             |> put_flash(:info, "Aufnahme gestartet: #{title}")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Aufnahme fehlgeschlagen: #{format_error(reason)}")}
        end

      nil ->
        case record_manual_fallback(socket) do
          {:ok, recording} ->
            title = if recording, do: recording.title, else: "Kanal"

            {:noreply,
             socket
             |> assign_recordings(Cache.recordings())
             |> assign(current_recording: recording)
             |> put_flash(:info, "Aufnahme gestartet: #{title}")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Aufnahme fehlgeschlagen: #{format_error(reason)}")}
        end
    end
  end

  def handle_event("stop_recording", _params, socket) do
    case socket.assigns.current_recording do
      %Recording{} = recording ->
        case Dvr.cancel_or_stop(recording) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign_recordings(Cache.recordings())
             |> assign(current_recording: nil)
             |> put_flash(:info, "Aufnahme gestoppt")}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Stoppen fehlgeschlagen: #{format_error(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
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
    socket =
      socket
      |> assign(now_map: now_map)
      |> sync_current_recording()

    {:noreply, socket}
  end

  def handle_info({:dvr_updated, recordings}, socket) do
    {:noreply, assign_recordings(socket, recordings)}
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
      playlist_url: nil,
      current_recording: nil
    )
  end

  defp maybe_start_channel(socket, channel) do
    socket =
      if socket.assigns[:watching_uuid] == channel.uuid and
           socket.assigns[:stream_status] in [:ready, :starting] do
        assign(socket, selected: channel, page_title: channel.name)
      else
        do_start_channel(socket, channel)
      end

    sync_current_recording(socket)
  end

  defp do_start_channel(socket, channel) do
    old_uuid = socket.assigns[:watching_uuid]

    if old_uuid && old_uuid != channel.uuid do
      Manager.unwatch(old_uuid, self())
    end

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

  defp assign_recordings(socket, recordings) do
    socket
    |> assign(
      recordings: recordings,
      recording_active?: Enum.any?(recordings, &(&1.state == :recording))
    )
    |> sync_current_recording()
  end

  defp sync_current_recording(socket) do
    recording =
      case current_programme(socket) do
        %Programme{event_id: event_id} ->
          Cache.recording_for_event(event_id) || channel_recording(socket)

        nil ->
          channel_recording(socket)
      end

    assign(socket, current_recording: recording)
  end

  defp channel_recording(socket) do
    case socket.assigns.selected do
      %{uuid: uuid} -> Cache.recording_for_channel(uuid)
      _ -> nil
    end
  end

  defp current_programme(socket) do
    case socket.assigns.selected do
      %{uuid: uuid} ->
        case Map.get(socket.assigns.now_map, uuid) do
          %{now: %Programme{} = programme} -> programme
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp record_manual_fallback(socket) do
    case socket.assigns.selected do
      %{uuid: uuid, name: name} = channel ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        ends_at =
          case current_programme(socket) do
            %Programme{ends_at: ends_at} -> ends_at
            _ -> DateTime.add(now, 2 * 3600, :second)
          end

        Dvr.create(%{
          channel: uuid,
          channel_name: name,
          start: now,
          stop: ends_at,
          title: "Aufnahme · #{channel.name}"
        })

      _ ->
        {:error, :no_channel}
    end
  end

  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

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

  defp recording?(nil), do: false
  defp recording?(%Recording{state: state}), do: state in [:scheduled, :recording]
end
