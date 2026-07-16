# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :tvplayer,
  # No database in v1 — TVHeadend is the source of truth. Re-add ecto_repos when needed.
  ecto_repos: [],
  generators: [timestamp_type: :utc_datetime, binary_id: true],
  tvheadend: [
    url: "http://10.0.1.10:9981",
    username: "admin",
    password: "admin",
    auth: :basic,
    timeout_ms: 10_000
  ],
  streams: [
    hls_root: "tmp/hls",
    ffmpeg_path: "ffmpeg",
    preset: "veryfast",
    crf: 20,
    maxrate: "6M",
    bufsize: "12M",
    audio_bitrate: "192k",
    hls_time: 2,
    hls_list_size: 30,
    keyframe_interval: 2,
    copy: :auto,
    # Keep unused encoders warm so switching back within ~15 minutes is instant.
    # Idle sessions are still reclaimed immediately when a new channel needs a slot.
    idle_ms: 900_000,
    startup_timeout_ms: 45_000,
    max_concurrent: 6,
    hot_channels: [1],
    runner: Tvplayer.Streams.FFmpeg
  ]

# Configure the endpoint
config :tvplayer, TvplayerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TvplayerWeb.ErrorHTML, json: TvplayerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tvplayer.PubSub,
  live_view: [signing_salt: "aVEL14Fe"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :tvplayer, Tvplayer.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tvplayer: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  tvplayer: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
