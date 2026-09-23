# Atmos Objects (Jellyfin plugin)

Serves the Atmos objects inside a film's TrueHD track as separate audio stems
plus their position metadata, so Hypnos can place its own spatial sources on
the Vision Pro instead of needing a Dolby renderer. No Dolby code is involved:
decoding is done by [truehdd](https://github.com/truehdd/truehdd), an
open-source TrueHD decoder that the server operator installs.

## Install

1. Build: `dotnet build Jellyfin.Plugin.AtmosObjects -c Release`. This targets
   .NET 9 and Jellyfin 10.11.
2. Copy `bin/Release/net9.0/Jellyfin.Plugin.AtmosObjects.dll` into
   `<jellyfin data>/plugins/AtmosObjects_0.1.0.0/`.
3. Build truehdd (`cargo build --release`) and point the plugin at it in
   `<jellyfin data>/plugins/configurations/Jellyfin.Plugin.AtmosObjects.xml`:

   ```xml
   <PluginConfiguration>
     <TruehddPath>/path/to/truehdd</TruehddPath>
     <CacheDirectory />            <!-- empty: <jellyfin cache>/atmos-objects -->
     <SegmentSeconds>10</SegmentSeconds>
     <EncoderParallelism>4</EncoderParallelism>
   </PluginConfiguration>
   ```
4. Restart Jellyfin.

## API

Every endpoint needs normal Jellyfin authentication (an API key or a user token).

| Request | Returns |
|---|---|
| `GET /AtmosObjects/{itemId}` | `{state, progressSeconds, durationSeconds, error}`; `state` is `none`, `preparing`, `ready`, `unsupported` or `failed` |
| `POST /AtmosObjects/{itemId}/Prepare` | Starts extraction (idempotent), returns 202 |
| `GET /AtmosObjects/{itemId}/Scene` | `scene.json`, or 404 until ready |
| `GET /AtmosObjects/{itemId}/Segments/{n}/{g}` | FLAC audio for segment `n`, channel group `g` |

`scene.json` contains:

- `sampleRate`, `frameCount`, `segmentFrames` and `segmentCount`.
- `groups`: the audio channels in each group's FLAC, in file order.
- `startSeconds`: the TrueHD track's start time in the container.
- `elements`: `{id, channel, kind: bed|object, bedChannel?}`.
- `events`: `{id, t, ramp, gain, pos?}`. `t` and `ramp` are sample frames, `gain` is in dB, and `pos` is DAMF room space: x from −1 (left) to +1 (right), y from −1 (back) to +1 (front), z from 0 (ear level) to 1 (ceiling).

## How preparation works

1. jellyfin-ffmpeg copies the TrueHD track out of the container into
   `truehdd decode -`. truehdd writes the object audio (a 24-bit CAF with one
   channel per element) and the DAMF metadata into a work directory.
2. The CAF is cut into `SegmentSeconds` pieces. Each piece is split into
   balanced channel groups of at most 8 channels (FLAC's limit), then encoded
   to 16-bit FLAC with TPDF dither.
3. `scene.json` is written last, so its presence means the scene is complete.
   The work directory is then deleted.

Costs:
- **Disk while preparing:** the uncompressed CAF, about 2.3 MB/s of film
  (25 GB for 3 hours).
- **Disk kept afterwards:** the FLAC segments.
- **Time:** decoding runs 16–40× real time, and on a mechanical disk it is
  limited by how fast the source file can be read.

A track without an Atmos object presentation is marked `unsupported`, and
the plugin does not retry it.
