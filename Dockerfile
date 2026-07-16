# Production image for Unraid / Docker.
#
# Builder/runner images (Elixir 1.18.4 + OTP 27.3.4):
#   - https://hub.docker.com/r/hexpm/elixir/tags
#   - https://bob.hex.pm/docker
#
# Build:  docker compose build
# Run:    docker compose up -d

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=trixie-20260610-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

RUN mix assets.setup

COPY priv priv
COPY lib lib
RUN mix compile

COPY assets assets
RUN mix assets.deploy

COPY config/runtime.exs config/
COPY rel rel
RUN mix release

FROM ${RUNNER_IMAGE} AS final

RUN apt-get update \
  && apt-get install -y --no-install-recommends \
    ca-certificates \
    ffmpeg \
    libncurses6 \
    libstdc++6 \
    locales \
    openssl \
    procps \
    tini \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    HLS_ROOT=/data/hls

WORKDIR "/app"

RUN mkdir -p /data/hls \
  && chown -R nobody:nogroup /app /data

COPY --from=builder --chown=nobody:nogroup /app/_build/${MIX_ENV}/rel/tvplayer ./

USER nobody

EXPOSE 4000

# tini reaps zombie ffmpeg children after abrupt stops
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/server"]
