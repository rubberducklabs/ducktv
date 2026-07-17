# Recordings — DVR API

APIs for scheduling, listing, and playing recordings. Implemented in tvplayer via
`Tvplayer.Tvheadend.Client`, `Tvplayer.Tvheadend.Dvr`, and the **Aufnahmen** LiveView.

Source: [DVR](https://docs.tvheadend.org/documentation/development/json-api/api-description/dvr.md), [Other Functions](https://docs.tvheadend.org/documentation/development/json-api/other-functions.md)

**Privilege:** Recorder (at minimum the "Basic" checkbox under Video Recorder on the access entry). Some config operations require Admin.

## Concepts

| Object | Description |
|--------|-------------|
| **DVR entry** | A single scheduled, active, or finished recording (timer instance) |
| **Autorec** | Series timer — records matching EPG events automatically |
| **Timerec** | Time-based recurring timer (e.g. every Tue/Thu 19:00–19:30) |
| **DVR config** | Recording profile (storage path, filename pattern, padding, retention) |

## DVR Configuration

### List recording configs

```
GET /api/dvr/config/grid
```

Returns storage path, filename pattern (`pathname`), pre/post padding, retention, default stream profile, etc.

Key fields:

```json
{
  "uuid": "4e3a1e1cacd2d559c129e7b90f6c986e",
  "name": "",
  "storage": "/mnt/tvheadend",
  "pathname": "$t$n.$x",
  "pre-extra-time": 0,
  "post-extra-time": 0,
  "retention-days": 2147483646,
  "profile": "af143f0983fd4e91953fb859c5561984"
}
```

Use `uuid` as `config_uuid` when creating recordings.

## Listing Recordings

All grid endpoints default to **50** results — pass `limit` generously and use `sort`/`dir`.

### All recordings (combined)

```
GET /api/dvr/entry/grid
```

Includes upcoming, finished, failed, and removed. Use `status` / `sched_status` /
`fileremoved` to distinguish.

**Important:** Entries with status `"File missing"` belong to **removed**
(`grid_removed` / Gelöschte Aufnahmen), not failed — even when `sched_status` is
`completedError`. Tvplayer maps these to state `:removed` ("Gelöscht").

### Upcoming / scheduled — **primary for "my recordings" UI**

```
GET /api/dvr/entry/grid_upcoming?sort=start&dir=ASC&limit=500
```

| Parameter | Description |
|-----------|-------------|
| `duplicates` | `0` to hide duplicate timers (default `1`) |

`sched_status`: `scheduled`  
`status`: human-readable e.g. `"Scheduled for recording"`

`start_real` / `stop_real` include padding and warm-up time.

### Finished recordings

```
GET /api/dvr/entry/grid_finished?sort=stop&dir=DESC&limit=500
```

`sched_status`: `completed`  
`status`: e.g. `"Completed OK"`  
`filename`: absolute path on disk  
`url`: `dvrfile/<uuid>` — use for playback  
`filesize`: bytes  
`playposition`, `playcount`, `watched`: playback tracking

### Failed recordings

```
GET /api/dvr/entry/grid_failed
```

Distinguish from finished via `status` (e.g. `"Too many data errors"`). May still have a `filename` and `url`.

### Removed recordings

```
GET /api/dvr/entry/grid_removed
```

Entries removed from disk (if TVH retains log records).

### Example upcoming entry (abbreviated)

```json
{
  "uuid": "bc85208b236701a63568cb62d5506e08",
  "enabled": true,
  "start": 1562099400,
  "stop": 1562103000,
  "start_real": 1562099340,
  "stop_real": 1562103000,
  "channel": "9a20ebf5ec10a3c49c2c021cc2698ecc",
  "channelname": "BBC TWO HD",
  "disp_title": "Inside the Bank of England",
  "disp_subtitle": "",
  "disp_summary": "1/2. Filmed with unprecedented access...",
  "sched_status": "scheduled",
  "status": "Scheduled for recording",
  "dvb_eid": 3842,
  "autorec": "24fcfd056fc32b86f0abd9fc6a57d17d",
  "filename": "",
  "filesize": 0
}
```

### Example finished entry (abbreviated)

```json
{
  "uuid": "07ac8ed6d7d8744a4217c7b7005d5d7a",
  "start": 1581937200,
  "stop": 1581940800,
  "channelname": "YESTERDAY",
  "disp_title": "Abandoned Engineering",
  "filename": "/video/tvheadend/Abandoned Engineering-4.ts",
  "url": "dvrfile/07ac8ed6d7d8744a4217c7b7005d5d7a",
  "filesize": 997310108,
  "sched_status": "completed",
  "status": "Completed OK",
  "watched": 0,
  "playposition": 0
}
```

## Creating Recordings

### From EPG event — **recommended for tvplayer**

```
POST /api/dvr/entry/create_by_event
```

| Parameter | Source |
|-----------|--------|
| `config_uuid` | `uuid` from `dvr/config/grid` (default config has `name: ""`) |
| `event_id` | `eventId` from `epg/events/grid` |

This is the natural fit when the user clicks "Record" on a programme in the guide.

### Manual timer (custom times)

```
POST /api/dvr/entry/create
```

Body parameter `conf` — minimum useful JSON:

```json
{
  "start": 1509397200,
  "stop": 1509400800,
  "channelname": "Channel 5",
  "title": { "eng": "Paddington Station 24/7" },
  "subtitle": { "eng": "Episode description" }
}
```

Returns the new timer's `uuid` on success.

### Series recording from EPG

```
POST /api/dvr/autorec/create_by_series
```

| Parameter | Description |
|-----------|-------------|
| `config_uuid` | DVR config uuid |
| `event_id` | Any `eventId` from the series |

### Series recording by search

```
POST /api/dvr/autorec/create
```

Body: `conf` JSON with search criteria (title, channel, etc.) and optional `config_uuid`.

### Time-based recurring timer

```
POST /api/dvr/timerec/create
```

Body: `conf` with `start`/`stop` times, `weekdays`, `channel`, etc.

## Managing Recordings

| Action | Endpoint | Parameter |
|--------|----------|-----------|
| Cancel / abort timer | `POST /api/dvr/entry/cancel` | `uuid` |
| Stop running recording | `POST /api/dvr/entry/stop` | `uuid` |
| Delete file from disk | `POST /api/dvr/entry/remove` | `uuid` (finished) |
| Re-record toggle | `POST /api/dvr/entry/rerecord/toggle` | `uuid` |
| Mark previously recorded | `POST /api/dvr/entry/prevrec/toggle` | `uuid` |
| Delete series (autorec) | `POST /api/idnode/delete` | `uuid` from `dvr/autorec/grid` |

**Cancel behaviour:** If recording is in progress, the file is kept but marked as failed.

## Playing Recordings

### Direct file stream

```
GET /dvrfile/<recording-uuid>
```

Requires DVR or streaming privilege. The `url` field on finished entries is relative (`dvrfile/<uuid>`).

**Tvplayer:** completed recordings expose **Herunterladen** on the Aufnahmen page, which
proxies this endpoint via `GET /recordings/:uuid/download` (streamed, with
`Content-Disposition: attachment`).

Web-Version MP4s (browser playback / compressed download) are produced by ffmpeg and
stored under `TRANSCODE_ROOT` (default `tmp/transcodes`, same pattern as `HLS_ROOT`).
Files are named `<recording-uuid>.mp4`.

### Player wrapper

```
GET /play/dvrfile/<recording-uuid>
```

Same User-Agent / ticket behaviour as live `/play/stream/...`.

### M3U playlist of recordings

```
GET /playlist/recordings
GET /playlist/m3u/dvrid/<uuid>
```

Playlist includes upcoming, failed, and future timers too. Unplayable entries have `BANDWIDTH=0`.

## EPG Integration

When listing EPG events, check for recording status:

```json
{
  "dvrUuid": "f01433995f76d60f3b32d38fb18f541a",
  "dvrState": "scheduled"
}
```

Use this to show record icons in the guide without a separate DVR query.

## Suggested Tvplayer Implementation

| Feature | Endpoints |
|---------|-----------|
| Record button on programme | `dvr/entry/create_by_event` |
| Upcoming recordings page | `dvr/entry/grid_upcoming` |
| Library / finished | `dvr/entry/grid_finished` |
| Cancel recording | `dvr/entry/cancel` |
| Play recording | `/dvrfile/<uuid>` or `/play/dvrfile/<uuid>` |
| Series link | `dvr/autorec/create_by_series` |
| Storage status (optional) | `GET /comet/poll` → `freediskspace`, `useddiskspace` |

### Example: schedule recording from guide

```bash
# 1. Get default config uuid
curl -u user:pass 'http://host:9981/api/dvr/config/grid?limit=1'

# 2. Schedule by EPG event
curl -u user:pass --data 'config_uuid=<config-uuid>&event_id=5229882' \
  'http://host:9981/api/dvr/entry/create_by_event'
```

### Example: list upcoming

```bash
curl -u user:pass \
  'http://host:9981/api/dvr/entry/grid_upcoming?sort=start&dir=ASC&limit=200'
```

## Status Monitoring

```
GET /status.xml
```

Returns active recordings and subscription count. Useful for showing "recording in progress" or explaining tuner conflicts during live viewing.

```
GET /comet/poll
```

Returns disk space figures for the recorder storage partition.
