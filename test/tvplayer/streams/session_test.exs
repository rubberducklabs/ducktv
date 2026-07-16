defmodule Tvplayer.Streams.SessionTest do
  use ExUnit.Case, async: false

  alias Tvplayer.Streams.{Manager, Session}
  alias Tvplayer.Tvheadend.{Cache, Channel}

  setup do
    File.rm_rf!("tmp/hls_test")
    File.mkdir_p!("tmp/hls_test")

    channel = %Channel{
      uuid: "channel-one",
      name: "Test 1",
      number: 1,
      enabled: true,
      icon_path: nil,
      tags: [],
      services: []
    }

    Cache.load_fixture([channel], %{})

    on_exit(fn ->
      for {uuid, _pid} <- Manager.list_sessions() do
        case Registry.lookup(Tvplayer.Streams.Registry, uuid) do
          [{pid, _}] ->
            Process.exit(pid, :kill)

          _ ->
            :ok
        end
      end

      File.rm_rf!("tmp/hls_test")
    end)

    %{channel: channel}
  end

  test "watch starts a shared session and becomes ready", %{channel: channel} do
    assert {:ok, info} = Manager.watch(channel.uuid, self())
    assert info.playlist_url == "/hls/channel-one/index.m3u8"

    assert wait_until(fn -> Session.status(channel.uuid).status == :ready end)
    assert Session.status(channel.uuid).viewers == 1
  end

  test "second watcher reuses the same session", %{channel: channel} do
    assert {:ok, _} = Manager.watch(channel.uuid, self())
    assert wait_until(fn -> Session.status(channel.uuid).status == :ready end)

    viewer = spawn(fn -> Process.sleep(5_000) end)

    assert {:ok, _} = Manager.watch(channel.uuid, viewer)
    assert length(Manager.list_sessions()) == 1
    assert Session.status(channel.uuid).viewers == 2
  end

  test "session_statuses and all_topic reflect encoder lifecycle", %{channel: channel} do
    Phoenix.PubSub.subscribe(Tvplayer.PubSub, Session.all_topic())

    assert Manager.session_statuses() == %{}
    assert {:ok, _} = Manager.watch(channel.uuid, self())

    assert_receive {:stream_status, %{channel_uuid: "channel-one", status: :starting}}, 1_000
    assert Map.get(Manager.session_statuses(), channel.uuid) in [:starting, :ready]

    assert wait_until(fn -> Session.status(channel.uuid).status == :ready end)
    assert_receive {:stream_status, %{channel_uuid: "channel-one", status: :ready}}, 1_000
    assert Manager.session_statuses()[channel.uuid] == :ready
  end

  test "reclaims longest-idle unused session when at capacity" do
    previous_idle = Application.get_env(:tvplayer, :streams)[:idle_ms]

    Application.put_env(
      :tvplayer,
      :streams,
      Keyword.put(Application.get_env(:tvplayer, :streams), :idle_ms, 60_000)
    )

    on_exit(fn ->
      Application.put_env(
        :tvplayer,
        :streams,
        Keyword.put(Application.get_env(:tvplayer, :streams), :idle_ms, previous_idle)
      )
    end)

    channels =
      for n <- 1..5 do
        %Channel{
          uuid: "channel-#{n}",
          name: "Test #{n}",
          number: n,
          enabled: true,
          icon_path: nil,
          tags: [],
          services: []
        }
      end

    Cache.load_fixture(channels, %{})

    # Fill concurrency slots (test max_concurrent is 4), then leave them idle.
    for channel <- Enum.take(channels, 4) do
      assert {:ok, _} = Manager.watch(channel.uuid, self())
      assert wait_until(fn -> Session.status(channel.uuid).status == :ready end)
      Manager.unwatch(channel.uuid, self())
    end

    assert wait_until(fn ->
             Enum.all?(Enum.take(channels, 4), fn channel ->
               Session.status(channel.uuid).viewers == 0
             end)
           end)

    # Refresh idle_since on newer channels so channel-1 is the oldest idle.
    Process.sleep(20)

    for uuid <- ["channel-2", "channel-3", "channel-4"] do
      assert {:ok, _} = Manager.watch(uuid, self())
      Manager.unwatch(uuid, self())
    end

    assert wait_until(fn ->
             Enum.all?(["channel-1", "channel-2", "channel-3", "channel-4"], fn uuid ->
               Session.status(uuid).viewers == 0 and is_integer(Session.status(uuid).idle_since)
             end)
           end)

    fifth = Enum.at(channels, 4)
    assert {:ok, _} = Manager.watch(fifth.uuid, self())
    assert wait_until(fn -> Session.status(fifth.uuid).status == :ready end)

    # Oldest idle encoder (channel-1) should have been reclaimed.
    assert Registry.lookup(Tvplayer.Streams.Registry, "channel-1") == []
    assert length(Manager.list_sessions()) == 4
  end

  test "keeps idle session warm until idle timeout", %{channel: channel} do
    assert {:ok, _} = Manager.watch(channel.uuid, self())
    assert wait_until(fn -> Session.status(channel.uuid).status == :ready end)

    Manager.unwatch(channel.uuid, self())
    assert wait_until(fn -> Session.status(channel.uuid).viewers == 0 end)
    assert is_integer(Session.status(channel.uuid).idle_since)

    # Still warm well before the configured idle timeout (200ms in test).
    Process.sleep(50)
    assert Session.status(channel.uuid).status == :ready

    assert wait_until(fn -> Registry.lookup(Tvplayer.Streams.Registry, channel.uuid) == [] end)
  end

  defp wait_until(fun, attempts \\ 40) do
    cond do
      fun.() ->
        true

      attempts <= 0 ->
        false

      true ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)
    end
  end
end
