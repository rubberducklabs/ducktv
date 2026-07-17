# TV Player

Easy-to-use browser TV client for [TVHeadend](https://tvheadend.org/), built with Phoenix LiveView.

The app lists channels and EPG data from TVHeadend, starts a shared on-the-fly FFmpeg encoder per watched channel, and serves browser-friendly HLS from Phoenix.

## Features

- Large, high-contrast Watch UI designed for living-room / older-adult use
- Full EPG guide: now/next, day browsing, search, programme details
- Shared per-channel FFmpeg → HLS pipeline (H.264 + AAC)
- Native resolution / frame-rate preservation (e.g. 1080p25 and 720p50)
- Always-on hot channel (default: channel 1) for near-instant startup
- Hover/focus pre-warm to speed up channel changes
- Radio (audio-only) channel support

## Requirements

- Docker + Dev Containers (recommended), or Elixir 1.17+, Erlang/OTP 27+, FFmpeg
- Network access to a TVHeadend server
- No database required in v1

## Deploy on Unraid (no docker-compose)

Single container (app + FFmpeg). Uses plain `docker` via `scripts/unraid.sh`.

1. Put this project on the server, e.g. `/mnt/user/appdata/tvplayer`.
2. In a terminal on Unraid:

```bash
cd /mnt/user/appdata/tvplayer
cp .env.example .env
```

3. Edit `.env`: set `SECRET_KEY_BASE` (`openssl rand -base64 48`), `PHX_HOST` to your Unraid IP (or reverse-proxy hostname), and `TVHEADEND_*`. Behind a reverse proxy, also set `PHX_PORT=80` (or `PHX_SCHEME=https` without `PHX_PORT`).
4. Build and start:

```bash
chmod +x scripts/unraid.sh
./scripts/unraid.sh build
./scripts/unraid.sh start
```

5. Open `http://<unraid-ip>:4000`.

Useful commands:

```bash
./scripts/unraid.sh logs
./scripts/unraid.sh stop
./scripts/unraid.sh restart
./scripts/unraid.sh status
```

Creates one container: `tvplayer` (`tvplayer:latest`) with volume `tvplayer-hls` → `/data/hls`.

### Unraid Docker UI (optional)

After `./scripts/unraid.sh build`, Repository must be `tvplayer:latest` (not a GitHub URL). Set:

- Port: `4000` → `4000` (or use `br0` with its own IP)
- Volume: named/host path → `/data/hls`
- Env: `SECRET_KEY_BASE`, `PHX_HOST`, `TVHEADEND_URL`, `TVHEADEND_USER`, `TVHEADEND_PASSWORD`

Example `docker run` (after build):

```bash
docker run -d \
  --name=ducktv \
  --net=br0 \
  --ip=10.0.1.11 \
  -e TZ=America/Los_Angeles \
  -e SECRET_KEY_BASE='...' \
  -e PHX_HOST=10.0.1.11 \
  -e PHX_SCHEME=http \
  -e TVHEADEND_URL=http://10.0.1.10:9981 \
  -e TVHEADEND_USER=admin \
  -e TVHEADEND_PASSWORD=admin \
  -e HLS_ROOT=/data/hls \
  -v tvplayer-hls:/data/hls \
  tvplayer:latest
```

## Quick start (Dev Container)

1. Open this folder in VS Code / Cursor and **Reopen in Container**.
2. The post-create script fetches deps and prepares the workspace.
3. Copy environment defaults:

```bash
cp .env.example .env
```

4. Prefer a least-privileged TVHeadend user with **Web interface** + **Streaming** rights (do not use admin in production).
5. Start the app:

```bash
mix phx.server
```

6. Open [http://localhost:4000](http://localhost:4000).

## Important environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `TVHEADEND_URL` | `http://10.0.1.10:9981` | TVHeadend base URL |
| `TVHEADEND_USER` / `TVHEADEND_PASSWORD` | — | API + stream credentials |
| `TVHEADEND_AUTH` | `basic` | `basic` or `digest` |
| `HOT_CHANNELS` | `1` | Comma-separated channel numbers kept always encoding |
| `STREAM_MAX_CONCURRENT` | `6` | Max simultaneous encoders |
| `STREAM_STARTUP_TIMEOUT_MS` | `45000` | Max wait for first HLS segments when `STREAM_COPY=off` |
| `STREAM_COPY_STARTUP_TIMEOUT_MS` | `120000` | Max wait when remux is enabled (long broadcast GOPs) |
| `STREAM_IDLE_MS` | `30000` | Idle stop delay after last viewer leaves |
| `STREAM_COPY` | `auto` | `auto` remuxes web-compatible H.264; `off` always transcodes |
| `FFMPEG_PRESET` | `veryfast` | x264 preset (transcode path only) |
| `FFMPEG_CRF` / `FFMPEG_MAXRATE` | `20` / `6M` | Quality + HD bitrate ceiling |
| `HLS_TIME` | `2` | HLS segment duration in seconds |
| `HLS_ROOT` | `tmp/hls` (Docker: `/data/hls`) | Playlist/segment working directory |
| `SECRET_KEY_BASE` | — | Required in production / Docker |
| `PHX_HOST` | `localhost` | Hostname or IP used to reach the app |
| `PHX_SCHEME` | `http` | `http` or `https` (use `https` behind a TLS reverse proxy) |
| `PHX_PORT` | `PORT` (or `443` if `PHX_SCHEME=https`) | Public URL port for share links. Behind a reverse proxy on standard ports set `80` (http) or leave unset with https |

## Architecture notes

- TVHeadend is the source of truth; no database in v1 (Ecto scaffolding kept dormant for later).
- One OTP session per channel reuses a single FFmpeg process across viewers.
- Phoenix serves `/hls/:channel_uuid/*` playlists and segments.
- Media runners implement `Tvplayer.Streams.Runner` so a Membrane pipeline can replace FFmpeg later.

## Tests

```bash
mix test
```

Real TVHeadend integration (optional):

```bash
TVH_INTEGRATION=1 mix test --only integration
```

## Troubleshooting

- **Endless “Starting channel…”** — check TVHeadend reachability, credentials, and that a tuner is free. Startup times out with a clear error after `STREAM_STARTUP_TIMEOUT_MS` (or `STREAM_COPY_STARTUP_TIMEOUT_MS` when remux is on). H.264 remux waits for source keyframes, so the first picture can take 10–30s on typical HD channels.
- **High CPU** — reduce `HOT_CHANNELS`, lower `STREAM_MAX_CONCURRENT`, or use a faster machine; H.264 sources remux at near-zero CPU (`STREAM_COPY=auto`), while `veryfast` still costs ~1 core per active MPEG-2/HEVC channel.
- **No icons** — icons are proxied via `/icons/...` from TVHeadend `imagecache` paths.
- **LAN access** — bind is `0.0.0.0:4000` in dev; ensure the client can reach both Phoenix and that TVHeadend allows the app host.
