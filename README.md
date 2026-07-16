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

- Docker + Dev Containers (recommended), or Elixir 1.17+, Erlang/OTP 27+, PostgreSQL 16, FFmpeg
- Network access to a TVHeadend server

## Deploy on Unraid (no docker-compose)

Uses plain `docker` commands via `scripts/unraid.sh` — works with Unraid’s Docker tab / terminal.

1. Put this project on the server, e.g. `/mnt/user/appdata/tvplayer`.
2. In a terminal on Unraid:

```bash
cd /mnt/user/appdata/tvplayer
cp .env.example .env
```

3. Edit `.env`: set `SECRET_KEY_BASE` (`openssl rand -base64 48`), `PHX_HOST` to your Unraid IP, and `TVHEADEND_*`.
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

That creates two containers on a shared network `tvplayer-net`:

| Container | Image | Role |
| --- | --- | --- |
| `tvplayer-db` | `postgres:16-alpine` | Database |
| `tvplayer` | `tvplayer:latest` (built locally) | App + FFmpeg |

Volumes: `tvplayer-postgres` (DB), `tvplayer-hls` (HLS under `/data/hls`).

### Unraid Docker UI (optional)

After `./scripts/unraid.sh build`, you can manage the containers from **Docker** in the Unraid UI. Or add them manually with the same env vars as in `.env.example` — important ones:

- Network: custom bridge `tvplayer-net` (create once)
- App port: `4000` → `4000`
- App volume: host path or named volume → `/data/hls`
- `DATABASE_URL=ecto://postgres:postgres@tvplayer-db/tvplayer` (host = DB container name)
- `SECRET_KEY_BASE`, `PHX_HOST`, `TVHEADEND_URL`, `TVHEADEND_USER`, `TVHEADEND_PASSWORD`

`docker-compose.yml` is optional and only needed if you install a Compose plugin later.

## Quick start (Dev Container)

1. Open this folder in VS Code / Cursor and **Reopen in Container**.
2. The post-create script runs `mix phx.new` (if needed), fetches deps, and prepares Postgres.
3. Copy environment defaults:

```bash
cp .env.example .env
```

4. Prefer a least-privileged TVHeadend user with **Web interface** + **Streaming** rights (do not use admin in production).
5. Start the app:

```bash
mix ecto.create
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
| `STREAM_STARTUP_TIMEOUT_MS` | `45000` | Max wait for first HLS segments before error |
| `STREAM_IDLE_MS` | `30000` | Idle stop delay after last viewer leaves |
| `STREAM_COPY` | `auto` | `auto` remuxes web-compatible H.264; `off` always transcodes |
| `FFMPEG_PRESET` | `veryfast` | x264 preset (transcode path only) |
| `FFMPEG_CRF` / `FFMPEG_MAXRATE` | `20` / `6M` | Quality + HD bitrate ceiling |
| `HLS_TIME` | `2` | HLS segment duration in seconds |
| `HLS_ROOT` | `tmp/hls` (Docker: `/data/hls`) | Playlist/segment working directory |
| `SECRET_KEY_BASE` | — | Required in production / Docker |
| `PHX_HOST` | `localhost` | Hostname or IP used to reach the app |

## Architecture notes

- TVHeadend remains the source of truth; no app tables are required in v1 (Postgres/Ecto UUID scaffolding is present for later).
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

- **Endless “Starting channel…”** — check TVHeadend reachability, credentials, and that a tuner is free. Startup times out with a clear error after `STREAM_STARTUP_TIMEOUT_MS`.
- **High CPU** — reduce `HOT_CHANNELS`, lower `STREAM_MAX_CONCURRENT`, or use a faster machine; H.264 sources remux at near-zero CPU (`STREAM_COPY=auto`), while `veryfast` still costs ~1 core per active MPEG-2/HEVC channel.
- **No icons** — icons are proxied via `/icons/...` from TVHeadend `imagecache` paths.
- **LAN access** — bind is `0.0.0.0:4000` in dev; ensure the client can reach both Phoenix and that TVHeadend allows the app host.
# ducktv
