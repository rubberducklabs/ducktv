#!/usr/bin/env bash
# Run TV Player on Unraid with plain `docker` (no docker-compose).
#
# Usage (from the project root, e.g. /mnt/user/appdata/tvplayer):
#   cp .env.example .env   # then edit SECRET_KEY_BASE, PHX_HOST, TVHEADEND_*
#   ./scripts/unraid.sh build
#   ./scripts/unraid.sh start
#   ./scripts/unraid.sh logs
#   ./scripts/unraid.sh stop

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NETWORK="${TVPLAYER_NETWORK:-tvplayer-net}"
DB_NAME="${TVPLAYER_DB_CONTAINER:-tvplayer-db}"
APP_NAME="${TVPLAYER_APP_CONTAINER:-tvplayer}"
IMAGE="${TVPLAYER_IMAGE:-tvplayer:latest}"
POSTGRES_IMAGE="${TVPLAYER_POSTGRES_IMAGE:-postgres:16-alpine}"

DB_VOLUME="${TVPLAYER_DB_VOLUME:-tvplayer-postgres}"
HLS_VOLUME="${TVPLAYER_HLS_VOLUME:-tvplayer-hls}"

load_env() {
  if [[ -f .env ]]; then
    set -a
    # shellcheck disable=SC1091
    source .env
    set +a
  fi

  PORT="${PORT:-4000}"
  PHX_HOST="${PHX_HOST:-localhost}"
  PHX_SCHEME="${PHX_SCHEME:-http}"
  POSTGRES_USER="${POSTGRES_USER:-postgres}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-postgres}"
  POSTGRES_DB="${POSTGRES_DB:-tvplayer}"
  DATABASE_URL="${DATABASE_URL:-ecto://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${DB_NAME}/${POSTGRES_DB}}"
  POOL_SIZE="${POOL_SIZE:-10}"

  TVHEADEND_URL="${TVHEADEND_URL:-http://10.0.1.10:9981}"
  TVHEADEND_USER="${TVHEADEND_USER:-admin}"
  TVHEADEND_PASSWORD="${TVHEADEND_PASSWORD:-admin}"
  TVHEADEND_AUTH="${TVHEADEND_AUTH:-basic}"
  TVHEADEND_TIMEOUT_MS="${TVHEADEND_TIMEOUT_MS:-10000}"

  FFMPEG_PATH="${FFMPEG_PATH:-ffmpeg}"
  FFMPEG_PRESET="${FFMPEG_PRESET:-veryfast}"
  FFMPEG_CRF="${FFMPEG_CRF:-20}"
  FFMPEG_MAXRATE="${FFMPEG_MAXRATE:-6M}"
  FFMPEG_BUFSIZE="${FFMPEG_BUFSIZE:-12M}"
  FFMPEG_AUDIO_BITRATE="${FFMPEG_AUDIO_BITRATE:-192k}"
  HLS_TIME="${HLS_TIME:-2}"
  HLS_LIST_SIZE="${HLS_LIST_SIZE:-30}"
  STREAM_COPY="${STREAM_COPY:-auto}"
  STREAM_IDLE_MS="${STREAM_IDLE_MS:-30000}"
  STREAM_STARTUP_TIMEOUT_MS="${STREAM_STARTUP_TIMEOUT_MS:-45000}"
  STREAM_MAX_CONCURRENT="${STREAM_MAX_CONCURRENT:-8}"
  HOT_CHANNELS="${HOT_CHANNELS:-1}"

  if [[ -z "${SECRET_KEY_BASE:-}" || "$SECRET_KEY_BASE" == "replace-me-with-output-of-mix-phx-gen-secret" ]]; then
    echo "ERROR: Set SECRET_KEY_BASE in .env (openssl rand -base64 48)" >&2
    exit 1
  fi
}

ensure_network() {
  if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create "$NETWORK"
  fi
}

cmd_build() {
  docker build -t "$IMAGE" .
}

