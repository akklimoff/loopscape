# Loopscape

Live video wallpapers for macOS, on every display — and, from 2.0, the music video of
whatever Spotify is playing, in step with the song.

macOS 26 (Tahoe) has no way to use your own video as a desktop wallpaper. The aerials
catalog under `~/Library/Application Support/com.apple.wallpaper/aerials/` is no longer
wired to the wallpaper picker, and the pickers themselves read from
`/System/Library/Desktop Pictures`, which lives on the read-only system volume.

Loopscape is a menu bar app that fills the gap. It places one borderless window per
`NSScreen` at desktop window level — below the desktop icons, above the wallpaper — and
loops a video in each.

## Features

- **Video wallpapers on every display**, one window per screen, re-anchored on wake and
  display changes, paused while the displays sleep.
- **Packs and rotation** — pick a clip from the menu or rotate every 5 / 15 / 30 / 60 minutes.
- **Spotify clips** *(2.0)* — the playing track's music video becomes the wallpaper, streamed
  from YouTube and kept in sync with the song by ear. See below.
- **Fabric transitions** *(2.0)* — every switch, pack to clip or pack to pack, passes behind
  a white fabric curtain: Silk, Loom, Fabric in the wind, Satin, or no animation.
- **A seamless menu bar** — the system wallpaper is set to each clip's still, so the
  translucent menu bar blends in.
- **Lock screen** through the bundled screen saver, playing the same pack.
- **Launch at login**, Russian and English UI.

## Install

