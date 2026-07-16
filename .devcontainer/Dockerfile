FROM hexpm/elixir:1.18.4-erlang-27.3.4-ubuntu-noble-20250529

ENV DEBIAN_FRONTEND=noninteractive \
    MIX_HOME=/usr/local/mix \
    HEX_HOME=/usr/local/hex \
    LANG=C.UTF-8

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    ffmpeg \
    git \
    inotify-tools \
    postgresql-client \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Node.js for Phoenix assets (esbuild/tailwind)
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
    && mix local.rebar --force

WORKDIR /workspace
