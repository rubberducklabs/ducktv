defmodule TvplayerWeb.Router do
  use TvplayerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TvplayerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :hls do
    plug :accepts, ["html", "json", "mpegurl", "*/*"]
  end

  scope "/", TvplayerWeb do
    pipe_through :browser

    live "/", WatchLive
    live "/guide", GuideLive
    live "/recordings", RecordingsLive
    live "/share/:token", SharedRecordingLive
    get "/share/:token/media", SharedRecordingController, :media
    get "/share/:token/download", SharedRecordingController, :download
    get "/recordings/:uuid/download", RecordingController, :download
    get "/recordings/:uuid/media", RecordingController, :media
    get "/icons/*path", IconController, :show
  end

  scope "/", TvplayerWeb do
    pipe_through :hls

    get "/hls/:channel_uuid/:file", HLSController, :show
  end

  if Application.compile_env(:tvplayer, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TvplayerWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
