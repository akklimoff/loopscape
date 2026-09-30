# Spotify clips — design

Date: 2026-09-18. Status: approved split, Part 0 still open. Part 2 plan:
`docs/superpowers/plans/2026-09-18-clip-resolver.md`.

## Goal

While the Spotify desktop client plays a track, Loopscape shows that track's music video as
the wallpaper on every display. When nothing plays, or the track has no video, Loopscape
behaves exactly as it does today.

## Decisions

- **Clip source: YouTube only**, resolved through `yt-dlp`. No hand-curated clips, no Spotify
  Canvas (unofficial endpoint, vertical 720p), no Spotify music videos (DRM).
- **Delivery: stream, do not download.** YouTube exposes each video as HLS, which `AVPlayer`
  plays natively. Video data lives only in AVPlayer's RAM buffer.
- **On disk: only the track → video mapping**, including "this track has no video".
- **`yt-dlp` is an external dependency** the user installs (`brew install yt-dlp`); it is not
  bundled. The standalone binary takes ~16 s to start, the Homebrew one under a second.
- **No video found → normal rotation continues.** The feature never leaves a black or frozen
  screen; every failure path ends at the regular packs.

Downloading or streaming through `yt-dlp` is against YouTube's terms of service. The README
must say so; the feature ships switched off.

## Versioning

This feature opens the **2.x** line; 1.6 is the last release without it.

| Version | Contents |
|---|---|
| 1.x | Fixes to existing behaviour only, if any are needed while 2.0 is in progress |
| 2.0 | Parts 1–4 complete: the first release in which a playing track switches the wallpaper |
| 2.1, 2.2, … | Follow-ups from "Out of scope", one release per item that proves necessary |

Parts 1–3 land on `main` without a release of their own — Parts 2 and 3 change nothing a
user can see, so a DMG for them would be noise. `VERSION` in `build.sh` and `make-dmg.sh`
moves to `2.0` with the first commit that changes the app binary (Part 1 or Part 3,
whichever lands first; Part 2 adds no code to the app), so the version line in the menu
tells a development build from the installed 1.6; the `v2.0` tag and DMG are cut only after
the Part 4 scenario run passes.

## Spike measurements

Taken on this machine (M1 Max, macOS 26.6.2, yt-dlp 2026.08.19, Python 3.13) with one video,
`CCHdMIEGaaM`:

| What | Result |
|---|---|
| Flat search, 5 candidates (`--flat-playlist -J`) | 2.6 s |
| Resolve HLS URL for a known video id | 2.8–4.4 s |
| Prototype resolver end to end: unknown track / mapped track / same session | 5.5 s / 3.5 s / 0.0 s |
| HLS (format 270, 1080p avc1): first frame in `AVPlayer` | 1.05 s |
| HLS: playing again after seek to 120 s | 0.7 s |
| HLS: duration reported by AVFoundation | 247.7 s, correct |
| Direct https DASH URL (format 137): first frame | 14.5 s |
| Direct https DASH URL / downloaded file: duration | 495.4 s, doubled; `ffmpeg -c copy` fixes a file |
| AVPlayer forward buffer while streaming | ~7 s |

The resolver row was re-measured with the real `.build/resolve` harness (Task 5, Rick Astley —
Never Gonna Give You Up), replacing the earlier prototype-script estimate: `yt-dlp 2026.08.19`,
`deno 2.9.7`. Both numbers still clear the Part 2 pass criteria below.

Consequences: HLS is the only variant worth building. H.264 ≤ 1080p is the format — M1 has no
AV1 hardware decoder and AVFoundation does not play VP9. 1080p HLS runs at ~4.7 Mbit/s, about
140 MB per clip and per loop, per display.

Search ranking is the weak spot, not the plumbing: for "Daft Punk Get Lucky official video"
the first hit is a third-party re-upload and the second is "Official Audio" (a static cover).
Ranking needs every candidate's title, channel and duration, so a resolve is two `yt-dlp`
runs — a flat search, then the stream URL of the pick — not one.

Old clips are small. МакSим — «Лучшая ночь» (2007) exists natively at 320×240; YouTube's
"super resolution" upscales of it are AV1/VP9 DASH only, which AVFoundation on M1 cannot
play. Stretched over a desktop that is worse than no clip, hence a minimum height.

`yt-dlp` wants a JavaScript runtime for YouTube and warns that running without one is
deprecated and hides formats. Homebrew's formula depends on `deno`, so the runtime is there
— but only if the child process gets a `PATH` that includes the Homebrew prefix.

