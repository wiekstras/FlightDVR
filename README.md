# Flight Studio

*A native macOS app for HDZero goggle DVR footage — browse, trim, edit and export.*

Native SwiftUI + AVFoundation, with ffmpeg as the media engine. Inspired by
FlightDVR Studio, rebuilt for the Mac, plus an editing layer the original
doesn't have: cut sections out of the middle of a clip, lay a music track under
it, and add eased speed ramps.

## What it does

- **Browse** — point it at a goggle card (`Find SD Card` searches every volume,
  nested folders included) or any folder. Clips get thumbnails, duration,
  resolution/fps and size. Sort by **date** (grouped into one section per flying
  day — dates parsed out of filenames when present, file dates otherwise), name,
  length or size.
  Finder folders and supported video files can also be dropped directly onto
  the window or opened with DVR Studio. Superseded folder scans are ignored so
  stale removable-drive results cannot overwrite the current library. Probe
  metadata is cached across launches and invalidates automatically when a file
  moves, changes size, or is modified. Favorites, tags and edit drafts update an
  in-memory index immediately while whole-library serialization is batched on a
  utility queue and flushed at macOS lifecycle boundaries. Sorted, filtered and
  day-grouped presentation state is cached and invalidated explicitly, avoiding
  repeated full-library sorting during unrelated SwiftUI updates. Filesystem
  identities preserve favorites, tags, highlights and edit recovery when a
  recording is renamed or moved on the same volume; legacy path-only records
  upgrade automatically when scanned. An atomic Application Support backup
  repairs a malformed primary metadata archive before new work can overwrite
  favorites, tags, highlights, or automatic edit recovery.
- **Manage** — move clips to the Trash (always recoverable, never hard-deleted)
  from the right-click menu, the Delete key, or Clips → Move Ticked to Trash.
- **Preview natively** — `.ts` files are losslessly remuxed into a cache with the
  `hvc1` tag, which is the one thing AVFoundation needs to play HDZero's HEVC.
  No VLC, no re-encode, instant after the first open.
- **Navigate visually** — opening a recording lazily generates a cached timeline
  filmstrip and audio waveform, while unopened library items incur no extra
  decoding work. Named event markers support one-click or ⌥←/⌥→ traversal for
  quickly revisiting moments in long DVR sessions.
- **Review quickly** — frame stepping, J/K/L navigation, selectable 0.25×–2×
  playback, native fullscreen, and fit/fill preview controls stay close at hand.
- **Edit** — per clip:
  - trim in/out points
  - reset the trim independently without clearing cuts, titles, audio or markers
  - frame-aware `HH:MM:SS:FF` source and output timecode, including multi-hour recordings
  - **cut ranges out of the middle** (as many as you like)
  - **speed ramp zones** (0.25×–4×) with cosine-eased ramps at both edges,
    so speed changes flow instead of snapping
  - **music track** from any audio file, with volume, fade in/out, and a
    choice of mixing under the clip audio or replacing it
  - **clip audio mix** with independent volume, mute, fade in and fade out,
    previewed live and rendered identically during export
  - **timed titles** at the top, centre or bottom, previewed live and burned into export
  - social reframing with full-frame padding, edge-to-edge crop, or a blurred background
  - **project files** — save a portable `.flightedit` JSON sidecar and reopen it
    from Finder, drag and drop, or the editor without copying source footage.
    Legacy `.flightedit.json` files remain supported; obvious wrong-source loads
    are rejected while renamed or relocated recordings remain recoverable
  - **automatic recovery** — every edit is also saved as a local draft as it is
    made, so switching clips or relaunching the app does not lose work
  - **saved highlight shelf** — preserve and name several independent edits from
    one long DVR recording without copying or modifying the source file, then
    export them individually or arrange them into one continuous highlight reel
  - **Preview edit** — a toggle in the player plays the clip with cuts, ramps
    and music applied, via an AVComposition over the preview cache: instant,
    no encoding, and it follows every change live
- **Export** — a queue with per-job progress:
  | Preset | Produces | For |
  |---|---|---|
  | Edit | ProRes 422 (LT/422/HQ) `.mov` | DaVinci/Final Cut timelines |
  | Master | H.264 CRF `.mp4` | archiving, full-quality sharing |
  | Social | two-pass H.264 at an exact target size | WhatsApp, Discord |
  | Remux | lossless rewrap to `.mp4` | instant, no re-encode |

  Apple VideoToolbox hardware encoding is offered when a *test encode* proves it
  works — not when ffmpeg merely claims to support it.
  Verified results can be opened, revealed in Finder, or sent through the native
  macOS share sheet directly from the queue; missing outputs lose those actions
  and are shown as an explicit error instead of a stale success.
- **Deliver** — Social exports can target TikTok, Instagram Reels, YouTube
  Shorts (9:16), Instagram posts (1:1 or 4:5), or YouTube (16:9). Choose **Fit**
  to preserve the entire FPV frame or **Fill** for an edge-to-edge social crop,
  then drag the footage directly in the live framing preview (or use precise
  sliders and double-click to recenter it).
