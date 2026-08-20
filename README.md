# Loopscape

Live video wallpapers for macOS, on every display.

macOS 26 (Tahoe) has no way to use your own video as a desktop wallpaper. The aerials
catalog under `~/Library/Application Support/com.apple.wallpaper/aerials/` is no longer
wired to the wallpaper picker, and the pickers themselves read from
`/System/Library/Desktop Pictures`, which lives on the read-only system volume.

Loopscape is a ~400-line menu bar app that fills the gap. It places one borderless window
per `NSScreen` at desktop window level — below the desktop icons, above the wallpaper — and
loops a video in each.

## Install

Download `Loopscape-1.0.dmg` from the [latest release](https://github.com/akklimoff/loopscape/releases/latest),
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

Building locally avoids the quarantine flag entirely, and installs the launch agent so the
app starts at login:

```sh
git clone https://github.com/akklimoff/loopscape.git
cd loopscape
./build.sh
```

Requires Apple Silicon and the Xcode command line tools (`xcode-select --install`).
`make-dmg.sh` produces the disk image.

Loopscape ships with no videos, so it will tell you the folder is empty and quit until you
add some — see below.

## Adding wallpapers

Put your clips in `~/Library/Application Support/Loopscape/videos/` as `<slug>.mp4`, each
with a still frame beside it as `<slug>.jpg`, then list them in `packs.json` one directory
up:

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
  "$HOME/Library/Application Support/Loopscape/videos/winter-ruins.mp4"

ffmpeg -i input.webm -frames:v 1 -q:v 2 \
  "$HOME/Library/Application Support/Loopscape/videos/winter-ruins.jpg"
```

The still is not decoration. The menu bar blurs the *desktop picture* rather than the
window stack, so a video alone leaves the old wallpaper showing through the top strip.
Loopscape paints the system wallpaper with the clip's still on every switch, and the seam
disappears.

## Menu

The status item is the entire interface: pick a pack, set the rotation interval (5 / 15 /
30 / 60 minutes, or off), jump to the next one, open the videos folder, quit. Choosing a
pack pins it; turning the interval off pins whatever is showing, so it survives a restart.

The UI is Russian when the system's primary language is Russian, English otherwise.

## Notes

- Videos are yours to supply; none ship with this repo.
- 16:9 clips are cropped top and bottom on ultrawide displays — `resizeAspectFill` never
  letterboxes.
- Playback pauses when the displays sleep and resumes on wake.
- Quitting from the menu keeps it closed until the next login; the agent does not respawn it.

## License

MIT