**Part 0 result (2026-09-30, Spotify 1.3.0.277): pass.** With Spotify driven by AppleScript
(play, pause, play, next track, set position, pause), every play, pause and track change posted
`com.spotify.client.PlaybackStateChanged` with `Player State`, `Track ID`, `Name`, `Artist`,
`Duration` and `Playback Position`, so Part 1 is built on the notification. Details that
matter for Parts 1 and 4:

- `Duration` is in milliseconds, `Playback Position` in seconds.
- A seek posts nothing: the new position shows up only with the next event. Part 4 either
  accepts a clip drifting after a scrub or polls the position while a clip plays.
- The first `play` after launching Spotify posted two events 3 ms apart: first a stale one for
  the previous session's track at its end position, then the real track at 0. The menu line
  just follows the latest event; in Part 4 the generation counter drops the stale resolve.

### Part 3 measurements

Built code at `5906cc0`, one built-in display, yt-dlp 2026.08.19, deno 2.9.7, macOS 26.6.2
(25G83), Rick Astley — Never Gonna Give You Up (213 s, 1080p avc1 HLS):

| What | Result |
|---|---|
| First frame, `--play-at 30` (still written after the exact seek lands) | 1.56–1.87 s; once 2.64 s |
| First frame, `--play-at 0` (no seek) | 0.79 s |
| Start position, `--play-at 30` / `205` | lands at 30.000 / 205.000 s |
| Loop seam | position runs 211.1 → 0 → 6.0 s at rate 1.0, no stall, no fallback |
| Empty library while streaming | stream keeps playing, no crash |
| Bytes in, one display, 60 s window ~70 s into playback | 0.268 MB/s ≈ 2.1 Mbit/s (idle 0.002 MB/s) |
| RSS while streaming | ~110 MB over a 60 s window; hour run: 152 → 249 MB in the first 5 min, then flat; ~57 MB on a pack |
| CPU | not attributable: AVFoundation decodes out of process; the app itself shows 2–4 % streaming or on a pack |
| Unreachable URL → pack | 0.24 s, `item failed: Could not connect to the server.` |
| Expired URL → pack | 0.76 s, `item failed: You do not have permission…` (CDN 403) |
| Two displays, drift | not measured, one display |

The first-frame figure is when the still is written, which waits for the exact seek; a frame
first shows ~0.8 s after launch. The exact seek costs ~1 s of the 2.0 s budget — Part 4 picks
between a bigger budget and a provisional keyframe still. A wallpaper left paused
(`defaults read com.aklimoff.loopscape paused` = 1) streams one frozen frame by design, so live
checks need Resume first.

## Architecture

Three independent units and one piece of glue. `Loopscape.swift` is a single file with
top-level code today; with several sources `swiftc` allows top-level code only in
`main.swift`, so the entry point moves there and `build.sh` compiles all app sources.

| Unit | Does | Depends on |
|---|---|---|
| `NowPlaying` | Turns Spotify's state into `Track` events (id, name, artist, duration, position, playing/paused/stopped) | Spotify desktop client |
| `ClipResolver` | `Track` → HLS URL or "none"; owns the mapping cache and the URL cache | `yt-dlp` |
| `ScreenWallpaper` (extended) | Plays a remote HLS URL: start at position, loop, report failure | AVFoundation |
| `AppDelegate` (glue) | State machine between rotation and clip mode, menu, saver marker | the three above |

Data flow: `NowPlaying` event → glue cancels any resolve in flight → `ClipResolver.resolve`
→ URL → every `ScreenWallpaper` streams it from the track's position → still grabbed from the
stream → `syncDesktopPicture`. Paused → players pause. Stopped, Spotify quit, toggle off,
resolve "none", or stream failure → back to the pack that was showing.

### NowPlaying

Listens on `DistributedNotificationCenter` for `com.spotify.client.PlaybackStateChanged`
(Loopscape is not sandboxed, so `userInfo` is delivered). No permissions, no polling, no OAuth.
Sees only the desktop client on the same Mac.

Known limitation, accepted for v1: the notification fires on change only, so a Loopscape
launched mid-track learns about it at the next play/pause/skip.

Fallback if Part 0 fails: poll Spotify over AppleScript. Needs
`NSAppleEventsUsageDescription` and a TCC Automation grant; with ad-hoc signing the grant may
not survive a rebuild, which must be checked before committing to that route.

### ClipResolver

- Runs `yt-dlp` via `Process`, looking in `/opt/homebrew/bin`, `/usr/local/bin` and then
  `PATH` — an app started from Finder or at login does not inherit the shell's `PATH`.
