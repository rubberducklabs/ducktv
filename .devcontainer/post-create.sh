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

if command -v psql >/dev/null 2>&1; then
  # dev.exs reads POSTGRES_* (not DATABASE_URL). Export so mix ecto.create works.
  export POSTGRES_HOST="${POSTGRES_HOST:-db}"
  export POSTGRES_USER="${POSTGRES_USER:-postgres}"
  export POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
  export POSTGRES_DB="${POSTGRES_DB:-tvplayer_dev}"

  echo "==> Waiting for PostgreSQL at ${POSTGRES_HOST}"
  ready=0
  for _ in $(seq 1 60); do
    if pg_isready -h "$POSTGRES_HOST" -U "$POSTGRES_USER" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  if [ "$ready" -ne 1 ]; then
    echo "==> ERROR: PostgreSQL not reachable at ${POSTGRES_HOST}:5432 after 60s" >&2
    echo "    Check that the db service is healthy and port 5432 is published." >&2
    exit 1
  fi
  echo "==> Creating databases"
  mix ecto.create || true
fi

echo "==> Devcontainer setup complete"
