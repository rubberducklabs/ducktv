# Watching — Channels, EPG & Streaming

APIs used by tvplayer for the channel guide and live playback.

Source: [Channel](https://docs.tvheadend.org/documentation/development/json-api/api-description/channel.md), [EPG](https://docs.tvheadend.org/documentation/development/json-api/api-description/epg.md), [Profile](https://docs.tvheadend.org/documentation/development/json-api/api-description/profile.md), [Other Functions](https://docs.tvheadend.org/documentation/development/json-api/other-functions.md)

## Channels

Users only see channels that are **enabled** and permitted by their access entry. Admins can pass `all=1` to list everything.

### List channels (grid) — **used by tvplayer**

```
GET /api/channel/grid?start=0&limit=10000
```

Response:

```json
{
  "entries": [
    {
      "uuid": "ae63d3b40fbfab610f49290abc189472",
      "name": "BBC RB 1",
      "number": 601,
      "enabled": true,
      "tags": ["21d5fe751062c4d99997d6cb48f43c55"],
      "services": ["9b0e2e103a373350f5e99cda6dd3f055"],
      "icon_public_url": "imagecache/42",
      "dvr_pre_time": 0,
      "dvr_pst_time": 0,
      "epgauto": true,
      "epg_running": -1
    }
  ],
  "total": 104
}
```

**Tvplayer fields used:** `uuid`, `name`, `number`, `enabled`, `icon_public_url`, `tags`, `services`.

Tvplayer filters to `enabled == true` and sorts by channel number.

### List channels (compact)

```
GET /api/channel/list?sort=numname
```

Returns `{key: uuid, val: name}` pairs. Disabled channels appear in braces. Optional: `numbers=1`, `sources=1`.

### Channel tags

```
GET /api/channeltag/list
GET /api/channeltag/grid
```

Useful for grouping (e.g. Radio). Tvplayer reads `tags` on channels but does not call these endpoints yet.

## Electronic Program Guide (EPG)

### Query events (grid) — **used by tvplayer**

```
GET /api/epg/events/grid
```

Key parameters:

| Parameter | Description |
|-----------|-------------|
| `mode=now` | Only currently airing events |
| `channel` | Filter by channel name or uuid (exact match) |
| `channelTag` | Filter by tag name or uuid |
| `title` | Case-insensitive title substring |
| `fulltext=1` | Exact title match |
| `start`, `limit` | Pagination (default limit **50**) |
| `sort` | Default `start` |
| `dir` | `desc` for reverse |
| `filter` | JSON filter array (string fields: `channelName`, `title`, `subtitle`, `summary`, `description`, `extraText`; numeric: `start`, `stop`, etc.) |
| `durationMin`, `durationMax` | Event length in seconds |
| `lang` | ISO639 3-letter language code |

Example — what's on now:

```
GET /api/epg/events/grid?mode=now&start=0&limit=10000
```

Example — guide for one channel in a time range (tvplayer approach):

```
GET /api/epg/events/grid?channel=<uuid>&start=0&limit=500&sort=start&dir=ASC
  &filter=[{"type":"numeric","field":"stop","value":<from_unix>,"comparison":"gt"},
           {"type":"numeric","field":"start","value":<to_unix>,"comparison":"lt"}]
```

Example event:

```json
{
  "eventId": 5229882,
  "channelUuid": "fd22bbade9093bd1fedf6ce87d75f9a0",
  "channelName": "ITV HD",
  "channelNumber": "3",
  "start": 1747148400,
  "stop": 1747152000,
  "title": "Tipping Point",
  "subtitle": "",
  "summary": "Ben Shephard hosts...",
  "description": "...",
  "nextEventId": 5229883,
  "image": "imagecache/99",
  "channelIcon": "imagecache/42"
}
```

When a recording is scheduled for an event, extra fields appear:

```json
{
  "dvrUuid": "f01433995f76d60f3b32d38fb18f541a",
  "dvrState": "scheduled"
}
```

`dvrState` values: `scheduled`, `recording`, `completed`, `completedError`, `completedWarning`, `completedRerecord`.

**Tvplayer fields used:** `eventId`, `channelUuid`, `channelName`, `channelNumber`, `start`, `stop`, `title`, `subtitle`, `summary`, `description`, `nextEventId`, `image`/`channelIcon`.

### Load single event(s)

```
GET /api/epg/events/load?eventId=<id>
GET /api/epg/events/load?eventId=[<id1>,<id2>]
```

Returns full detail for specific `eventId` values. Does not support standard `/load` meta parameters.

### Related / alternative broadcasts

```
GET /api/epg/events/related?eventId=<id>
GET /api/epg/events/alternative?eventId=<id>
```

Series-related and duplicate broadcasts (requires EPG CRIDs; limited on some sources).

## Live Streaming

Streaming is **not** under `/api/`. It returns a continuous MPEG-TS (or transcoded) byte stream.

### Stream by channel UUID — **used by tvplayer**

```
GET /stream/channel/<channel-uuid>?profile=pass
```

Alternatives:

```
GET /stream/channelid/<numeric-id>?profile=<name>
GET /stream/channelnumber/<lcn>?profile=<name>
GET /stream/channelname/<name>?profile=<name>
```

Query parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `profile` | server default | Stream profile name or uuid |
| `qsize` | 1500000 | Buffer size in bytes |

Tvplayer builds authenticated URLs like:

```
http://user:pass@host:9981/stream/channel/<uuid>?profile=pass
```

`Tvplayer.Streams.Session` feeds this URL to FFmpeg for HLS remux/transcode.

### Stream profiles

```
GET /api/profile/list
```

Common profiles:

| Name | Purpose |
|------|---------|
| `pass` | Raw passthrough (tvplayer default) |
| `matroska` | MKV container |
| `webtv-h264-aac-mpegts` | Browser-friendly transcode |
| `audio` | Audio only |

List returns `{key: uuid, val: name}` entries.

### Play wrapper

For clients that need playlist indirection:

```
GET /play/stream/channelnumber/<n>
GET /play/ticket/stream/channel/<uuid>
```

Tickets expire after **5 minutes**.

## Images

Channel and EPG images are served from the image cache:

```
GET /imagecache/<image-number>
```

The path also appears on channel/EPG objects as `icon_public_url` or `image`. Tvplayer proxies these via `IconController` using `Client.fetch_icon/2`.

Requires **Streaming**, **Recording**, or **Web interface** privilege.

## XMLTV Export (optional)

Full EPG as XMLTV:

```
GET /xmltv/channels
GET /xmltv/channel/<channel-uuid>
```

Not used by tvplayer today; useful for bulk EPG import or debugging.

## Tuner Conflicts

A channel may fail to stream when a tuner is busy (e.g. active recording). Tvplayer surfaces this in `Streams.Session` startup errors. Check recording status via `GET /api/dvr/entry/grid_upcoming` or `GET /status.xml` when debugging.
