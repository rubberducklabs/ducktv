defmodule TvplayerWeb.RecordingsLive do
  use TvplayerWeb, :live_view

  alias Tvplayer.Recordings.{ShareLink, Transcoder}
  alias Tvplayer.Tvheadend.{Cache, Channel, Dvr, Recording}

  @timezone "Europe/Vienna"
  @padding_options [0, 5, 10, 15]
  @duration_options [30, 60, 90, 120]
  # Manual timers may span midnight (e.g. 23:30–01:00), but never silently
  # roll a same-day end-before-start typo into a ~24h recording.
  @max_duration_minutes 12 * 60
  @filters [:all, :scheduled, :recording, :completed, :failed, :removed]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Cache.channels_topic())
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Cache.dvr_topic())
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Transcoder.topic())
    end

    recordings = Cache.recordings()
    channels = Cache.list_channels()
    padding = Cache.default_padding()

    socket =
      socket
      |> assign(
        page_title: "Aufnahmen",
        channels: channels,
        recordings: recordings,
        filter: :all,
        recording_active?: Enum.any?(recordings, &(&1.state == :recording)),
        padding_options: @padding_options,
        duration_options: @duration_options,
        confirm_delete_uuid: nil,
        edit: nil,
        edit_start_extra: 0,
        edit_stop_extra: 0,
        new_form_open?: false,
        channel_query: "",
        selected_channel: nil,
        form_day: today(),
        form_custom_day?: false,
        form_start_time: default_start_time(),
        form_duration: 60,
        form_end_time: default_end_time(default_start_time(), 60),
        form_start_extra: padding.pre || 0,
        form_stop_extra: padding.post || 0,
        form_title: "",
        form_error: nil,
        transcodes: Transcoder.statuses(),
        download_menu_uuid: nil,
        share_uuid: nil,
        share_url: nil,
        pending_play_uuid: nil,
        playing_uuid: nil
      )
      |> assign_filtered()

    {:ok, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    filter =
      case filter do
        "scheduled" -> :scheduled
        "recording" -> :recording
        "completed" -> :completed
        "failed" -> :failed
        "removed" -> :removed
        _ -> :all
      end

    {:noreply, socket |> assign(filter: filter) |> assign_filtered()}
  end

  def handle_event("cancel_recording", %{"uuid" => uuid}, socket) do
    case Dvr.cancel_or_stop(uuid) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign_from_cache()
         |> put_flash(:info, "Aufnahme abgebrochen")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Abbrechen fehlgeschlagen: #{inspect(reason)}")}
    end
  end

  def handle_event("confirm_delete", %{"uuid" => uuid}, socket) do
    {:noreply, assign(socket, confirm_delete_uuid: uuid)}
  end

  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, confirm_delete_uuid: nil)}
  end

  def handle_event("delete_recording", %{"uuid" => uuid}, socket) do
    case Dvr.remove(uuid) do
      {:ok, _} ->
        Transcoder.delete_output(uuid)

        {:noreply,
         socket
         |> assign(confirm_delete_uuid: nil)
         |> assign(transcodes: Map.delete(socket.assigns.transcodes, uuid))
         |> assign_from_cache()
         |> put_flash(:info, "Aufnahme gelöscht")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Löschen fehlgeschlagen: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_download_menu", %{"uuid" => uuid}, socket) do
    open? = socket.assigns.download_menu_uuid == uuid
    {:noreply, assign(socket, download_menu_uuid: if(open?, do: nil, else: uuid))}
  end

  def handle_event("close_download_menu", _params, socket) do
    {:noreply, assign(socket, download_menu_uuid: nil)}
  end

  def handle_event("open_share", %{"uuid" => uuid}, socket) do
    case find_shareable(socket, uuid) do
      %Recording{} ->
        {:noreply,
         assign(socket,
           share_uuid: uuid,
           share_url: ShareLink.url_for(uuid),
           download_menu_uuid: nil
         )}

      nil ->
        {:noreply,
         put_flash(socket, :error, "Teilen erst möglich, wenn die Web-Version bereit ist.")}
    end
  end

  def handle_event("close_share", _params, socket) do
    {:noreply, assign(socket, share_uuid: nil, share_url: nil)}
  end

  def handle_event("start_web_version", %{"uuid" => uuid}, socket) do
    case find_downloadable(socket, uuid) do
      %Recording{} ->
        # Optimistic UI: show queued state immediately, then enqueue.
        socket =
          assign(socket,
            download_menu_uuid: nil,
            transcodes: Map.put(socket.assigns.transcodes, uuid, :queued)
          )

        status = Transcoder.request(uuid)

        {:noreply,
         socket
         |> assign(transcodes: Map.put(socket.assigns.transcodes, uuid, status))
         |> put_flash(:info, web_version_flash(status))}

      nil ->
        {:noreply, put_flash(socket, :error, "Aufnahme nicht verfügbar")}
    end
  end

  def handle_event("watch_recording", %{"uuid" => uuid}, socket) do
    case find_downloadable(socket, uuid) do
      %Recording{} ->
        current = Map.get(socket.assigns.transcodes, uuid) || Transcoder.status(uuid)

        if current == :done do
          {:noreply,
           assign(socket,
             playing_uuid: uuid,
             pending_play_uuid: nil,
             download_menu_uuid: nil
           )}
        else
          socket =
            assign(socket,
              pending_play_uuid: uuid,
              download_menu_uuid: nil,
              transcodes: Map.put(socket.assigns.transcodes, uuid, :queued)
            )

          status = Transcoder.request(uuid)

          {:noreply, assign(socket, transcodes: Map.put(socket.assigns.transcodes, uuid, status))}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Aufnahme nicht verfügbar")}
    end
  end

  def handle_event("close_player", _params, socket) do
    {:noreply, assign(socket, playing_uuid: nil)}
  end

  def handle_event("retry_transcode", %{"uuid" => uuid}, socket) do
    socket = assign(socket, transcodes: Map.put(socket.assigns.transcodes, uuid, :queued))
    status = Transcoder.request(uuid)

    {:noreply, assign(socket, transcodes: Map.put(socket.assigns.transcodes, uuid, status))}
  end

  def handle_event("cancel_transcode", %{"uuid" => uuid}, socket) do
    :ok = Transcoder.cancel(uuid)

    socket =
      socket
      |> assign(transcodes: Map.delete(socket.assigns.transcodes, uuid))
      |> then(fn s ->
        if s.assigns.pending_play_uuid == uuid do
          assign(s, pending_play_uuid: nil)
        else
          s
        end
      end)
      |> put_flash(:info, "Konvertierung abgebrochen")

    {:noreply, socket}
  end

  def handle_event("open_edit", %{"uuid" => uuid}, socket) do
    case Enum.find(socket.assigns.recordings, &(&1.uuid == uuid)) do
      %Recording{state: :scheduled} = recording ->
        {:noreply,
         assign(socket,
           edit: recording,
           edit_start_extra: recording.start_extra || 0,
           edit_stop_extra: recording.stop_extra || 0,
           new_form_open?: false
         )}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close_edit", _params, socket) do
    {:noreply, assign(socket, edit: nil)}
  end

  def handle_event("set_edit_start_extra", %{"minutes" => minutes}, socket) do
    {:noreply, assign(socket, edit_start_extra: String.to_integer(minutes))}
  end

  def handle_event("set_edit_stop_extra", %{"minutes" => minutes}, socket) do
    {:noreply, assign(socket, edit_stop_extra: String.to_integer(minutes))}
  end

  def handle_event("save_edit", %{"start" => start_str, "stop" => stop_str}, socket) do
    case socket.assigns.edit do
      %Recording{} = recording ->
        with {:ok, starts_at} <- parse_local_datetime(start_str),
             {:ok, ends_at} <- parse_local_datetime(stop_str),
             true <- DateTime.compare(ends_at, starts_at) == :gt,
             {:ok, _} <-
               Dvr.update(recording.uuid, %{
                 start: starts_at,
                 stop: ends_at,
                 start_extra: socket.assigns.edit_start_extra,
                 stop_extra: socket.assigns.edit_stop_extra
               }) do
          {:noreply,
           socket
           |> assign(edit: nil)
           |> assign_from_cache()
           |> put_flash(:info, "Aufnahme aktualisiert: #{recording.title}")}
        else
          false ->
            {:noreply, put_flash(socket, :error, "Ende muss nach dem Start liegen.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Speichern fehlgeschlagen: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("open_new", _params, socket) do
    padding = Cache.default_padding()

    start_time = default_start_time()

    {:noreply,
     assign(socket,
       new_form_open?: true,
       edit: nil,
       channel_query: "",
       selected_channel: nil,
       form_day: today(),
       form_custom_day?: false,
       form_start_time: start_time,
       form_duration: 60,
       form_end_time: default_end_time(start_time, 60),
       form_start_extra: padding.pre || 0,
       form_stop_extra: padding.post || 0,
       form_title: "",
       form_error: nil
     )}
  end

  def handle_event("close_new", _params, socket) do
    {:noreply, assign(socket, new_form_open?: false, form_error: nil)}
  end

  def handle_event("select_channel", %{"uuid" => uuid}, socket) do
    channel = Enum.find(socket.assigns.channels, &(&1.uuid == uuid))
    {:noreply, assign(socket, selected_channel: channel, channel_query: "", form_error: nil)}
  end

  def handle_event("clear_channel", _params, socket) do
    {:noreply, assign(socket, selected_channel: nil)}
  end

  def handle_event("set_form_day", %{"day" => day}, socket) do
    {:noreply,
     assign(socket,
       form_day: Date.from_iso8601!(day),
       form_custom_day?: false,
       form_error: nil
     )}
  end

  def handle_event("set_form_custom_day", _params, socket) do
    {:noreply, assign(socket, form_custom_day?: true, form_error: nil)}
  end

  def handle_event("set_form_duration", %{"minutes" => minutes}, socket) do
    duration = String.to_integer(minutes)

    {:noreply,
     assign(socket,
       form_duration: duration,
       form_end_time: default_end_time(socket.assigns.form_start_time, duration),
       form_error: nil
     )}
  end

  def handle_event("set_form_start_extra", %{"minutes" => minutes}, socket) do
    {:noreply, assign(socket, form_start_extra: String.to_integer(minutes))}
  end

  def handle_event("set_form_stop_extra", %{"minutes" => minutes}, socket) do
    {:noreply, assign(socket, form_stop_extra: String.to_integer(minutes))}
  end

  def handle_event("validate_new", params, socket) do
    socket =
      socket
      |> assign(form_error: nil)
      |> maybe_assign_date(params)
      |> maybe_assign_times(params)
      |> maybe_assign_title(params)
      |> maybe_assign_channel_query(params)

    {:noreply, socket}
  end

  def handle_event("create_recording", params, socket) do
    socket =
      socket
      |> maybe_assign_date(params)
      |> maybe_assign_times(params)
      |> maybe_assign_title(params)

    case create_manual(socket) do
      {:ok, recording} ->
        title = if recording, do: recording.title, else: "Aufnahme"

        {:noreply,
         socket
         |> assign(new_form_open?: false, form_error: nil)
         |> assign_from_cache()
         |> put_flash(:info, "Aufnahme geplant: #{title}")}

      {:error, message} when is_binary(message) ->
        {:noreply, assign(socket, form_error: message)}

      {:error, reason} ->
        {:noreply, assign(socket, form_error: "Fehler: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:channels_updated, channels}, socket) do
    {:noreply, assign(socket, channels: channels)}
  end

  def handle_info({:dvr_updated, recordings}, socket) do
    {:noreply,
     socket
     |> assign(
       recordings: recordings,
       recording_active?: Enum.any?(recordings, &(&1.state == :recording))
     )
     |> assign_filtered()}
  end

  def handle_info({:transcode, uuid, status}, socket) do
    previous = Map.get(socket.assigns.transcodes, uuid)

    transcodes =
      if is_nil(status) do
        Map.delete(socket.assigns.transcodes, uuid)
      else
        Map.put(socket.assigns.transcodes, uuid, status)
      end

    socket = assign(socket, transcodes: transcodes)

    socket =
      if status == :done and socket.assigns.pending_play_uuid == uuid do
        assign(socket, playing_uuid: uuid, pending_play_uuid: nil)
      else
        socket
      end

    socket =
      if status == :done and previous != :done do
        put_flash(socket, :info, "Web-Version ist bereit.")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_from_cache(socket) do
    recordings = Cache.recordings()

    socket
    |> assign(
      recordings: recordings,
      recording_active?: Enum.any?(recordings, &(&1.state == :recording))
    )
    |> assign_filtered()
  end

  defp assign_filtered(socket) do
    filtered =
      case socket.assigns.filter do
        :all -> socket.assigns.recordings
        state -> Enum.filter(socket.assigns.recordings, &(&1.state == state))
      end

    filtered =
      Enum.sort_by(filtered, fn recording ->
        {sort_rank(recording.state), DateTime.to_unix(recording.starts_at)}
      end)

    counts =
      Enum.reduce(@filters -- [:all], %{all: length(socket.assigns.recordings)}, fn state, acc ->
        Map.put(acc, state, Enum.count(socket.assigns.recordings, &(&1.state == state)))
      end)

    assign(socket, filtered_recordings: filtered, filter_counts: counts)
  end

  defp sort_rank(:recording), do: 0
  defp sort_rank(:scheduled), do: 1
  defp sort_rank(:failed), do: 2
  defp sort_rank(:completed), do: 3
  defp sort_rank(:removed), do: 4

  defp create_manual(socket) do
    with %Channel{} = channel <- socket.assigns.selected_channel || :missing_channel,
         {:ok, starts_at} <-
           local_datetime(socket.assigns.form_day, socket.assigns.form_start_time),
         {:ok, duration} <-
           minutes_between(socket.assigns.form_start_time, socket.assigns.form_end_time) do
      # Stop is start + validated duration so midnight-spanning timers stay exact,
      # and end-before-start typos cannot roll into a multi-hour next-day recording.
      ends_at = DateTime.add(starts_at, duration * 60, :second)

      title =
        case String.trim(socket.assigns.form_title || "") do
          "" -> "#{channel.name} · #{format_time(starts_at)}"
          custom -> custom
        end

      Dvr.create(%{
        channel: channel.uuid,
        channel_name: channel.name,
        start: starts_at,
        stop: ends_at,
        title: title,
        start_extra: socket.assigns.form_start_extra,
        stop_extra: socket.assigns.form_stop_extra
      })
    else
      :missing_channel -> {:error, "Bitte einen Kanal wählen."}
      :invalid -> {:error, duration_error_message()}
      {:error, :invalid_time} -> {:error, "Ungültige Start- oder Endzeit."}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_assign_date(socket, %{"date" => date}) when is_binary(date) and date != "" do
    case Date.from_iso8601(date) do
      {:ok, day} ->
        assign(socket,
          form_day: day,
          form_custom_day?: not preset_day?(day)
        )

      _ ->
        socket
    end
  end

  defp maybe_assign_date(socket, _), do: socket

  defp maybe_assign_times(socket, params) do
    start_raw = blank_to_nil(Map.get(params, "start_time"))
    end_raw = blank_to_nil(Map.get(params, "end_time"))
    start_time = normalize_time(start_raw)
    end_time = normalize_time(end_raw)

    start_changed? = start_time && start_time != socket.assigns.form_start_time
    end_changed? = end_time && end_time != socket.assigns.form_end_time

    cond do
      start_changed? and end_changed? ->
        case minutes_between(start_time, end_time) do
          {:ok, duration} ->
            assign(socket,
              form_start_time: start_time,
              form_end_time: end_time,
              form_duration: duration
            )

          :invalid ->
            duration = socket.assigns.form_duration

            assign(socket,
              form_start_time: start_time,
              form_end_time: default_end_time(start_time, duration),
              form_duration: duration,
              form_error: duration_error_message()
            )
        end

      start_changed? ->
        duration = socket.assigns.form_duration

        assign(socket,
          form_start_time: start_time,
          form_end_time: default_end_time(start_time, duration)
        )

      end_changed? ->
        case minutes_between(socket.assigns.form_start_time, end_time) do
          {:ok, duration} ->
            assign(socket, form_end_time: end_time, form_duration: duration)

          :invalid ->
            assign(socket,
              form_end_time: end_time,
              form_error: duration_error_message()
            )
        end

      start_raw && start_raw != socket.assigns.form_start_time ->
        assign(socket, form_start_time: start_raw)

      end_raw && end_raw != socket.assigns.form_end_time ->
        assign(socket, form_end_time: end_raw)

      true ->
        socket
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value) when is_binary(value), do: value

  defp maybe_assign_title(socket, %{"title" => title}) when is_binary(title) do
    assign(socket, form_title: title)
  end

  defp maybe_assign_title(socket, _), do: socket

  defp maybe_assign_channel_query(socket, %{"q" => q}) when is_binary(q) do
    assign(socket, channel_query: q)
  end

  defp maybe_assign_channel_query(socket, _), do: socket

  defp filtered_channels(channels, ""), do: Enum.take(channels, 12)

  defp filtered_channels(channels, query) do
    q = String.downcase(query)

    channels
    |> Enum.filter(fn channel ->
      String.contains?(String.downcase(channel.name), q) or
        String.contains?(to_string(channel.number || ""), q)
    end)
    |> Enum.take(12)
  end

  defp day_options do
    today = today()

    Enum.map(0..6, fn offset ->
      day = Date.add(today, offset)
      {day, day_chip_label(day, offset)}
    end)
  end

  defp day_chip_label(_day, 0), do: "Heute"
  defp day_chip_label(_day, 1), do: "Morgen"

  defp day_chip_label(day, _) do
    weekday = Enum.at(~w(Mo Di Mi Do Fr Sa So), Date.day_of_week(day) - 1)
    "#{weekday} #{day.day}."
  end

  defp preset_day?(%Date{} = day) do
    Date.diff(day, today()) in 0..6
  end

  defp today, do: DateTime.now!(@timezone) |> DateTime.to_date()

  defp default_start_time do
    now = DateTime.now!(@timezone)
    # Round up to next 5-minute mark
    total_minutes = now.hour * 60 + now.minute + 15
    rounded = div(total_minutes + 4, 5) * 5
    format_clock(rem(div(rounded, 60), 24), rem(rounded, 60))
  end

  defp default_end_time(start_time, duration_minutes)
       when is_binary(start_time) and is_integer(duration_minutes) do
    case parse_clock(start_time) do
      {:ok, hour, minute} ->
        total = hour * 60 + minute + duration_minutes
        format_clock(rem(div(total, 60), 24), rem(total, 60))

      :error ->
        start_time
    end
  end

  defp minutes_between(start_time, end_time)
       when is_binary(start_time) and is_binary(end_time) do
    with {:ok, sh, sm} <- parse_clock(start_time),
         {:ok, eh, em} <- parse_clock(end_time) do
      start_mins = sh * 60 + sm
      end_mins = eh * 60 + em
      duration = end_mins - start_mins

      duration =
        if duration <= 0 do
          # Only treat as next-day when the span is a plausible overnight timer.
          duration + 24 * 60
        else
          duration
        end

      if valid_duration?(duration), do: {:ok, duration}, else: :invalid
    else
      _ -> :invalid
    end
  end

  defp valid_duration?(duration)
       when is_integer(duration) and duration > 0 and duration <= @max_duration_minutes,
       do: true

  defp valid_duration?(_), do: false

  defp duration_error_message do
    hours = div(@max_duration_minutes, 60)
    "Endzeit muss nach dem Start liegen (max. #{hours} Std)."
  end

  defp normalize_time(nil), do: nil
  defp normalize_time(""), do: nil

  defp normalize_time(time) when is_binary(time) do
    case parse_clock(time) do
      {:ok, hour, minute} -> format_clock(hour, minute)
      :error -> nil
    end
  end

  defp parse_clock(time) when is_binary(time) do
    parts = String.split(time, ":")

    with [h, m | _] <- parts,
         {hour, ""} <- Integer.parse(h),
         {minute, ""} <- Integer.parse(m),
         true <- hour in 0..23 and minute in 0..59 do
      {:ok, hour, minute}
    else
      _ -> :error
    end
  end

  defp format_clock(hour, minute) do
    String.pad_leading(Integer.to_string(hour), 2, "0") <>
      ":" <> String.pad_leading(Integer.to_string(minute), 2, "0")
  end

  defp local_datetime(%Date{} = day, time_str) when is_binary(time_str) do
    with {:ok, hour, minute} <- parse_clock(time_str),
         {:ok, time} <- Time.new(hour, minute, 0),
         result <- DateTime.new(day, time, @timezone) do
      case result do
        {:ok, dt} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
        {:ambiguous, dt, _} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
        {:gap, _, b} -> {:ok, DateTime.shift_zone!(b, "Etc/UTC")}
        _ -> {:error, :invalid_time}
      end
    else
      _ -> {:error, :invalid_time}
    end
  end

  defp parse_local_datetime(str) when is_binary(str) do
    # Expect "YYYY-MM-DDTHH:MM" from datetime-local input
    case NaiveDateTime.from_iso8601(str <> ":00") do
      {:ok, naive} ->
        case DateTime.from_naive(naive, @timezone) do
          {:ok, dt} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
          {:ambiguous, dt, _} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
          {:gap, _, b} -> {:ok, DateTime.shift_zone!(b, "Etc/UTC")}
          _ -> {:error, :invalid_time}
        end

      _ ->
        # Try without forcing seconds
        case NaiveDateTime.from_iso8601(str) do
          {:ok, naive} ->
            case DateTime.from_naive(naive, @timezone) do
              {:ok, dt} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
              {:ambiguous, dt, _} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
              {:gap, _, b} -> {:ok, DateTime.shift_zone!(b, "Etc/UTC")}
              _ -> {:error, :invalid_time}
            end

          _ ->
            {:error, :invalid_time}
        end
    end
  end

  defp to_datetime_local(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!(@timezone)
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end

  defp format_time(nil), do: nil

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!(@timezone)
    |> Calendar.strftime("%H:%M")
  end

  defp format_datetime(%DateTime{} = dt) do
    local = DateTime.shift_zone!(dt, @timezone)
    weekday = Enum.at(~w(Mo Di Mi Do Fr Sa So), Date.day_of_week(DateTime.to_date(local)) - 1)
    "#{weekday} #{Calendar.strftime(local, "%d.%m. %H:%M")}"
  end

  defp format_time_range(%DateTime{} = starts_at, %DateTime{} = ends_at) do
    start_local = DateTime.shift_zone!(starts_at, @timezone)
    end_local = DateTime.shift_zone!(ends_at, @timezone)

    end_str =
      if Date.compare(DateTime.to_date(start_local), DateTime.to_date(end_local)) == :eq do
        format_time(ends_at)
      else
        Calendar.strftime(end_local, "%d.%m. %H:%M")
      end

    "#{format_datetime(starts_at)} – #{end_str}"
  end

  defp format_filesize(nil), do: nil
  defp format_filesize(0), do: nil

  defp format_filesize(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_000_000_000 -> "#{Float.round(bytes / 1_000_000_000, 1)} GB"
      bytes >= 1_000_000 -> "#{Float.round(bytes / 1_000_000, 1)} MB"
      true -> "#{bytes} B"
    end
  end

  defp padding_label(recording) do
    pre = recording.start_extra || 0
    post = recording.stop_extra || 0

    cond do
      pre == 0 and post == 0 -> nil
      pre == post -> "±#{pre} Min"
      true -> "−#{pre} / +#{post} Min"
    end
  end

  defp icon_url(nil), do: nil

  defp icon_url(path) when is_binary(path) do
    "/icons/" <> String.trim_leading(path, "/")
  end

  defp channel_icon(channels, channel_uuid) do
    channels
    |> Enum.find(&(&1.uuid == channel_uuid))
    |> case do
      %{icon_path: path} -> icon_url(path)
      _ -> nil
    end
  end

  defp filter_label(:all), do: "Alle"
  defp filter_label(:scheduled), do: "Geplant"
  defp filter_label(:recording), do: "Läuft"
  defp filter_label(:completed), do: "Abgeschlossen"
  defp filter_label(:failed), do: "Fehlgeschlagen"
  defp filter_label(:removed), do: "Gelöscht"

  defp state_label(state), do: Recording.state_label(state)

  defp downloadable?(recording), do: Recording.downloadable?(recording)

  defp download_filename(recording), do: Recording.download_filename(recording)

  defp web_download_filename(recording), do: Recording.web_download_filename(recording)

  defp chip_active?(current, value), do: current == value

  defp find_downloadable(socket, uuid) do
    case Enum.find(socket.assigns.recordings, &(&1.uuid == uuid)) do
      %Recording{} = recording ->
        if Recording.downloadable?(recording), do: recording, else: nil

      _ ->
        nil
    end
  end

  defp find_shareable(socket, uuid) do
    with %Recording{} = recording <- find_downloadable(socket, uuid),
         :done <- Map.get(socket.assigns.transcodes, uuid) || Transcoder.status(uuid) do
      recording
    else
      _ -> nil
    end
  end

  defp share_validity_label, do: ShareLink.validity_label()

  defp transcode_status(transcodes, uuid), do: Map.get(transcodes, uuid)

  defp playing_recording(nil, _recordings), do: nil

  defp playing_recording(uuid, recordings) do
    Enum.find(recordings, &(&1.uuid == uuid))
  end

  defp web_version_flash(:done), do: "Web-Version ist bereit."
  defp web_version_flash(:queued), do: "Web-Version wird vorbereitet…"
  defp web_version_flash({:running, _}), do: "Web-Version wird konvertiert…"
  defp web_version_flash({:failed, _}), do: "Konvertierung fehlgeschlagen."
  defp web_version_flash(_), do: "Web-Version wird vorbereitet…"

  defp transcode_label(:queued), do: "In Warteschlange"
  defp transcode_label({:running, percent}), do: "Wird konvertiert · #{percent}%"
  defp transcode_label({:failed, _}), do: "Konvertierung fehlgeschlagen"
  defp transcode_label(_), do: nil

  defp watch_button_label(:done), do: "Abspielen"
  defp watch_button_label(_), do: "Ansehen"

  defp transcode_cancellable?(:queued), do: true
  defp transcode_cancellable?({:running, _}), do: true
  defp transcode_cancellable?(_), do: false

  defp transcode_percent({:running, percent}) when is_integer(percent), do: percent
  defp transcode_percent(:queued), do: 0
  defp transcode_percent(_), do: nil
end
