defmodule Tvplayer.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    hls_root =
      Application.get_env(:tvplayer, :streams, [])
      |> Keyword.get(:hls_root, "tmp/hls")

    transcode_root =
      Application.get_env(:tvplayer, :transcodes, [])
      |> Keyword.get(:root, "tmp/transcodes")

    File.mkdir_p!(hls_root)
    File.mkdir_p!(transcode_root)
    Tvplayer.Auth.init!()
    # Reap ffmpeg left behind by previous BEAM crashes / abrupt restarts.
    Tvplayer.Streams.Probe.ensure_table!()
    Tvplayer.Streams.FFmpeg.prepare!(hls_root)

    children = [
      TvplayerWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:tvplayer, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tvplayer.PubSub},
      Tvplayer.Tvheadend.Cache,
      {Registry, keys: :unique, name: Tvplayer.Streams.Registry},
      {DynamicSupervisor, name: Tvplayer.Streams.Supervisor, strategy: :one_for_one},
      Tvplayer.Streams.Manager,
      Tvplayer.Recordings.Transcoder,
      TvplayerWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Tvplayer.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    hls_root =
      Application.get_env(:tvplayer, :streams, [])
      |> Keyword.get(:hls_root, "tmp/hls")

    Tvplayer.Streams.FFmpeg.shutdown_all(hls_root)
    :ok
  end

  @impl true
  def config_change(changed, _new, removed) do
    TvplayerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
