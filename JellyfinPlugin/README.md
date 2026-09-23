# Atmos Objects (Jellyfin plugin)

Serves the Atmos objects inside a film's TrueHD track as separate audio stems
plus their position metadata, so Hypnos can place its own spatial sources on
the Vision Pro instead of needing a Dolby renderer. No Dolby code is involved:
decoding is done by [truehdd](https://github.com/truehdd/truehdd), an
open-source TrueHD decoder, with a small patch of ours (below).

Decoding is live: a client can start or seek anywhere in a film and the
plugin decodes from that point on request. It serves the first segment about
a second later, and each segment it decodes is cached for next time.

## Install

1. Build the plugin: `dotnet build Jellyfin.Plugin.AtmosObjects -c Release`.
   This targets .NET 9 and Jellyfin 10.11.
2. Build truehdd: `truehdd/build.sh`. It clones upstream at a pinned commit,
   applies `truehdd/*.patch` and runs `cargo build --release`.
3. Copy `bin/Release/net9.0/Jellyfin.Plugin.AtmosObjects.dll` into
   `<jellyfin data>/plugins/AtmosObjects_0.1.0.0/`, and point the plugin at
   truehdd in
   `<jellyfin data>/plugins/configurations/Jellyfin.Plugin.AtmosObjects.xml`:

   ```xml
   <PluginConfiguration>
     <TruehddPath>/path/to/truehdd/checkout/target/release/truehdd</TruehddPath>
     <CacheDirectory />            <!-- empty: <jellyfin cache>/atmos-objects -->
     <SegmentSeconds>10</SegmentSeconds>
     <EncoderParallelism>4</EncoderParallelism>
   </PluginConfiguration>
   ```
4. Restart Jellyfin.

### The truehdd patch

Upstream truehdd writes object audio only as a CAF file, and it seeks back
at the end to fill in the length, so the audio can't be read while the
decode is still running. `truehdd/audio-stdout.patch` adds
`decode --audio-stdout`, which streams the same samples to stdout as raw
24-bit little-endian PCM. The DAMF header and metadata still go to files;
upstream already flushes the metadata after every update. The patch is small
and self-contained, and could be offered upstream.

## API

Every endpoint needs normal Jellyfin authentication (an API key or a user token).

| Request | Returns |
|---|---|
| `GET /AtmosObjects/{itemId}/Scene?startSeconds=T` | The layout. With nothing cached, it starts a decode at `T` and waits for it. 422 if the track has no objects |
| `GET /AtmosObjects/{itemId}/Segments/{n}/Events` | Position/gain events for segment `n` |
| `GET /AtmosObjects/{itemId}/Segments/{n}/{g}` | FLAC audio for segment `n`, channel group `g` |
| `GET /AtmosObjects/{itemId}` | `{state, progressSeconds, durationSeconds, error}`, where `state` is `none`, `partial`, `preparing`, `ready`, `unsupported` or `failed` |
| `POST /AtmosObjects/{itemId}/Prepare` | Decodes the whole film into the cache in the background |

A segment request waits until that segment has been decoded, up to 45 s. It
starts a decode at that segment unless one is already running just before
it.

The layout (`scene.json`, version 2) contains:

- `sampleRate`, `segmentFrames` and `segmentCount`.
- `frameCount`: estimated from the item's runtime until a decode reaches the
  end; `frameCountExact` says which.
- `groups`: the audio channels in each group's FLAC, in file order.
- `startSeconds`: the container time of frame 0, which is the TrueHD
  track's first access unit.
- `elements`: `{id, channel, kind: bed|object, bedChannel?}`.

Events are `{id, t, ramp, gain, pos?}`:
- `t` and `ramp` are scene frames and `gain` is in dB.
- `pos` is DAMF room space: x from −1 (left) to +1 (right), y from −1 (back)
  to +1 (front), z from 0 (ear level) to 1 (ceiling).
- A position is reached linearly over `ramp` frames.
- Each segment's list opens with a snapshot of every element as it stands at
  the segment's first frame, so a segment can be used on its own.

## How live decoding stays sample-exact

Segments from different decodes must line up to the sample, because a seek
can start a new decode while neighbouring segments came from an older one.

1. jellyfin-ffmpeg seeks and copies the TrueHD track out as Matroska
   (`-c copy -copyts`), so every packet keeps its container timestamp.
2. Packets are held back until there is a continuous run that starts at a
   major sync (a TrueHD restart point). Right after a seek, the Matroska
   demuxer delivers the restart-point packet and then jumps a whole restart
   interval ahead. Any timestamp gap drops the run.
3. Every access unit holds a fixed number of samples (40 at 48 kHz), and
   timestamps are rounded to 1 ms. Intersecting the windows allowed by a
   few hundred consecutive packets leaves exactly one possible start frame.
4. The run is fed to truehdd, which decodes it from its first access unit.
   The decoded PCM is placed on the global segment grid, and any partial
   segment at the start is dropped.

On an Endgame UHD remux:
- A decode cut at 20:34 and one cut at 1:30:00 each matched a continuous
  decode of the whole film to the sample.
- The same segment decoded from two different cut points gave bit-identical
  FLAC and identical events.

## Cache and sessions

```
<cache>/v2/<itemId>/scene.json
<cache>/v2/<itemId>/seg/<n>.events.json
<cache>/v2/<itemId>/seg/<n>-<g>.flac      16-bit FLAC with TPDF dither, ≤8 channels
```

- A segment counts as cached once its last group's FLAC exists. Each file is
  written under a temporary name and then renamed into place.
- A decode keeps running ahead of the viewer. It stops at the end of the
  film, after running into two cached segments, or when nobody has asked for
  the item in 10 minutes.
- Reaching the end records the exact frame count. If every segment is then
  cached, the item is marked `ready`.
- The kept FLAC costs about 1 GB per hour of film.
- A track that decodes cleanly without an Atmos object presentation is marked
  `unsupported` and isn't retried.