- One call searches (`ytsearch5:<artist> <title> official video`) and returns candidates as
  JSON. A pure scoring function picks one or none:
  plus for "official video" / "music video" in the title, for a channel matching the artist
  or VEVO, for duration close to the track's; minus for audio, lyric, live, cover, karaoke,
  reaction, slowed, 8D. Below a threshold the answer is "none". Weights and the threshold
  are not fixed here: they are tuned until the Part 2 fixtures pass.
- Format selector: `bv[vcodec^=avc1][height>=480][height<=1080][protocol^=m3u8]`. A video
  with nothing in that range counts as "none", as does one that is private or removed.
- The child process runs with the Homebrew prefix on its `PATH`, so `yt-dlp` finds `deno`.
- Disk cache `clips.json` beside `packs.json`: `Track ID → video id | none`. Skips the search
  and remembers misses. "none" entries expire after 30 days so a later release is picked up.
  The file is plain JSON and doubles as the manual override: editing a track's `video` pins
  a different clip.
- `resolve` blocks for the length of the `yt-dlp` runs; the glue owns the queue it runs on.
- RAM cache: resolved URL per video id until the `expire` timestamp embedded in the URL.
- Distinct error for "`yt-dlp` not installed", surfaced in the menu as an install hint.

### Streaming in ScreenWallpaper

- `play(stream:at:)` beside `play(_:)`; looping by keeping two items of the same URL queued
  on the `AVQueuePlayer` (`StreamSession`), because `AVPlayerLooper` drops outputs from its
  replicas and its HLS behaviour is undocumented; a stall past 20 s or a failed item reports
  `StreamFailure`.
- Item failure or a stall past a timeout is reported to the glue, which falls back to the
  pack. An expired URL after a long sleep takes the same path, then one re-resolve.
- One player per display, as today — so N displays stream N times. Measured in Part 3;
  sharing one decode across displays is out of scope unless the numbers demand it.
- The still for the menu bar strip is a frame grabbed from the stream with
  `AVPlayerItemVideoOutput` (`AVAssetImageGenerator` does not support HLS), written to
  `~/Library/Caches/<bundle id>/stills/<video id>.jpg`. One file per video id keeps the
  existing invariant: the wallpaper agent caches by URL, so a still's URL is never rewritten.

**Open risk:** a music video changes scenes, the still does not, so the menu bar strip can
visibly disagree with the picture below it. Deferred by the owner to the UX pass before
`v2.0` (see "Owner UX pass"); remedies (average-colour still, periodic repaint) are decided
there.

### Glue

