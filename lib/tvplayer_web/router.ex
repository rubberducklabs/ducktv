defmodule TvplayerWeb.Router do
  use TvplayerWeb, :router

  import TvplayerWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TvplayerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_auth
  end

  pipeline :require_auth do
    plug :require_authenticated_user
  end

  pipeline :hls do
    plug :accepts, ["html", "json", "mpegurl", "*/*"]
    plug :require_authenticated_media
  end

  # No `:accepts` here. Players ask for the playlist, the init segment and the
  # media segments with different Accept headers, and a miss is a 406 that
  # looks like a broken player. Guests get 401 rather than the HTML login page.
  pipeline :recording_hls do
    plug :fetch_session
    plug :put_secure_browser_headers
    plug :require_authenticated_media
  end

  pipeline :public_hls do
    plug :fetch_session
    plug :put_secure_browser_headers
  end

  scope "/", TvplayerWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
    post "/logout", SessionController, :delete

    live "/share/:token", SharedRecordingLive
    get "/share/:token/download", SharedRecordingController, :download
  end

  scope "/", TvplayerWeb do
    pipe_through :public_hls

    get "/share/:token/hls/:file", SharedRecordingController, :hls
  end

  scope "/", TvplayerWeb do
    pipe_through [:browser, :require_auth]

    live_session :authenticated,
      on_mount: [{TvplayerWeb.UserAuth, :ensure_authenticated}] do
      live "/", WatchLive
      live "/guide", GuideLive
      live "/recordings", RecordingsLive
    end

    get "/recordings/:uuid/download", RecordingController, :download
    get "/icons/*path", IconController, :show
  end

  scope "/", TvplayerWeb do
    pipe_through :recording_hls

    get "/recordings/:uuid/hls/:file", RecordingController, :hls
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
