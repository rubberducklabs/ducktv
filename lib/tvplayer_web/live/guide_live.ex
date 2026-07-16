defmodule TvplayerWeb.GuideLive do
  use TvplayerWeb, :live_view

  alias Tvplayer.Tvheadend.{Cache, Programme}

  # 4px per minute → 1 hour = 240px, full day = 5760px
  @px_per_minute 4
  @day_minutes 24 * 60
  @timezone "Europe/Vienna"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tvplayer.PubSub, Cache.channels_topic())
    end

    day = today()
    channels = Cache.list_channels()

    socket =
      assign(socket,
        page_title: "TV-Programm",
        channels: channels,
        day: day,
        programmes_by_channel: %{},
        search: "",
        search_results: [],
        detail: nil,
        loading: connected?(socket),
        error: nil,
        px_per_minute: @px_per_minute,
        day_width: @day_minutes * @px_per_minute,
        now_offset: now_offset_px(day)
      )

    if connected?(socket), do: send(self(), :load_grid)

    {:ok, socket}
  end

  @impl true
  def handle_event("prev_day", _params, socket) do
    day = Date.add(socket.assigns.day, -1)

    send(self(), :load_grid)

    {:noreply,
     assign(socket,
       day: day,
       detail: nil,
       search: "",
       search_results: [],
       now_offset: now_offset_px(day),
       loading: true,
       programmes_by_channel: %{}
     )}
  end

  def handle_event("next_day", _params, socket) do
    day = Date.add(socket.assigns.day, 1)

    send(self(), :load_grid)

    {:noreply,
     assign(socket,
       day: day,
       detail: nil,
       search: "",
       search_results: [],
       now_offset: now_offset_px(day),
       loading: true,
       programmes_by_channel: %{}
     )}
  end

  def handle_event("jump_now", _params, socket) do
    day = today()

    send(self(), {:load_grid, scroll: true})

    {:noreply,
     assign(socket,
       day: day,
       search: "",
       search_results: [],
       detail: nil,
       now_offset: now_offset_px(day),
       loading: true
     )}
  end

  def handle_event("search", %{"q" => q}, socket) do
    q = String.trim(q)
    socket = assign(socket, search: q)

    socket =
      if String.length(q) >= 2 do
        case Cache.search(q) do
          {:ok, results} -> assign(socket, search_results: results, error: nil)
          {:error, reason} -> assign(socket, search_results: [], error: inspect(reason))
        end
      else
        assign(socket, search_results: [])
      end

    {:noreply, socket}
  end

  def handle_event("show_detail", %{"id" => id}, socket) do
    id = String.to_integer(id)

    detail =
      socket.assigns.programmes_by_channel
      |> Map.values()
      |> List.flatten()
      |> Enum.find(&(&1.event_id == id)) ||
        Enum.find(socket.assigns.search_results, &(&1.event_id == id))

    {:noreply, assign(socket, detail: detail)}
  end

  def handle_event("close_detail", _params, socket) do
    {:noreply, assign(socket, detail: nil)}
  end

  def handle_event("watch_channel", %{"uuid" => uuid}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/?channel=#{uuid}")}
  end

  @impl true
  def handle_info(:load_grid, socket) do
    {:noreply, load_grid(socket, socket.assigns.day)}
  end

  def handle_info({:load_grid, scroll: true}, socket) do
    {:noreply, socket |> load_grid(socket.assigns.day) |> scroll_to_now()}
  end

  def handle_info({:channels_updated, channels}, socket) do
    {:noreply, assign(socket, channels: channels)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_grid(socket, day) do
    {from, to} = day_bounds(day)

    socket = assign(socket, loading: true, error: nil)

    case Cache.events_grid(from, to) do
      {:ok, by_channel} ->
        socket =
          assign(socket,
            programmes_by_channel: by_channel,
            loading: false,
            now_offset: now_offset_px(day)
          )

        if day == today(), do: scroll_to_now(socket), else: socket

      {:error, reason} ->
        assign(socket, programmes_by_channel: %{}, loading: false, error: inspect(reason))
    end
  end

  defp scroll_to_now(socket) do
    offset = socket.assigns.now_offset

    if is_integer(offset) do
      push_event(socket, "epg_scroll_to", %{offset: offset})
    else
      socket
    end
  end

  defp today do
    DateTime.now!(@timezone) |> DateTime.to_date()
  end

  defp day_bounds(%Date{} = day) do
    from =
      case DateTime.new(day, ~T[00:00:00], @timezone) do
        {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
        {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
        {:gap, _a, b} -> DateTime.shift_zone!(b, "Etc/UTC")
      end

    to = DateTime.add(from, 24 * 3600, :second)
    {from, to}
  end

  defp now_offset_px(%Date{} = day) do
    if day == today() do
      now = DateTime.now!(@timezone)
      day_start = DateTime.new!(day, ~T[00:00:00], @timezone)
      minutes = DateTime.diff(now, day_start, :second) / 60
      round(minutes * @px_per_minute)
    else
      nil
    end
  end

  defp channel_programmes(by_channel, channel) do
    Map.get(by_channel, channel.uuid, [])
  end

  defp programme_style(programme, day) do
    {day_start_utc, day_end_utc} = day_bounds(day)

    start_at = later(programme.starts_at, day_start_utc)
    end_at = earlier(programme.ends_at, day_end_utc)

    start_min = max(DateTime.diff(start_at, day_start_utc, :second) / 60, 0)
    duration_min = max(DateTime.diff(end_at, start_at, :second) / 60, 1)

    left = start_min * @px_per_minute
    width = max(duration_min * @px_per_minute, 2)

    "left: #{round(left)}px; width: #{round(width)}px"
  end

  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp programme_now?(programme) do
    Programme.now?(programme)
  end

  defp hour_marks do
    Enum.map(0..23, fn hour ->
      %{
        hour: hour,
        label: String.pad_leading(Integer.to_string(hour), 2, "0") <> ":00",
        offset: hour * 60 * @px_per_minute
      }
    end)
  end

  defp format_time(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!(@timezone)
    |> Calendar.strftime("%H:%M")
  end

  defp format_day(%Date{} = day) do
    weekday =
      Enum.at(~w(Mo Di Mi Do Fr Sa So), Date.day_of_week(day) - 1)

    month =
      Enum.at(~w(Jan Feb Mär Apr Mai Jun Jul Aug Sep Okt Nov Dez), day.month - 1)

    "#{weekday} #{day.day}. #{month}"
  end

  defp programme_title(nil), do: "Keine Programminformation"
  defp programme_title(p), do: Programme.display_text(p)

  defp truncate(nil, _), do: ""

  defp truncate(text, max) when is_binary(text) do
    text = String.trim(text)

    if String.length(text) <= max do
      text
    else
      String.slice(text, 0, max) <> "…"
    end
  end
end