- Modes: `rotation` (today's behaviour) and `clip(track)`. The rotation timer is suspended in
  clip mode and restarted on the way out.
- Every resolve carries a generation counter; a result for a track that is no longer current
  is dropped, so fast skipping never flashes intermediate clips.
- `current.txt` keeps naming the last regular pack — the screen saver cannot stream.
- Menu: a "Spotify clips" checkbox (off by default), a disabled "♪ Artist — Title" line while
  a track is known, and the `yt-dlp` install hint when it is missing.

## Parts and verification

Parts 1–3 are independent and can land in any order; Part 4 needs all three. Until Part 4
nothing can switch the wallpaper to a clip — Part 1 only adds the read-only menu line — so
every part leaves a shippable app.

### Part 0 — gate: track detection

- Run a throwaway listener (a dozen lines: observe the notification on
  `DistributedNotificationCenter`, print `userInfo`), then pause, play and skip in Spotify.
- Pass: each action prints `Player State`, `Track ID`, `Name`, `Artist`, `Duration`,
  `Playback Position`.
- Fail: Part 1 is built on the AppleScript fallback, after checking that the TCC grant
  survives `./build.sh`.

### Part 1 — NowPlaying

- `./build.sh` passes with the multi-file layout; packs, rotation, pause and the screen saver
  behave as before.
- Manual: skip, pause, resume, quit Spotify — the menu line follows within a second and
  disappears on quit.
- Manual: launch Loopscape mid-track — no line until the next event (the accepted limitation,
  confirmed rather than assumed).

### Part 2 — ClipResolver

- `./build.sh --test` builds and runs a small test executable (plain `swiftc`, no Xcode).
  Scoring tests use JSON fixtures captured from real searches for 8–10 tracks, including the
  Get Lucky case and tracks with no video, where the expected answer is "none".
- CLI harness `.build/resolve "<artist>" "<title>" <seconds>` prints the chosen video, URL and
  timings. Pass: ≤ 8 s for an unknown track, ≤ 5 s with a mapping hit, instant within a
  session, "none" written to the mapping and served from it on the next call.
- The harness run under a Finder-like environment (`env -i PATH=/usr/bin:/bin:…`) still finds
  `yt-dlp` and its JavaScript runtime. Without `yt-dlp` it reports the distinct "not
  installed" error and exits cleanly. The same two checks against the real app — launched
  with `open`, and showing the install hint in the menu — belong to Part 4, where the
  resolver is first wired in.

### Part 3 — streaming playback

Driven by debug launch arguments `--play-url <m3u8>` and `--play-at <seconds>`, so Spotify is
not involved.

- First frame ≤ 2 s.
- Loop: a ~30 s video, watch the seam several times.
- Start position: `--play-at <seconds>` lands where asked.
- Pause toggle, display sleep/wake, space switches and fullscreen behave as with a local pack.
- Wi-Fi off for 30 s mid-stream, and an already-expired URL: both end on the regular pack,
  never on black or a frozen frame.
- Two displays: bandwidth in Activity Monitor ≈ 2× one display; note the drift between them.
- CPU in Activity Monitor stays at a few percent.
- Menu bar strip: screenshots at 3–4 points of a video with hard scene changes. Outcome is a
  decision — acceptable, or pick a remedy before Part 4.

### Part 4 — glue and menu

Manual scenario run, each step with its expected result:

1. Track with a video → clip within ~5 s, roughly at the track's position.
2. Five quick skips → only the last track's clip appears.
3. Track without a video → wallpaper does not flicker; `clips.json` gains a "none".
4. Pause → video pauses; resume → it continues.
5. Quit Spotify → the previous pack returns.
6. Untick "Spotify clips" mid-clip → the pack returns at once.
7. Leave a clip on past the rotation interval → rotation does not interrupt it; after the
   track stops, rotation resumes.
8. Lock the Mac during a clip → the screen saver plays a regular pack.
9. Launch the app with `open`, not from a terminal → clips still resolve (`yt-dlp` and `deno`
   are found without the shell's `PATH`).
10. With `yt-dlp` out of reach → the menu shows the install hint, nothing crashes.

README gains the feature section, the `yt-dlp` dependency and the terms-of-service note.
Only after all ten steps and the owner UX pass below: tag `v2.0` and build the DMG.

### Owner UX pass (before `v2.0`)

The owner judges these by eye on the finished feature rather than per part. Everything a log
can prove was checked in Part 3 (see "Part 3 measurements"); what is left needs a person at
the screen. Debug launch for the Part 3 items, from the repo root:

```bash
.build/resolve "Rick Astley" "Never Gonna Give You Up" 213   # URL lasts ~6 h
URL=<the printed stream URL>
defaults write com.aklimoff.loopscape paused -bool false     # a paused wallpaper shows one frozen frame
osascript -e 'quit app "Loopscape"'; while pgrep -x Loopscape >/dev/null; do sleep 0.2; done; sleep 2
open -a "$PWD/.build/check/Loopscape.app" --args --play-url "$URL" --play-at 205
/usr/bin/log show --predicate 'process == "Loopscape"' --last 3m --style compact | grep 'stream:'
```

`log` must be `/usr/bin/log` — in zsh a bare `log` is a builtin and prints nothing.

Deferred from Part 3:

- Loop seam by eye (`--play-at 205`, seam ~8 s in): no black flash, freeze or jump.
- Pause toggle, Space switch and a fullscreen app mid-stream: a paused stream freezes on its
  frame, never goes black or swaps to a pack.
- Display sleep and wake: the stream resumes; after sleeping past the URL's `expire`, the pack
  returns and nothing is black.
- Wi-Fi off for 30 s mid-stream: the pack returns after ~20 s, log shows `stalled for 20 s`.
- Two displays, if one is at hand: bandwidth ≈ 2× one display; drift between the pictures.
- Menu bar strip across hard scene cuts: acceptable, or pick a remedy (see "Open risk").

Observed while running Part 3, to judge and decide:

- Start is a hard cut: the desktop picture shows for 1–2.6 s, then the video replaces it at
  once. Candidate: fade the video in over the still.
- The still is cached per URL (debug path) and per video id (Part 4) from the first run's
  start position, so later starts elsewhere in the video show a different frame until the
  video appears.
- Quitting the app mid-stream leaves the clip's still as the desktop picture.
- First frame measured 2.64 s once, over the 2.0 s budget (1.56–1.87 s on other runs).

## Out of scope (2.1+ candidates)

Disk cache of video data with an LRU cap; a 720p / low-traffic option; reading Spotify's state
at launch; playback on other devices via the Web API; sharing one decode across displays.
Each is revisited only if use shows the need.
