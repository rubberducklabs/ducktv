#!/usr/bin/env bash
set -euo pipefail

cd /workspace

echo "==> Ensuring Hex / Rebar are available"
mix local.hex --force
mix local.rebar --force

if [ ! -f mix.exs ]; then
  echo "==> Generating Phoenix project with mix phx.new"
  mix archive.install hex phx_new --force
  mix phx.new . \
    --app tvplayer \
    --module Tvplayer \
    --database postgres \
    --binary-id \
    --no-install
fi

echo "==> Fetching dependencies"
mix deps.get

if [ -f assets/package.json ]; then
  echo "==> Installing Node assets (if any)"
  (cd assets && npm install) || true
fi

echo "==> Creating HLS output directory"
mkdir -p tmp/hls

echo "==> Devcontainer setup complete"
