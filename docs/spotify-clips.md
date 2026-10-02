# Spotify clips — how it works

The path from "Spotify started a track" to "its video plays in step on every display", and
where each step lives.

## Layout

`Clips/` holds everything that does not need AppKit or AVFoundation: matching, the
resolver, storage, alignment maths. It is compiled into the app, into the unit tests and
into the `resolve` command-line tool. `App/` holds the parts that talk to the system.

| File | Role |
|---|---|
| `App/NowPlaying.swift`, `App/Track.swift` | Spotify's `PlaybackStateChanged` notification → `Track` |
| `App/ClipMode.swift` | The state machine: which track, which clip, paused or not; returns effects, does no I/O |
| `Clips/ClipMatching.swift` | Scores YouTube candidates against a track |
| `Clips/YtDlp.swift` | Runs `yt-dlp` for search, stream URLs and the soundtrack URL |
| `Clips/ClipResolver.swift`, `Clips/ClipStore.swift` | Track → video, cached in `clips.json` with misses and offsets |
| `App/StreamSession.swift` | One HLS item on the shared `AVQueuePlayer`: start, hold, jump, stall watchdog |
| `App/Curtain*.swift` | The fabric transition: pure timing in `Curtain`, Metal drawing in `CurtainView`, sequencing in `CurtainDirector` |
| `App/SpotifyPosition.swift` | Spotify's exact position over Apple Events, addressed by process |
| `App/ClipSync.swift` | Keep, nudge the rate, or jump, given clip time and song time |
| `App/SpotifyAudio.swift` | A Core Audio process tap on Spotify, the last 20 s in a ring buffer |
| `App/ClipAudio.swift`, `Clips/SoundtrackCache.swift` | The video's soundtrack, decoded and cached as onset envelopes |
| `Clips/AudioAlign.swift`, `Clips/OffsetMap.swift` | Where the heard stretch sits in the soundtrack; the offset per stretch of the song |
| `App/AppDelegate+*.swift` | Wire the above together: `+SpotifyClips` runs `ClipMode`'s effects, `+Stream`, `+ClipSync` and `+ClipAlignment` drive playback |

## A track starts

1. Spotify posts `PlaybackStateChanged`; `ClipMode` returns `.resolve`.
2. The resolver looks the track up in `clips.json`. Unknown tracks are searched on YouTube
   (`ytsearch5`) and the best candidate is picked; a track without a fit is recorded as a
   miss for 30 days. The video's HLS URL comes from `yt-dlp` and is kept in memory until
   it expires.
3. The curtain covers the screen while the stream starts behind it. The stream seeks to
   where the song will be once it is ready, plus a lead, and holds there.
4. The first frame arrives, the still is written for the desktop picture, the curtain
   reveals the clip.

## Staying in sync

Three layers, each correcting what the one before cannot see:

- **Position.** Spotify reports a position only with play, pause and skip events, so
  Loopscape asks for it directly every few seconds. A reading that disagrees with the
  extrapolation by more than 0.3 s means a seek.
- **Hold and release.** Every seek — the start and any jump — pauses the clip on the
  target frame, reads Spotify, and starts playback at the moment the song reaches the
  frame. A seek that landed too late is retried once.
- **Rate.** Drift above 0.15 s is closed by playing the clip at up to ±20 % speed until it
  is within 0.04 s; drift above 1 s is a jump.

What a clock cannot know is how the video differs from the album recording. That is the
offset: video time minus song time, per stretch of the song.

## Measuring the offset

On macOS 14.2+ a process tap records Spotify's output, mixed down to mono and decimated to
12 kHz, the last 20 s held in memory. The video's soundtrack is fetched once (the smallest
m4a, downloaded with a Range request, which googlevideo serves at full speed) and reduced
to onset envelopes in eight log-spaced bands, cached on disk per video.

Every 3 s the last 6 s heard are reduced the same way and located in the soundtrack by
normalised cross-correlation averaged over the bands. Bands matter: one envelope places a
rock song almost as well one bar off, the vocal and guitar lines do not repeat bar to bar.
The search runs near the offset in force first and over the whole soundtrack only when
that fails. A match counts when its peak is at least 0.35 and stands 0.15 above the best
placement elsewhere.

A change of more than 0.5 s is a cut in the video or a chorus mistaken for another one;
it is accepted only when the next check agrees. Then the last 18 s heard are scored piece
by piece at the old and the new offset, and the change is placed where the old one stops
fitting — where the video makes the cut, not seconds later where it was noticed. The map
is saved to `clips.json`, and the next play of the song jumps at that point.

## Failure

Every failure path ends at the regular packs: no video, no format at 480p or above, a
stream that stalls, no network, no `yt-dlp`. Failed lookups are retried once after 15 s,
again when the network returns, and back off for 15 minutes after three in a row.
Alignment failing only means the clip is lined up by Spotify's position alone.
