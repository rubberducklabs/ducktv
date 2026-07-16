import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/tvplayer start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :tvplayer, TvplayerWeb.Endpoint, server: true
end

config :tvplayer, TvplayerWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() != :test do
  parse_hot_channels = fn value ->
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(fn part ->
      case Integer.parse(String.trim(part)) do
        {number, _} -> number
        :error -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  auth =
    case System.get_env("TVHEADEND_AUTH", "basic") do
      "digest" -> :digest
      _ -> :basic
    end

  config :tvplayer,
    tvheadend: [
      url: System.get_env("TVHEADEND_URL", "http://10.0.1.10:9981"),
      username: System.get_env("TVHEADEND_USER", "admin"),
      password: System.get_env("TVHEADEND_PASSWORD", "admin"),
      auth: auth,
      timeout_ms: String.to_integer(System.get_env("TVHEADEND_TIMEOUT_MS", "10000"))
    ],
    streams: [
      hls_root: System.get_env("HLS_ROOT", "tmp/hls"),
      ffmpeg_path: System.get_env("FFMPEG_PATH", "ffmpeg"),
      preset: System.get_env("FFMPEG_PRESET", "veryfast"),
      crf: String.to_integer(System.get_env("FFMPEG_CRF", "20")),
      maxrate: System.get_env("FFMPEG_MAXRATE", "6M"),
      bufsize: System.get_env("FFMPEG_BUFSIZE", "12M"),
      audio_bitrate: System.get_env("FFMPEG_AUDIO_BITRATE", "192k"),
      hls_time: String.to_integer(System.get_env("HLS_TIME", "2")),
      hls_list_size: String.to_integer(System.get_env("HLS_LIST_SIZE", "30")),
      keyframe_interval: String.to_integer(System.get_env("FFMPEG_KEYFRAME_INTERVAL", "2")),
      copy:
        case System.get_env("STREAM_COPY", "auto") do
          "off" -> :off
          "false" -> :off
          "0" -> :off
          _ -> :auto
        end,
      idle_ms: String.to_integer(System.get_env("STREAM_IDLE_MS", "900000")),
      startup_timeout_ms: String.to_integer(System.get_env("STREAM_STARTUP_TIMEOUT_MS", "45000")),
      max_concurrent: String.to_integer(System.get_env("STREAM_MAX_CONCURRENT", "6")),
      hot_channels: parse_hot_channels.(System.get_env("HOT_CHANNELS", "1")),
      runner: Tvplayer.Streams.FFmpeg
    ]
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :tvplayer, TvplayerWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Gettext translations
        ~r"priv/gettext/.*\.po$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/tvplayer_web/router\.ex$",
        ~r"lib/tvplayer_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :tvplayer, Tvplayer.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT", "4000"))
  scheme = System.get_env("PHX_SCHEME", "http")

  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN", "false") do
      "true" -> true
      "1" -> true
      _ -> false
    end

  config :tvplayer, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :tvplayer, TvplayerWeb.Endpoint,
    url: [host: host, port: port, scheme: scheme],
    http: [
      # Bind on all IPv4 interfaces (Unraid / Docker LAN access).
      # Use {0, 0, 0, 0, 0, 0, 0, 0} if you need dual-stack IPv6.
      ip: {0, 0, 0, 0}
    ],
    check_origin: check_origin,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :tvplayer, TvplayerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :tvplayer, TvplayerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :tvplayer, Tvplayer.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
