defmodule Tvplayer.Tvheadend.Cache do
  @moduledoc """
  In-memory cache for TVHeadend channels and EPG data.
  """

  use GenServer

  alias Tvplayer.Tvheadend.{Client, Programme}

  @channels_topic "tvheadend:channels"
  @epg_topic "tvheadend:epg"
  @refresh_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def list_channels do
    GenServer.call(__MODULE__, :list_channels)
  end

  def get_channel(uuid) when is_binary(uuid) do
    GenServer.call(__MODULE__, {:get_channel, uuid})
  end

  def get_channel_by_number(number) when is_integer(number) do
    GenServer.call(__MODULE__, {:get_channel_by_number, number})
  end

  def default_channel do
    GenServer.call(__MODULE__, :default_channel)
  end

  def now_for(channel_uuid) when is_binary(channel_uuid) do
    GenServer.call(__MODULE__, {:now_for, channel_uuid})
  end

  def now_map do
    GenServer.call(__MODULE__, :now_map)
  end

  def events_for(channel_uuid, from, to)
      when is_binary(channel_uuid) and is_struct(from, DateTime) and is_struct(to, DateTime) do
    GenServer.call(__MODULE__, {:events_for, channel_uuid, from, to}, 15_000)
  end

  @doc """
  Returns EPG events for all channels in a time window, grouped by channel UUID.
  """
  def events_grid(from, to)
      when is_struct(from, DateTime) and is_struct(to, DateTime) do
    GenServer.call(__MODULE__, {:events_grid, from, to}, 60_000)
  end

  def search(query) when is_binary(query) do
    GenServer.call(__MODULE__, {:search, query}, 15_000)
  end

  def refresh do
    GenServer.cast(__MODULE__, :refresh)
  end

  def load_fixture(channels, now_map \\ %{}, events_by_channel \\ %{})
      when is_list(channels) and is_map(now_map) and is_map(events_by_channel) do
    GenServer.call(__MODULE__, {:load_fixture, channels, now_map, events_by_channel})
  end

  def channels_topic, do: @channels_topic
  def epg_topic, do: @epg_topic

  @impl true
  def init(_opts) do
    state = %{
      channels: [],
      channels_by_uuid: %{},
      channels_by_number: %{},
      now_by_channel: %{},
      events_cache: %{},
      last_error: nil
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:list_channels, _from, state) do
    {:reply, state.channels, state}
  end

  def handle_call({:get_channel, uuid}, _from, state) do
    {:reply, Map.get(state.channels_by_uuid, uuid), state}
  end

  def handle_call({:get_channel_by_number, number}, _from, state) do
    {:reply, Map.get(state.channels_by_number, number), state}
  end

  def handle_call(:default_channel, _from, state) do
    hot = Application.get_env(:tvplayer, :streams, [])[:hot_channels] || [1]

    channel =
      Enum.find_value(hot, fn number -> Map.get(state.channels_by_number, number) end) ||
        List.first(state.channels)

    {:reply, channel, state}
  end

  def handle_call({:now_for, channel_uuid}, _from, state) do
    {:reply, Map.get(state.now_by_channel, channel_uuid), state}
  end

  def handle_call(:now_map, _from, state) do
    {:reply, state.now_by_channel, state}
  end

  def handle_call({:events_for, channel_uuid, from, to}, _from, state) do
    key = {channel_uuid, DateTime.to_unix(from), DateTime.to_unix(to)}

    case Map.get(state.events_cache, key) do
      {expires_at, programmes} when is_struct(expires_at, DateTime) ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:reply, {:ok, programmes}, state}
        else
          fetch_and_cache_events(channel_uuid, from, to, key, state)
        end

      _ ->
        fetch_and_cache_events(channel_uuid, from, to, key, state)
    end
  end

  def handle_call({:events_grid, from, to}, _from, state) do
    key = {:grid, DateTime.to_unix(from), DateTime.to_unix(to)}

    case Map.get(state.events_cache, key) do
      {expires_at, by_channel} when is_struct(expires_at, DateTime) ->
        if DateTime.compare(expires_at, DateTime.utc_now()) == :gt do
          {:reply, {:ok, by_channel}, state}
        else
          fetch_and_cache_grid(from, to, key, state)
        end

      _ ->
        fetch_and_cache_grid(from, to, key, state)
    end
  end

  def handle_call({:search, query}, _from, state) do
    case Client.search_events(query) do
      {:ok, programmes} -> {:reply, {:ok, programmes}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:load_fixture, channels, now_map, events_by_channel}, _from, state) do
    channels_by_uuid = Map.new(channels, &{&1.uuid, &1})

    channels_by_number =
      channels
      |> Enum.filter(& &1.number)
      |> Map.new(&{&1.number, &1})

    day = DateTime.now!("Europe/Vienna") |> DateTime.to_date()

    from =
      case DateTime.new(day, ~T[00:00:00], "Europe/Vienna") do
        {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
        {:ambiguous, dt, _} -> DateTime.shift_zone!(dt, "Etc/UTC")
        {:gap, _a, b} -> DateTime.shift_zone!(b, "Etc/UTC")
      end

    to = DateTime.add(from, 24 * 3600, :second)
    grid_key = {:grid, DateTime.to_unix(from), DateTime.to_unix(to)}
    expires_at = DateTime.add(DateTime.utc_now(), 60 * 60, :second)

    events_cache =
      if events_by_channel == %{} do
        # Empty grid cache so guide tests avoid hitting the HTTP client
        Map.put(%{}, grid_key, {expires_at, %{}})
      else
        Map.put(%{}, grid_key, {expires_at, events_by_channel})
      end

    new_state = %{
      state
      | channels: channels,
        channels_by_uuid: channels_by_uuid,
        channels_by_number: channels_by_number,
        now_by_channel: now_map,
        events_cache: events_cache,
        last_error: nil
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    send(self(), :refresh)
    {:noreply, state}
  end

  @impl true
  def handle_info(:refresh, state) do
    state = refresh_all(state)
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, state}
  end

  defp fetch_and_cache_events(channel_uuid, from, to, key, state) do
    case Client.list_events(channel: channel_uuid, from: from, to: to, limit: 1_000) do
      {:ok, programmes} ->
        expires_at = DateTime.add(DateTime.utc_now(), 5 * 60, :second)
        events_cache = Map.put(state.events_cache, key, {expires_at, programmes})
        {:reply, {:ok, programmes}, %{state | events_cache: events_cache}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp fetch_and_cache_grid(from, to, key, state) do
    case Client.list_events(from: from, to: to, limit: 10_000) do
      {:ok, programmes} ->
        by_channel = Enum.group_by(programmes, & &1.channel_uuid)
        expires_at = DateTime.add(DateTime.utc_now(), 5 * 60, :second)
        events_cache = Map.put(state.events_cache, key, {expires_at, by_channel})
        {:reply, {:ok, by_channel}, %{state | events_cache: events_cache}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp refresh_all(state) do
    with {:ok, channels} <- Client.list_channels(),
         {:ok, now_programmes} <- Client.list_now() do
      channels_by_uuid = Map.new(channels, &{&1.uuid, &1})

      channels_by_number =
        channels
        |> Enum.filter(& &1.number)
        |> Map.new(&{&1.number, &1})

      now_by_channel =
        now_programmes
        |> Enum.group_by(& &1.channel_uuid)
        |> Map.new(fn {uuid, programmes} ->
          now = Enum.find(programmes, &Programme.now?/1) || List.first(programmes)
          next = Enum.find(programmes, fn p -> p != now end)
          {uuid, %{now: now, next: next}}
        end)

      new_state = %{
        state
        | channels: channels,
          channels_by_uuid: channels_by_uuid,
          channels_by_number: channels_by_number,
          now_by_channel: now_by_channel,
          last_error: nil
      }

      Phoenix.PubSub.broadcast(Tvplayer.PubSub, @channels_topic, {:channels_updated, channels})
      Phoenix.PubSub.broadcast(Tvplayer.PubSub, @epg_topic, {:epg_updated, now_by_channel})

      new_state
    else
      {:error, reason} ->
        %{state | last_error: reason}
    end
  end
end