Download the DMG from the [latest release](https://github.com/akklimoff/loopscape/releases/latest),
open it, and drag Loopscape onto the Applications folder.

### Gatekeeper

The app is ad-hoc signed and **not notarized** — there is no paid Apple Developer
certificate behind it, so macOS blocks the first launch with "Apple could not verify that
this app is free of malware". To allow it:

1. Open Loopscape once and let the warning appear
2. System Settings -> Privacy & Security -> scroll down -> **Open Anyway**

Or strip the quarantine flag yourself:

```sh
xattr -dr com.apple.quarantine /Applications/Loopscape.app
```

### From source

Building locally avoids the quarantine flag entirely:

```sh
git clone https://github.com/akklimoff/loopscape.git
cd loopscape
./build.sh
```

Requires Apple Silicon, macOS 13 or newer, and the Xcode command line tools
(`xcode-select --install`). `make-dmg.sh` produces the disk image in `.build/`.

Loopscape ships with no videos. The first launch creates the wallpapers folder and the menu
says it is empty until you put something in it — see below.

## Adding wallpapers

Put your clips in `~/Library/Application Support/Loopscape/Wallpapers/` as `<slug>.<ext>` in
any container AVFoundation can play (`.mp4`, `.mov`, `.m4v`, `.ts`, ...; WebM is not one
of them), then list them in `packs.json` one directory up (optional — a clip without an
entry shows up under its slug):

```json
[
  { "slug": "winter-ruins", "ru": "Зимние руины", "en": "Winter Ruins" }
]
```

HEVC is strongly preferred over VP9 or H.264 — Apple Silicon decodes it in hardware, so a
4K loop costs a few percent of one core instead of pinning it. To convert:

```sh
ffmpeg -i input.webm -an \
  -c:v hevc_videotoolbox -profile:v main10 -tag:v hvc1 -pix_fmt p010le \
  -b:v 30M -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
  "$HOME/Library/Application Support/Loopscape/Wallpapers/winter-ruins.mp4"

ffmpeg -i input.webm -frames:v 1 -q:v 2 \
  "$HOME/Library/Application Support/Loopscape/Wallpapers/winter-ruins.jpg"
```

The still is not decoration. The menu bar blurs the *desktop picture* rather than the
window stack, so a video alone leaves the old wallpaper showing through the top strip.
Loopscape paints the system wallpaper with the clip's still on every switch, and the seam
disappears.

## Menu

The status item is the entire interface: pick a pack, set the rotation interval (5 / 15 /
30 / 60 minutes, or off), jump to the next one, pause, see the Spotify track, toggle
**Spotify clips**, choose the **Transition**, open the wallpapers folder, toggle **Launch at
login**, quit. With an interval set, choosing a pack shows it now and restarts the countdown; with the
interval off, whatever is showing is kept across restarts.

Launch at login is on by default and is backed by `SMAppService`, so it shows up in System
Settings under Login Items. Unchecking it there and in the menu are the same switch.

The UI is Russian when the system's primary language is Russian, English otherwise.

## Spotify clips

With **Spotify clips** ticked in the menu, the track playing in the Spotify desktop app
brings its music video onto every display, from where the track is. It is off by default.

- **Finding the video.** Loopscape searches YouTube for the official video and checks the
  candidates against the track: artist (in Latin or Cyrillic spelling), title, length, the
  channel, and words like *live*, *lyrics* or *cover* that rule a video out. A track without
  a good match keeps the regular packs on screen.
- **Streaming.** The video is streamed over HLS (VP9 up to 1440p where the Mac decodes it in
  hardware, H.264 otherwise) through one player shared by every display; nothing is
  downloaded.
- **Following Spotify.** Pause pauses the video; after 10 seconds of pause the packs come
  back until playback resumes. Skips, seeks and stops are followed; a track without a video
  brings the packs back.
- **Staying in sync.** A music video rarely matches the album recording: an intro, a scene
  without music, a cut. Loopscape reads Spotify's exact position, holds the video on its
  frame until the song gets there, and keeps it level by nudging its speed. On macOS 14.2 and
  newer it also listens to what Spotify plays and finds that moment in the video's own
  soundtrack every few seconds, so offsets and mid-song pauses in the video are measured
  rather than guessed — and remembered for the next play.

### Requirements and permissions

- `yt-dlp` from Homebrew: `brew install yt-dlp` (it brings the `deno` runtime it needs). The
  menu says so when it cannot find it.
- **Automation → Spotify**, asked on first use: Loopscape reads where Spotify is in the song.
  It never controls playback.
- **System Audio Recording** (macOS 14.2+), asked on first use: Loopscape listens to Spotify's
  output only, keeps the last few seconds in memory and never saves or sends them. Declined,
  clips still play, lined up by Spotify's position alone.

### What is kept on disk

- `clips.json` beside the wallpapers folder: which video belongs to which track, tracks
  without one (retried after 30 days) and the measured offsets. Edit an entry to correct a
  wrong match, delete it to search again.
- `~/Library/Caches/com.aklimoff.loopscape/`: one still per clip for the desktop picture and
  each clip's soundtrack reduced to onset envelopes for alignment. Safe to delete.

**Terms of service:** fetching video from YouTube through `yt-dlp` is against YouTube's
terms of service. The feature ships switched off; turning it on is your call.

**Limitation:** Spotify announces a track only on play, pause or skip, so a track that was
already playing when Loopscape started shows up at the next such event.

## Lock screen

The real lock screen belongs to `loginwindow` and is off-limits to third-party apps, so
Loopscape gets there the only sanctioned way: a screen saver. `build.sh` installs
`LoopscapeSaver.saver` into `~/Library/Screen Savers/`; in System Settings → **Wallpaper**
click **Screen Saver…**, pick **Loopscape** and set *Start Screen Saver* to taste in the
same sheet. Once the Mac locks and the idle delay passes, the saver plays the same pack the
desktop is showing (random if it cannot tell).

The saver runs inside the sandboxed `legacyScreenSaver` appex, which is entitled to read
the whole disk, so it plays straight from the wallpapers folder; the app records the current
pack in `current.txt` one directory up.

## Notes

- Videos are yours to supply; none ship with this repo.
- 16:9 clips are cropped top and bottom on ultrawide displays — `resizeAspectFill` never
  letterboxes.
- Playback pauses when the displays sleep and resumes on wake.
- Quitting from the menu keeps it closed until the next login; nothing respawns it.

## Development

- `./build.sh` — build, install to `/Applications` and launch
- `./build.sh --test` — run the unit tests (a small swiftc harness in `Tests/`, no Xcode
  project) and build `.build/resolve`
- `.build/resolve "Artist" "Track" <seconds>` — resolve one track to its video from the
  command line, the way the app does
- `./make-dmg.sh` — the release disk image

How Spotify clips work inside is described in [docs/spotify-clips.md](docs/spotify-clips.md);
changes per version are in [CHANGELOG.md](CHANGELOG.md).

## License

MIT
