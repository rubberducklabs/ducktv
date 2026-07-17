# TVHeadend API Reference (Tvplayer)

Curated reference for the [TVHeadend JSON API](https://docs.tvheadend.org/documentation/development/json-api/api-description), focused on what **tvplayer** uses today (live watching) and what it will need for **recordings**.

Official docs index: [llms.txt](https://docs.tvheadend.org/documentation/llms.txt)

## Contents

| Document | Purpose |
|----------|---------|
| [Watching](./watching.md) | Channels, EPG, live streaming, icons — **current usage** |
| [Recordings](./recordings.md) | DVR timers, listing, create/cancel — **planned** |

## Base URL & Authentication

TVHeadend serves the JSON API over HTTP, default port **9981**:

```
http://<host>:9981/api/<endpoint>
```

If TVHeadend was started with `--http_root`, include that path prefix:

```
http://<host>:9981/<httpRoot>/api/<endpoint>
```

### Credentials

Every API call requires a username and password with sufficient privileges. The user must have **Web interface** access (`ACCESS_WEB_INTERFACE`); without it all calls return **403 Forbidden**.

| HTTP status | Meaning |
|-------------|---------|
| 401 | Invalid credentials |
| 403 | Missing privilege (e.g. Web interface, Recorder) |
| 404 | Unknown API endpoint |
| 400 | Bad/missing parameters |

Authentication methods depend on server config. Tvplayer supports **basic** and **digest** auth via `Req` (see `Tvplayer.Tvheadend.Client`).

### Response format

- Successful data endpoints return **JSON** (often compact, no line breaks).
- Action endpoints return `{}` on success.
- Errors return generic **HTML** pages (not JSON).

### Server info

```
GET /api/serverinfo
```

Used by tvplayer integration tests to verify connectivity. Returns `api_version` and server metadata.

## Common Grid Parameters

Most `*/grid` endpoints share these query parameters (default `limit` is **50** — use a large value to fetch all):

| Parameter | Description |
|-----------|-------------|
| `start` | First record index (default `0`) |
| `limit` | Page size |
| `sort` | Field name to sort by (case-sensitive) |
| `dir` | `desc` for reverse sort |
| `filter` | JSON array of filter objects (see below) |

`epg/events/grid` has its own parameter set (documented in [watching.md](./watching.md)) but also supports `filter`, `sort`, `dir`, `start`, `limit`.

### Grid filters

```json
[
  {
    "field": "<fieldname>",
    "type": "string|numeric|boolean",
    "value": "<value>",
    "comparison": "gt|lt|eq"
  }
]
```

- `comparison` applies only to **numeric** fields (`gt` = greater-or-equal, `lt` = less-or-equal).
- Booleans use `"0"` / `"1"`, not `true`/`false`.
- String filters use case-insensitive regex.
- Multiple filters must target **different fields** (you cannot filter `start` between two values with two `start` filters).

Tvplayer uses numeric filters on EPG `start`/`stop` for time-window queries in `Client.list_events/1`.

## Privileges Summary

| Feature | Required privilege |
|---------|-------------------|
| JSON API (general) | Web interface |
| Live streaming | Streaming |
| Channel icons (`imagecache`) | Streaming, Recording, or Web interface |
| DVR read/write | Recorder (Basic minimum; some ops need Admin) |
| Profile admin | Admin |

## Tvplayer Client Mapping

| Tvplayer function | TVHeadend endpoint |
|-------------------|-------------------|
| `Client.server_info/1` | `GET /api/serverinfo` |
| `Client.list_channels/1` | `GET /api/channel/grid` |
| `Client.list_now/1` | `GET /api/epg/events/grid?mode=now` |
| `Client.list_events/1` | `GET /api/epg/events/grid` |
| `Client.search_events/2` | `GET /api/epg/events/grid` (title filter) |
| `Client.stream_url/2` | `GET /stream/channel/<uuid>?profile=pass` |
| `Client.fetch_icon/2` | `GET /imagecache/<id>` or icon path |
| `Client.dvr_configs/1` | `GET /api/dvr/config/grid` |
| `Client.list_recordings/1` | `GET /api/dvr/entry/grid` |
| `Client.record_event/2` | `POST /api/dvr/entry/create_by_event` |
| `Client.create_recording/2` | `POST /api/dvr/entry/create` |
| `Client.update_recording/3` | `POST /api/idnode/save` |
| `Client.cancel_recording/2` | `POST /api/dvr/entry/cancel` |
| `Client.stop_recording/2` | `POST /api/dvr/entry/stop` |
| `Client.remove_recording/2` | `POST /api/dvr/entry/remove` |

Stream sessions (`Tvplayer.Streams.Session`) pull MPEG-TS from `stream_url` with profile **`pass`** (no transcoding on the TVHeadend side).

## Non-API HTTP Endpoints

These live outside `/api/` but are relevant for playback:

| Endpoint | Use |
|----------|-----|
| `/stream/channel/<uuid>` | Live MPEG-TS stream |
| `/stream/channelid/<id>` | Same, by numeric channel id |
| `/dvrfile/<recording-uuid>` | Download/play a finished recording |
| `/play/dvrfile/<uuid>` | Player-friendly wrapper around dvrfile |
| `/play/stream/channelnumber/<n>` | Player-friendly live stream |
| `/imagecache/<id>` | Channel/event images |
| `/ping` | Health check (no auth, TVH ≥ 4.3-2124) |

See [watching.md](./watching.md) for stream URLs and [recordings.md](./recordings.md) for DVR file playback.
