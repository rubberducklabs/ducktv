defmodule Tvplayer.Streams.Manager do
  @moduledoc """
  Starts and reuses per-channel stream sessions.

  Unused sessions stay warm for `idle_ms` (default 15 minutes). When the
  concurrency limit is reached, the longest-idle unused session is reclaimed
  so a new channel can start immediately.
  """

  use GenServer

  require Logger

  alias Tvplayer.Streams.Session
  alias Tvplayer.Tvheadend.Cache

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def watch(channel_uuid, viewer_pid \\ self()) when is_binary(channel_uuid) do
    GenServer.call(__MODULE__, {:watch, channel_uuid, viewer_pid})
  end

  def unwatch(channel_uuid, viewer_pid \\ self()) when is_binary(channel_uuid) do
    GenServer.cast(__MODULE__, {:unwatch, channel_uuid, viewer_pid})
  end

  def ensure_hot_channels do
    GenServer.cast(__MODULE__, :ensure_hot_channels)
  end

  def list_sessions do
    Registry.select(Tvplayer.Streams.Registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  @doc """
  Returns a map of `channel_uuid => status` for all live encoder sessions.
  Status is one of `:starting`, `:ready`, or `:error`.
  """
  def session_statuses do
    Enum.reduce(list_sessions(), %{}, fn {uuid, pid}, acc ->
      if Process.alive?(pid) do
        try do
          %{status: status} = Session.status(uuid)
          Map.put(acc, uuid, status)
        catch
          :exit, _ -> acc
        end
      else
        acc
      end
    end)
  end

  @impl true
  def init(_opts) do
    send(self(), :boot_hot_channels)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:watch, channel_uuid, viewer_pid}, _from, state) do
    with {:ok, _pid} <- ensure_session(channel_uuid, hot?: false),
         {:ok, info} <- Session.watch(channel_uuid, viewer_pid) do
      {:reply, {:ok, info}, state}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:unwatch, channel_uuid, viewer_pid}, state) do
    if session_alive?(channel_uuid) do
      Session.unwatch(channel_uuid, viewer_pid)
    end

    {:noreply, state}
  end

  def handle_cast(:ensure_hot_channels, state) do
    start_hot_channels()
    {:noreply, state}
  end

  @impl true
  def handle_info(:boot_hot_channels, state) do
    # Channels may not be loaded yet; retry briefly.
    case Cache.list_channels() do
      [] -> Process.send_after(self(), :boot_hot_channels, 1_000)
      _ -> start_hot_channels()
    end

    {:noreply, state}
  end

  defp start_hot_channels do
    hot_numbers = Application.get_env(:tvplayer, :streams, [])[:hot_channels] || []

    Enum.each(hot_numbers, fn number ->
      case Cache.get_channel_by_number(number) do
        nil ->
          Logger.warning("hot channel number #{number} not found")

        channel ->
          case ensure_session(channel.uuid, hot?: true, channel_number: channel.number) do
            {:ok, _} ->
              Logger.info("hot channel ready: #{channel.name} (#{number})")

            {:error, reason} ->
              Logger.error("failed to start hot channel #{number}: #{inspect(reason)}")
          end
      end
    end)
  end

  defp ensure_session(channel_uuid, opts) do
    if session_alive?(channel_uuid) do
      {:ok, GenServer.whereis(Session.via(channel_uuid))}
    else
      start_session(channel_uuid, opts)
    end
  end

  defp start_session(channel_uuid, opts, retried? \\ false) do
    config = Application.get_env(:tvplayer, :streams, [])
    max = Keyword.get(config, :max_concurrent, 6)
    current = length(list_sessions())

    hot? = Keyword.get(opts, :hot?, false)

    cond do
      current >= max and not hot? ->
        if retried? do
          {:error, :too_many_streams}
        else
          case reclaim_idle_session() do
            :ok -> start_session(channel_uuid, opts, true)
            :error -> {:error, :too_many_streams}
          end
        end

      true ->
        channel_number =
          Keyword.get(opts, :channel_number) ||
            case Cache.get_channel(channel_uuid) do
              %{number: number} -> number
              _ -> nil
            end

        child_spec = %{
          id: channel_uuid,
          start:
            {Session, :start_link,
             [
               [
                 channel_uuid: channel_uuid,
                 channel_number: channel_number,
                 hot?: hot?
               ]
             ]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(Tvplayer.Streams.Supervisor, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # Prefer the longest-idle unused encoder so warm channels the user may switch
  # back to stay alive as long as capacity allows.
  defp reclaim_idle_session do
    candidates =
      list_sessions()
      |> Enum.flat_map(fn {uuid, pid} ->
        if Process.alive?(pid) do
          try do
            info = Session.status(uuid)

            if not info.hot? and info.viewers == 0 do
              [{uuid, info.idle_since || 0}]
            else
              []
            end
          catch
            :exit, _ -> []
          end
        else
          []
        end
      end)
      |> Enum.sort_by(fn {_uuid, idle_since} -> idle_since end)

    case candidates do
      [{uuid, _} | _] ->
        Logger.info("reclaiming idle stream session #{uuid} for a new channel")
        Session.stop(uuid)
        :ok

      [] ->
        :error
    end
  end

  defp session_alive?(channel_uuid) do
    case Registry.lookup(Tvplayer.Streams.Registry, channel_uuid) do
      [{pid, _}] -> Process.alive?(pid)
      [] -> false
    end
  end
end