cmd_start() {
  load_env
  ensure_network

  if ! docker inspect "$DB_NAME" >/dev/null 2>&1; then
    docker run -d \
      --name "$DB_NAME" \
      --network "$NETWORK" \
      --restart unless-stopped \
      -e POSTGRES_USER="$POSTGRES_USER" \
      -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
      -e POSTGRES_DB="$POSTGRES_DB" \
      -v "${DB_VOLUME}:/var/lib/postgresql/data" \
      "$POSTGRES_IMAGE"
  else
    docker start "$DB_NAME" >/dev/null
  fi

  echo "Waiting for Postgres..."
  for _ in $(seq 1 60); do
    if docker exec "$DB_NAME" pg_isready -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if docker inspect "$APP_NAME" >/dev/null 2>&1; then
    docker rm -f "$APP_NAME" >/dev/null
  fi

  docker run -d \
    --name "$APP_NAME" \
    --network "$NETWORK" \
    --restart unless-stopped \
    -p "${PORT}:4000" \
    -v "${HLS_VOLUME}:/data/hls" \
    -e PHX_SERVER=true \
    -e PORT=4000 \
    -e PHX_HOST="$PHX_HOST" \
    -e PHX_SCHEME="$PHX_SCHEME" \
    -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
    -e DATABASE_URL="$DATABASE_URL" \
    -e POOL_SIZE="$POOL_SIZE" \
    -e TVHEADEND_URL="$TVHEADEND_URL" \
    -e TVHEADEND_USER="$TVHEADEND_USER" \
    -e TVHEADEND_PASSWORD="$TVHEADEND_PASSWORD" \
    -e TVHEADEND_AUTH="$TVHEADEND_AUTH" \
    -e TVHEADEND_TIMEOUT_MS="$TVHEADEND_TIMEOUT_MS" \
    -e HLS_ROOT=/data/hls \
    -e FFMPEG_PATH="$FFMPEG_PATH" \
    -e FFMPEG_PRESET="$FFMPEG_PRESET" \
    -e FFMPEG_CRF="$FFMPEG_CRF" \
    -e FFMPEG_MAXRATE="$FFMPEG_MAXRATE" \
    -e FFMPEG_BUFSIZE="$FFMPEG_BUFSIZE" \
    -e FFMPEG_AUDIO_BITRATE="$FFMPEG_AUDIO_BITRATE" \
    -e HLS_TIME="$HLS_TIME" \
    -e HLS_LIST_SIZE="$HLS_LIST_SIZE" \
    -e STREAM_COPY="$STREAM_COPY" \
    -e STREAM_IDLE_MS="$STREAM_IDLE_MS" \
    -e STREAM_STARTUP_TIMEOUT_MS="$STREAM_STARTUP_TIMEOUT_MS" \
    -e STREAM_MAX_CONCURRENT="$STREAM_MAX_CONCURRENT" \
    -e HOT_CHANNELS="$HOT_CHANNELS" \
    "$IMAGE"

  echo "Started. Open http://${PHX_HOST}:${PORT}"
}

cmd_stop() {
  docker stop "$APP_NAME" "$DB_NAME" 2>/dev/null || true
}

cmd_rm() {
  docker rm -f "$APP_NAME" "$DB_NAME" 2>/dev/null || true
}

cmd_logs() {
  docker logs -f "$APP_NAME"
}

cmd_status() {
  docker ps -a --filter "name=^/${APP_NAME}$" --filter "name=^/${DB_NAME}$"
}

usage() {
  cat <<EOF
Usage: $0 <build|start|stop|rm|logs|status|restart>

  build    docker build -t tvplayer:latest .
  start    create/start Postgres + app (reads .env)
  stop     stop both containers
  rm       remove both containers (volumes kept)
  logs     follow app logs
  status   show container status
  restart  stop + start
EOF
}

case "${1:-}" in
  build) cmd_build ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  rm) cmd_rm ;;
  logs) cmd_logs ;;
  status) cmd_status ;;
  restart) cmd_stop; cmd_start ;;
  *) usage; exit 1 ;;
esac
