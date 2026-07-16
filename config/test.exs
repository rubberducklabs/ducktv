import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tvplayer, TvplayerWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "35gsg0fb0ShG6+C3UGMLN8Uea+vfk+K1dS0zR50Qk7rPRrp3qJ30IMy9Xotyl8kv",
  server: false

# In test we don't send emails
config :tvplayer, Tvplayer.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :tvplayer,
  tvheadend: [
    url: "http://tvheadend.test",
    username: "test",
    password: "test",
    auth: :basic,
    timeout_ms: 1_000
  ],
  streams: [
    hls_root: "tmp/hls_test",
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
    idle_ms: 200,
    startup_timeout_ms: 1_000,
    copy_startup_timeout_ms: 1_000,
    max_concurrent: 4,
    hot_channels: [],
    runner: Tvplayer.Streams.FakeRunner
  ]
