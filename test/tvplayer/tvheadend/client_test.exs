defmodule Tvplayer.Tvheadend.ClientTest do
  use ExUnit.Case, async: true

  alias Tvplayer.Tvheadend.Client

  test "list_channels parses and sorts enabled channels" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.Channels, fn conn ->
      Req.Test.json(conn, %{
        "entries" => [
          %{
            "uuid" => "b",
            "name" => "ZDF",
            "number" => 2,
            "enabled" => true,
            "icon_public_url" => "imagecache/2"
          },
          %{
            "uuid" => "a",
            "name" => "ORF",
            "number" => 1,
            "enabled" => true,
            "icon_public_url" => "imagecache/1"
          },
          %{
            "uuid" => "c",
            "name" => "Off",
            "number" => 9,
            "enabled" => false
          }
        ]
      })
    end)

    assert {:ok, [first, second]} =
             Client.list_channels(
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.Channels}
             )

    assert first.name == "ORF"
    assert second.name == "ZDF"
  end

  test "list_now returns programmes" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.Now, fn conn ->
      Req.Test.json(conn, %{
        "entries" => [
          %{
            "eventId" => 10,
            "channelUuid" => "a",
            "channelName" => "ORF",
            "title" => "News",
            "start" => 1_700_000_000,
            "stop" => 1_700_003_600
          }
        ]
      })
    end)

    assert {:ok, [programme]} =
             Client.list_now(
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.Now}
             )

    assert programme.title == "News"
  end

  test "load_events fetches programmes by event id" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.LoadEvents, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.request_path == "/api/epg/events/load"
      assert conn.query_params["eventId"] == "[11,12]"

      Req.Test.json(conn, %{
        "entries" => [
          %{
            "eventId" => 11,
            "channelUuid" => "a",
            "channelName" => "ORF",
            "title" => "Weather",
            "start" => 1_700_003_600,
            "stop" => 1_700_007_200
          },
          %{
            "eventId" => 12,
            "channelUuid" => "b",
            "title" => "Sport",
            "start" => 1_700_003_600,
            "stop" => 1_700_007_200
          }
        ]
      })
    end)

    assert {:ok, [weather, sport]} =
             Client.load_events([11, 12],
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.LoadEvents}
             )

    assert weather.title == "Weather"
    assert sport.title == "Sport"
  end

  test "load_events skips empty or invalid ids" do
    assert Client.load_events([], url: "http://tvheadend.test") == {:ok, []}
    assert Client.load_events([0, nil], url: "http://tvheadend.test") == {:ok, []}
  end

  test "stream_url embeds credentials and profile" do
    url =
      Client.stream_url("abc123",
        url: "http://10.0.1.10:9981",
        username: "user",
        password: "pass",
        profile: "pass"
      )

    assert url =~ "http://user:pass@10.0.1.10:9981/stream/channel/abc123"
    assert url =~ "profile=pass"
  end

  test "dvrfile_url embeds credentials for recording path" do
    url =
      Client.dvrfile_url("/dvrfile/rec-1",
        url: "http://10.0.1.10:9981",
        username: "user",
        password: "pass"
      )

    assert url == "http://user:pass@10.0.1.10:9981/dvrfile/rec-1"
  end

  test "list_recordings parses dvr entries" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.DvrList, fn conn ->
      Req.Test.json(conn, %{
        "entries" => [
          %{
            "uuid" => "rec-1",
            "disp_title" => "Tatort",
            "channel" => "a",
            "channelname" => "ORF",
            "start" => 1_700_000_000,
            "stop" => 1_700_003_600,
            "sched_status" => "scheduled",
            "status" => "Scheduled for recording",
            "start_extra" => 5,
            "stop_extra" => 5
          }
        ]
      })
    end)

    assert {:ok, [recording]} =
             Client.list_recordings(
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.DvrList}
             )

    assert recording.title == "Tatort"
    assert recording.state == :scheduled
  end

  test "record_event posts create_by_event" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.DvrCreateEvent, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "event_id=10"
      assert body =~ "config_uuid=cfg-1"
      Req.Test.json(conn, %{"uuid" => ["new-rec"]})
    end)

    assert {:ok, "new-rec"} =
             Client.record_event(10,
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               config_uuid: "cfg-1",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.DvrCreateEvent}
             )
  end

  test "create_recording posts conf json" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.DvrCreate, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "conf="
      Req.Test.json(conn, %{"uuid" => "manual-1"})
    end)

    assert {:ok, "manual-1"} =
             Client.create_recording(
               %{
                 channel: "a",
                 channel_name: "ORF",
                 start: DateTime.from_unix!(1_700_000_000),
                 stop: DateTime.from_unix!(1_700_003_600),
                 title: "Manual",
                 start_extra: 5,
                 stop_extra: 10
               },
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.DvrCreate}
             )
  end

  test "cancel_recording posts uuid" do
    Req.Test.stub(Tvplayer.Tvheadend.ClientTest.DvrCancel, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "uuid=rec-1"
      Req.Test.json(conn, %{})
    end)

    assert {:ok, "rec-1"} =
             Client.cancel_recording("rec-1",
               url: "http://tvheadend.test",
               username: "u",
               password: "p",
               plug: {Req.Test, Tvplayer.Tvheadend.ClientTest.DvrCancel}
             )
  end

  test "stream_dvrfile live path proxies the recording through chunked output" do
    body = :crypto.strong_rand_bytes(128_000)
    {stub, port} = start_dvr_stub(200, body, "video/mp2t")
    on_exit(fn -> stop_dvr_stub(stub) end)

    conn = Plug.Test.conn(:get, "/recordings/rec-1/download")

    assert {:ok, conn} =
             Client.stream_dvrfile("/dvrfile/rec-1", conn,
               url: "http://127.0.0.1:#{port}",
               username: "u",
               password: "p",
               filename: "ZIB.ts",
               content_type: "video/mp2t"
             )

    assert conn.status == 200
    assert conn.resp_body == body

    assert Plug.Conn.get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="ZIB.ts")
           ]
  end

  test "stream_dvrfile live path returns http_error without sending a body" do
    {stub, port} = start_dvr_stub(404, "missing", "text/plain")
    on_exit(fn -> stop_dvr_stub(stub) end)

    conn = Plug.Test.conn(:get, "/recordings/rec-1/download")

    assert {:error, {:http_error, 404}} =
             Client.stream_dvrfile("/dvrfile/rec-1", conn,
               url: "http://127.0.0.1:#{port}",
               username: "u",
               password: "p",
               filename: "ZIB.ts"
             )

    assert conn.state == :unset
  end

  defp start_dvr_stub(status, body, content_type) do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    parent = self()

    pid =
      spawn(fn ->
        send(parent, {:stub_ready, self()})
        stub_loop(listen, status, body, content_type)
      end)

    receive do
      {:stub_ready, ^pid} -> :ok
    after
      1_000 -> flunk("dvr stub did not start")
    end

    {%{pid: pid, listen: listen}, port}
  end

  defp stop_dvr_stub(%{pid: pid, listen: listen}) do
    Process.exit(pid, :kill)
    :gen_tcp.close(listen)
  end

  defp stub_loop(listen, status, body, content_type) do
    case :gen_tcp.accept(listen, 5_000) do
      {:ok, socket} ->
        _ = drain_http_request(socket)
        reason = if status == 200, do: "OK", else: "Error"

        response =
          "HTTP/1.1 #{status} #{reason}\r\n" <>
            "content-type: #{content_type}\r\n" <>
            "content-length: #{byte_size(body)}\r\n" <>
            "connection: close\r\n" <>
            "\r\n" <> body

        :gen_tcp.send(socket, response)
        :gen_tcp.close(socket)
        stub_loop(listen, status, body, content_type)

      {:error, :timeout} ->
        stub_loop(listen, status, body, content_type)

      {:error, _} ->
        :ok
    end
  end

  defp drain_http_request(socket), do: drain_http_request(socket, "")

  defp drain_http_request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      :ok
    else
      case :gen_tcp.recv(socket, 0, 2_000) do
        {:ok, data} -> drain_http_request(socket, acc <> data)
        {:error, _} -> :ok
      end
    end
  end
end
