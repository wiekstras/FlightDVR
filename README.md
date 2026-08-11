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
- **Manage** — move clips to the Trash (always recoverable, never hard-deleted)
  from the right-click menu, the Delete key, or Clips → Move Ticked to Trash.
- **Preview natively** — `.ts` files are losslessly remuxed into a cache with the
  `hvc1` tag, which is the one thing AVFoundation needs to play HDZero's HEVC.
  No VLC, no re-encode, instant after the first open.
- **Edit** — per clip:
  - trim in/out points
  - **cut ranges out of the middle** (as many as you like)
  - **speed ramp zones** (0.25×–4×) with cosine-eased ramps at both edges,
    so speed changes flow instead of snapping
  - **music track** from any audio file, with volume, fade in/out, and a
    choice of mixing under the clip audio or replacing it
  - **project files** — save an edit as a portable `.flightedit.json` sidecar
    and reopen it later without copying the source footage
  - **automatic recovery** — every edit is also saved as a local draft as it is
    made, so switching clips or relaunching the app does not lose work
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
- **Deliver** — Social exports can target TikTok, Instagram Reels, YouTube
  Shorts (9:16) or YouTube (16:9). Choose **Fit** to preserve the entire FPV
  frame or **Fill** for an edge-to-edge social crop.
- **Publish queue foundation** — validated multi-platform jobs are journaled to
  disk. Completed destinations survive relaunches, while interrupted uploads
  return as explicit retryable failures instead of disappearing.
- **Stitch** — tick two or more compatible clips and create one continuous,
  shareable sequence in the current list order.

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