- **Publish queue foundation** — validated multi-platform jobs are journaled to
  disk. Completed destinations survive relaunches, while interrupted uploads
  return as explicit retryable failures instead of disappearing. One Publish
  click starts every destination, and one failed platform can retry independently.
  Each retry has a unique attempt identity, preventing a cancelled provider's
  late progress or completion callback from corrupting the newer upload state.
  Export and publishing journals each maintain an atomic sibling backup; a
  malformed primary is decoded from backup and repaired before any queued,
  completed, or partially uploaded destination can disappear.
- **Export & Publish handoff** — the current edit can be queued for social
  delivery in one action. DVR Studio freezes that edit, encodes and verifies it,
  then durably hands it to the publishing queue without blocking further edits;
  an interrupted handoff resumes idempotently after relaunch.
- **Recoverable publishing composer** — titles, captions, hashtags, visibility
  and platform choices are saved while typing, with live delivery preflight for
  canvas, codec, duration, frame rate, dimensions and API file-size limits.
  Choose a JPEG/PNG YouTube thumbnail or generate a 1280×720 frame from the
  completed export without leaving DVR Studio.
  Provider connection status is checked concurrently before delivery; missing
  accounts or unprovisioned integrations block before encoding rather than
  wasting time on a video that cannot be uploaded.
- **Crash-safe exports** — queued export jobs survive relaunches, including
  their frozen edit instructions and media metadata, so later timeline changes
  cannot alter an already queued deliverable. Encoders write to private staging
  files, verify the result with ffprobe, and atomically promote it only after
  completion, protecting new and replaced exports from partial-file corruption.
  Job-scoped title assets and two-pass encoder logs are removed after success,
  failure, cancellation, or crash recovery.
  Preset-aware disk preflight rejects jobs before encoding when the destination
  volume cannot hold the private staging file.
- **Stitch** — tick two or more compatible clips and create one continuous,
  shareable sequence. A native sequence composer supports drag, arrow and remove
  controls with edited-duration and resolution checks before the job is queued.
  Every clip's frozen trims, cuts, speed work, titles and audio mix are rendered
  before concatenation; missing audio is padded with silence rather than dropping
  sound from the entire sequence. Social sequences preserve the selected platform
  canvas, framing and two-pass target size, including ordered highlight reels.

## The colour fix

HDZero recordings are full-range video with bogus PAL-era colour tags. Flight
Studio's default corrects the one thing that is provably wrong — the range —
and leaves the untrustworthy tags alone, which measured best in FlightDVR
Studio's frame-by-frame comparison. `Leave colour alone` is there if you've
graded around the raw footage.

## Requirements

- macOS 14+, Apple Silicon or Intel (builds for the host arch)
- ffmpeg: `brew install ffmpeg`

## Building

```bash
./build.sh
open "build/Flight Studio.app"
```

Only Swift (Command Line Tools are enough — no Xcode needed) and ffmpeg are
required.

## Install without building

Every push to `main` produces a macOS app archive under the repository's
**Actions → Build Flight Studio → Artifacts**. Tagged versions (`v*`) are also
attached to the corresponding GitHub Release. Download `Flight-Studio-macos.zip`,
unzip it, and drag **Flight Studio.app** into Applications.

The automated archive is ad-hoc signed but not notarized yet, so macOS may ask
you to confirm it the first time it is opened. A developer signing certificate
and notarization credentials can be added later as GitHub secrets without
changing the application build.

## Verifying

The app carries its own end-to-end test. It synthesises an HDZero-style clip
(H.265, full range, `bt470bg` tags, MPEG-TS), runs a trim + middle-cut +
speed-ramp + music export through the same code path as the GUI, and checks the
result's duration, codec, colour range and audio with ffprobe:

```bash
.build/debug/FlightStudio --selftest
```

## Layout

| File | Contains |
|---|---|
| `FFmpeg.swift` | ffmpeg/ffprobe discovery, process running, progress parsing, probing |
| `ClipStore.swift` | scanning, SD-card detection, thumbnail + preview caches |
| `EditPlan.swift` | the edit model and the filtergraph builder (cuts, ramps, music) |
| `Exporter.swift` | presets, export command construction, the queue, hardware detect |
| `ContentView.swift` / `PlayerPane.swift` / `TimelinePane.swift` / `ExportPane.swift` | the UI |
| `SelfTest.swift` | the headless end-to-end test |

Decisions worth knowing:

- **ffmpeg runs as a child process**, never linked — keeps the app GPL-clean and
  crash-isolated. Bundle copy wins over Homebrew over PATH.
- **Speed ramps are stepped `setpts` sub-segments** (10 steps through each eased
  ramp), because ffmpeg has no continuous-ramp primitive. At half a second per
  ramp the steps are imperceptible.
- **Thumbnails decode ~24 frames past the seek point** — seeking into MPEG-TS
  lands on an estimated byte offset, and the first frames after a seek are torn.
- **Two-pass social keeps audio in both passes**; stripping it on pass one
  shifts video framing and x264 rejects the stats file.
- **A cancelled or failed export deletes its partial file.** Nothing unplayable
  is left behind looking like a finished export.
