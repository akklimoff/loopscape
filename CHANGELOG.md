# Changelog

## 2.0

### Spotify clips

- The track playing in the Spotify desktop app brings its music video onto every display,
  from where the track is. Off by default; switched on from the menu.
- The video is found on YouTube with `yt-dlp` and checked against the track — artist,
  title, length, channel — so lyric videos, live cuts, covers by strangers and reactions are
  ruled out. Artists Spotify spells in Latin and YouTube in Cyrillic ("MakSim" / "МакSим")
  match.
- Streamed over HLS, never downloaded: VP9 up to 1440p where the Mac decodes it in hardware,
  H.264 otherwise, through one player shared by every display.
- Follows Spotify: pause, resume, skip, seek and stop. After 10 seconds of pause the packs
  come back until playback resumes.
- Kept in sync with the song:
  - Spotify's exact position is read directly, so seeks inside a track are caught within
    seconds.
  - The video holds on its frame until the song reaches it, so it starts and lands after a
    seek in step, not wherever buffering happened to finish.
  - Small drift is corrected by nudging the video's speed, invisibly.
  - On macOS 14.2+, Loopscape listens to Spotify and finds what it hears in the video's own
    soundtrack every few seconds. Intros, scenes without music and cuts in the video are
    measured, placed where the video makes them, and remembered for the next play.
- Every failure ends at the regular packs, never at a black or frozen screen: a missing
  video, a failed stream, no network, no `yt-dlp`. Failed lookups are retried when the
  network returns and back off after repeated failures.
- The track → video mapping and measured offsets live in `clips.json`, editable by hand.

### Transitions

- Every switch — pack to clip, clip to pack, pack to pack — passes behind a white fabric
  curtain. Four styles in the new **Transition** menu: Silk, Loom, Fabric in the wind,
  Satin; or **No animation**.

### Other

- The menu shows the current Spotify track.
- Quitting restores the regular pack as the desktop picture; a playing clip survives display
  sleep and replugging.

## 1.6

- No more "Loopscape would like to access data from other apps" prompt at login: the
  screen saver plays straight from the wallpapers folder.

## 1.5

- The wallpapers folder is watched: new clips play without a restart, and deleting the
  clip on screen switches to another.
- The still behind the menu bar no longer lags one clip behind on a second display.
- `build.sh` waits for the previous instance to exit before relaunching.

## 1.4

- Stills are generated automatically from a clip's first frame; your own
  `.jpg`/`.png`/`.heic` still takes precedence.
- Rotation actually rotates; the **Interval** submenu is the only switch, **Off** keeps the
  pack across restarts.
- The library folder is now `~/Library/Application Support/Loopscape/Wallpapers/`.
- The app version is shown at the bottom of the menu.

## 1.2

- The default macOS wallpaper no longer flashes through.
- Wallpaper windows are re-anchored to their screens after wake and on space changes.
- The still wallpaper is re-asserted on wake and on resume.
- The screen saver picks the current pack on every activation.

## 1.1

- Launch at login is a menu checkbox backed by `SMAppService`.
- A fresh install opens with an empty state instead of quitting.
- New app artwork and menu bar icon.
- The rotation interval can be turned off.
- The video keeps playing behind fullscreen apps.

## 1.0

- Live video wallpapers on every display, packs from `packs.json`, rotation, a lock-screen
  screen saver.
