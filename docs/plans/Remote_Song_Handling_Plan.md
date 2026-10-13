# Remote song handling plan

## Goal and constraints

Make the remote-song play button visibly indicate loading, identify the real
tap-to-audio delays, and reduce the delays Navis or the deployment can control.
Measure cold and warm starts on Android and Linux desktop. Aim for a median
tap-to-audio of at most three seconds and a 95th percentile of at most five
seconds under a healthy network. These are targets, not claims about the
current server.

Keep the official Octo-Fiesta image, automatic album downloads, permanent
storage, and the highest available Deezer FLAC quality. Do not introduce a
private Octo-Fiesta fork or a second Deezer implementation. Preserve Navis's
permanent download -> rolling cache -> stream source priority.

## Investigated baseline (2026-09-19)

- Navis began at `1.3.1+10301`. Its full-screen `FilledButton` used a default
  `CircularProgressIndicator` whose primary color matches the button's primary
  background. The existing widget test only checked that some spinner exists.
- A remote search selection calls `QueueController.replaceWithSongs`, persists
  provisional song rows, and calls the audio handler. The handler prepares the
  selected source in phase 1 and fills the rest of the queue in phase 2.
- The deployed Octo-Fiesta image was
  `ghcr.io/v1ck3s/octo-fiesta:dev` at revision
  `afa6259a1bbf2d34202b054e3da4f0797eca937d`; Navidrome was `0.64.0`.
  Octo-Fiesta had Deezer FLAC, Album download mode, and Permanent storage.
  The official `dev` branch still pointed to that revision when rechecked;
  pulling the same mutable tag would not provide a newer lock implementation.
- The deployed revision's
  [BaseDownloadService.cs](https://github.com/V1ck3s/octo-fiesta/blob/afa6259a1bbf2d34202b054e3da4f0797eca937d/octo-fiesta/Services/Common/BaseDownloadService.cs)
  shows `DownloadAndStreamAsync` awaiting the complete track download, file
  tagging, and registration before returning a file stream.
  `DownloadSongInternalAsync` acquires a shared lock before even checking
  whether the track is already downloaded;
  background album tracks can contend with a new selected song. The library
  scan is launched asynchronously and should not be blamed without evidence.
- The download directory `/mnt/media/music/fiestarr_downloads` was on NFS.
  In a read-only sample of 48 recent downloads, file transfer had a 3.5 s
  median and 18 s maximum (server logging rounds to seconds); post-transfer
  completion had a 6.06 s median and 25.61 s maximum. Metadata writing,
  within post-transfer completion, had a 4.54 s median and 20.85 s maximum.
  These were mixed foreground/background events and not paired user-startup
  measurements. Do not sum the medians as if they represent one request.
- The Navis handler's default timed player load is 12 seconds. A cold remote
  preparation can outlast it. An isolated 25-second allowance still failed on
  a cold selection during automatic album work, so it was not retained as a
  substitute for reducing the server delay.

## Paired exploratory runtime evidence (2026-09-19)

These are diagnostic runs, not enough observations for latency percentiles.
They used an isolated Navis profile and the deployed server. The playback
criterion was a ready player with an advancing position; `playing: true` alone
was found to be a false success signal.

| Route and condition | Player source apply | First advancing position | Result |
|---|---:|---:|---|
| Configured public URL, first remote selection | 12-second timeout | none | Cold selected FLAC finished on Octo-Fiesta just before the timeout; Linux media player logged a TLS pull timeout. |
| Configured public URL, same warmed track | 1.97 s | 2.11 s | Ready and advancing. Restart: 1.91 s apply, 2.14 s advancing. |
| Configured public URL, another cold remote selection | 25-second timeout | none | The selected FLAC completed on Octo-Fiesta during the attempt, but Linux again logged a TLS pull timeout. The longer limit alone did not fix it. |
| Direct LAN Octo-Fiesta, same warmed track | 0.33 s | 0.52 s | Ready and advancing. Restart: 0.25 s apply, 0.45 s advancing. |
| Direct LAN Octo-Fiesta, uncached remote track with album download | 25-second timeout | none | The selected FLAC was downloaded and tagged after about 15 seconds, but subsequent album activity held up its stream. The on-screen loading indicator was visible in an app-owned screenshot. |

Three bounded HTTP range probes of the same warmed stream returned the first
4096 bytes through the public URL in 613-959 ms; direct LAN probes took
21-26 ms. This isolates a repeatable public-route penalty while also showing
that the player/TLS timeout is intermittent and larger than the ordinary
HTTP probe. Do not extrapolate either probe to cold FLAC preparation. The
production account URL was not changed; the LAN comparison used a cloned
database with only its server URL changed.

The second cold selection's server log showed an 11-second selected-song
download and metadata path, then immediately began a nine-track background
album download. This is consistent with the deployed full-download-before-
response behavior. The LAN cold selection likewise finished its selected FLAC
in about 15 seconds, then began album work. During that work a direct HTTP
range request for the newly cached track timed out at 8 seconds; a retry took
2.6 seconds. The identical LAN endpoint took 21-26 ms when idle. Together
with the deployed shared download lock, this is strong evidence of foreground
stream contention. Instrument lock acquisition/release in an isolated official
image experiment to quantify its exact contribution.

A reversible host benchmark copied and rewrote a 47 MB FLAC three times per
filesystem, leaving production files untouched. The median rewrite was
0.61 s on local SSD and 0.90 s on NFS; NFS copy times ranged 0.43-3.47 s
versus 0.02-0.03 s locally. This used ffmpeg rather than Octo-Fiesta's
TagLib path and is too small to justify migrating the library. The selected
production file was verified as FLAC, 44.1 kHz, 16-bit, with embedded art.
For one production album triggered by a selected remote song, server logs
recorded all nine remaining downloads completing; all nine distinct resulting
files remained present and were verified to contain FLAC audio.

Two fresh, temporary containers ran the exact deployed official image with
the same FLAC, Album, and Permanent settings but an isolated local-SSD
download directory. For the first remote result of the same search query,
time to the first 4096 stream bytes was 6.35 s and 3.75 s in those two cold
trials. In the second trial, after the background album worker had logged a
new track starting, two requests for the selected track (already present in
that container) still took 8.71 s and 8.72 s to return first bytes. This
reproduces the shared-lock delay without NFS or the public proxy. Both
containers and their experiment-owned files were removed. The two cold trials
are insufficient to estimate any percentile; they show local storage alone
does not guarantee the three-second target or protect foreground requests
during album acquisition.

A later live replay of the same search phrase selected a different Deezer
song ID and again timed out during player source apply at 12 seconds; client
provisional persistence and source resolution finished within 20 ms. The
remote search result order and membership changed between replays. The
diagnostic runner now accepts `NAVIS_PRESENTATION_REMOTE_SONG_ID` and refuses
to substitute another result when the requested ID is absent. A stable,
previously downloaded result passed a final LAN replay with player readiness
at 442 ms, first position advance at 562 ms, and a 30-second seek resuming
past the target. After clean restart it was ready at 261 ms, advanced at
397 ms, and resumed past 30 seconds after the same seek. These numbers are
warm, single-track observations and do not overturn the cold-start findings.

## Work sequence

### 1. Prepare and reproduce

1. Read `AGENTS.md`, `docs/README.md`, `docs/development/agentic-engineering.md`, the
   playback section of `docs/architecture.md`, and the runtime loop in
   `docs/development/development-workflow.md`. Record commit, dirty state, Flutter version,
   and the actual deployed image digests. Recheck mutable image tags.
2. Bootstrap Flutter dependencies. Reproduce the blank fullscreen button
   in a widget test using an external song and an active load. Capture an
   app-owned screenshot with `POST /v1/presentation/screenshot` in an isolated
   Linux profile. Use the authenticated Navis diagnostics API for control.
3. Identify an Android emulator or device and run the same scenario there.
   Do not infer Android rendering from a Linux-only screenshot.

### 2. Fix playback feedback

1. Give the fullscreen filled-button spinner an explicit, contrasting
   `ColorScheme.onPrimary` color. Give the transport spinner a stable test key
   and useful loading semantics. Keep the button's size and transport actions.
2. Follow `PlaybackSnapshot.isLoading`, `loadingSongId`, `processingState`,
   current song metadata, and remote classification from selection through
   ready, buffering, failure, cancellation, and rapid reselection. The loading
   state must correspond to the selected source, even if the old song's
   metadata is still on screen. Background preparation of *other* queue
   items must not hide a usable play/pause control.
3. Share the resulting decision across fullscreen and shell controls. If the
   existing snapshot fields cannot represent active-source loading separately
   from queue fill, introduce a narrow handler-owned field; update structural
   equality, wrappers, diagnostics, and tests together.
4. Test contrast in light and dark themes, animation across frame pumps,
   portrait/landscape, wide layout, large text, and transitions to ready and
   failure. Check the indicator inside the play button, not any spinner on
   the screen. Inspect an app-owned screenshot.

### 3. Attribute startup time

1. Instrument a bounded, redacted attempt timeline: tap accepted, provisional
   persistence/readback completed, handler queued, source resolved, player
   source set, player ready, and first advancing playback position. Include
   source kind, cache category, platform, quality, retry/cancel outcome, and
   separate background queue/cache work. Use monotonic elapsed time and opaque
   attempt IDs. Expose it through authenticated diagnostics without song
   titles, credentials, URLs, or unbounded history.
2. Measure HTTP time to first byte independently from total response time.
   The player's and sidecar's transports may bypass ordinary Dio metrics.
   Do not add production probe requests merely to measure latency.
3. Collect representative cold remote, server-warm/client-cold remote,
   rolling-cache, permanent-download, and ordinary Navidrome track samples.
   Compare Android and Linux and repeat while background album downloads are
   active. Require at least 20 valid samples per condition for final percentiles;
   report smaller diagnostic runs only as exploratory evidence. Record cache
   state before each attempt. Never remove production albums to force misses.
4. Compare the configured client route, direct LAN Octo-Fiesta, and direct
   Navidrome for songs Navidrome owns. Correlate client requests to server
   stages without exposing track/account data. First advancing position is a
   test proxy for audio; also verify audible playback on a device.

### 4. Reduce proven bottlenecks

- If provisional database work dominates, optimize that path while preserving
  foreign keys and the chosen remote source. If queue fill blocks the selected
  song, restore selected-track-first preparation and cancellation.
- If completed cache entries are missed, repair source resolution or cache
  registration without changing the source priority or quality matching.
- If desktop sidecar activity delays active playback, start it after playback
  advances while preserving eventual cache registration and generation safety.
- If stale attempts or recovery duplicate a stream, correct cancellation and
  retry ownership. Do not replace an actual optimization with a blanket longer
  timeout or speculative prefetch of search results.
- Run one server-side experiment at a time: profile artwork fetch/tag writing,
  compare temporary local storage to NFS using the *official image* and an
  isolated library, inspect the configured proxy route, and measure foreground
  requests during album download contention. Retain a setting change only
  after measured improvement and complete FLAC/album/seek/library checks.
  A production storage move requires its own integrity and rollback plan.
- If upstream full-download-before-response remains the cold-start limit,
  prepare a sanitized report for Octo-Fiesta upstream with paired timings and
  a proposal for progressive FLAC delivery and foreground priority. Do not
  send or deploy it automatically.

### 5. Verify and hand off

Run focused unit/widget/diagnostic tests, `flutter analyze --no-fatal-infos`,
and `./tool/check.sh`. Complete the required isolated runtime loop through
`GET /v1/health`, playback actions, diagnostics state, logs, and inspected
`POST /v1/presentation/screenshot` output. Repeat after a clean restart.
Validate Linux and Android; report any unavailable platform explicitly.
Check permanent FLAC files, full album acquisition, Navidrome discovery,
repeat playback, and remote seek behavior. Update the owning architecture and
development-workflow docs when behavior or diagnostics changes, and add the
final user-visible result to both changelog sources. Review the full diff and
do not include secrets or unrelated files.

Handoff must report the loading-indicator result, Navis startup before/after
measurements, retained server configuration changes, cold/warm performance
against the target, and any proven upstream limit. A visible indicator alone
does not close the latency issue.

## Next agent starting point and decision gates

The current implementation has the fullscreen and shell loading feedback,
redacted startup telemetry, an advancing-position diagnostic assertion, and
an app-owned screenshot capture during a sufficiently long remote load.
The server deployment and account URL have not been changed. Warm LAN playback
works; cold starts under automatic album work remain unresolved. Do not label
the current patch a cold-start performance fix.

Validation of the retained patch: `./tool/check.sh` passed its analyzer,
migrations, reliability tests, and full suite (1,407 tests); the Android
sideload debug APK built. The final isolated Linux replay reached first
advancing position at 0.49 s, then 0.38 s after a clean restart, on an idle
LAN route. A subsequent live run sought that same remote FLAC to 30 seconds
in about 123 ms on the initial play and 122 ms after a clean restart; both
resumed in the ready state past 30 seconds. The app-owned cold-load screenshot
showed the loading indicator, and a restart screenshot showed a usable
transport and advanced progress. Android device audio/network runtime remains
untested; Android-targeted fullscreen widget tests passed in portrait light
and dark themes with at least 3:1 spinner-to-button contrast and in landscape.
On a Pixel 9 Pro XL emulator, the Android Auto MediaBrowser cold-start gate
passed before `MainActivity`. A profile sidecar with read-only diagnostics
started and returned healthy playback/sync endpoints; its app-owned screenshot
showed onboarding rather than the player. Android remote playback and the
fullscreen loading frame still require sign-in in that sidecar.

1. Run `./tool/check.sh` after bootstrapping the root and vendored Windows
   adapter dependencies with their tracked lockfiles. In an isolated profile,
   repeat a live remote search/play through both routes using an exact remote
   result ID and inspect the
   `*-remote-loading-screenshot` and `startupAttempts`. Use the current
   diagnostic script with
   `NAVIS_PRESENTATION_SEARCH_FILTER=songs` and
   `NAVIS_PRESENTATION_SEARCH_PLAY_REMOTE=1` plus
   `NAVIS_PRESENTATION_REMOTE_SONG_ID` for paired replays. If the ID vanishes
   from the search results, choose a different stable fixture and restart the
   pair; never treat a different first result as the same warm song. The source
   database for a LAN comparison must be a private clone with only
   `server_config.url` changed;
   never replace the primary account's public URL.
2. For each trial, record selection wall time, startup stages, request time to
   first byte, selected-track download/tag completion, album download interval,
   HTTP status, player-ready time, and first advancing position. Use opaque
   trial IDs. Capture at least 20 independent cold and 20 warm trials per route
   and platform before reporting medians or p95. A timeout is a failed sample,
   not a value to omit. Avoid logging authenticated stream URLs.
3. Test the official Octo-Fiesta image in an isolated container with the same
   Deezer FLAC, Album, and Permanent settings. Compare its current NFS download
   mount to temporary local storage using separate fixture songs. During each
   album fill, request the already downloaded selected track and an unrelated
   foreground remote track. Confirm whether both wait for the global lock.
   Keep the library isolated and delete only experiment-owned files. Do not
   migrate production storage from a small benchmark.
4. Compare the public stream route with a supported internal HTTPS route that
   validates the same hostname and certificate. The direct LAN HTTP address
   was diagnostic evidence, not a portable replacement for the mobile account
   configuration. If a local route is introduced, verify off-LAN fallback,
   Android TLS behavior, artwork, seek/range requests, and authentication.
5. Retain a deployment change only if cold and warm playback improve in paired
   tests and full-album acquisition, highest-quality FLAC, permanent files,
   Navidrome discovery, repeat play, and seeking all pass. Otherwise restore
   the original configuration and prepare a sanitized Octo-Fiesta upstream
   report. The report should identify the shared lock contention and ask for
   foreground stream priority, a fast path for already completed files, and
   progressive delivery compatible with seekable FLAC and album downloads.
   Sending the report is a separate external action.
6. Validate on an Android device with a user-authenticated sidecar when
   available. Do not pass credentials through Dart defines or ADB. The
   Android-targeted widget tests check the fullscreen indicator in light and
   dark portrait themes and in landscape, but they are not an Android
   audio/network runtime result.

The proposed upstream change should preserve album and permanent FLAC behavior
while replacing the provider-wide semaphore with per-track deduplication and
foreground priority. A completed-file fast path must run before waiting for
unrelated downloads and still verify the stored quality. Background album
workers should yield to a pending stream request, then resume without losing
tracks. Progressive delivery is a separate, more involved option: it must
return valid audio before the whole FLAC is tagged while keeping range/seek
requests correct and final metadata and library registration atomic. Any
candidate needs concurrency tests for two requests for the same song, a
quality upgrade, foreground play during album fill, cancellation, and server
restart. If upstream cannot provide this in the official image, the current
full-album FLAC requirement rules out the three-second cold-start target for
some tracks; report that limitation rather than disguising it with a timeout.

## Sanitized upstream report draft (do not send automatically)

**Title:** Foreground FLAC streams wait for complete downloads and album work

On the official `ghcr.io/v1ck3s/octo-fiesta:dev` image at revision
`afa6259a1bbf2d34202b054e3da4f0797eca937d`, with Deezer FLAC,
`DownloadMode=Album`, and `StorageMode=Permanent`, a selected remote track does
not produce stream bytes until its complete download, tag write, and library
registration finish. An isolated local-SSD reproduction returned the first
4096 bytes after 6.35 s and 3.75 s in two fresh cold trials. Once the second
trial's album worker started another track, two requests for the already
downloaded selected track each waited about 8.7 s for first bytes. This was
observed without NFS or an external proxy. The deployed client also hit a
12-second player-load timeout during a cold album fill, while a warmed track
started in under a second over the LAN.

`DownloadSongInternalAsync` appears to acquire one shared `DownloadLock` before
checking whether a completed file already exists. Please consider a verified
completed-file fast path before that lock, per-track in-flight deduplication,
and priority for an interactive stream request over background album downloads.
Longer term, progressive delivery could help cold FLAC startup if range/seek,
tagging, quality selection, and atomic library registration remain correct.
The desired behavior retains automatic complete-album downloads, permanent
storage, and the highest available Deezer FLAC quality. A suitable regression
test would start a full-album fill, request an already completed song and an
unrelated new song, and confirm foreground responses are not serialized behind
all album tracks. This draft deliberately omits account, host, URL, and song
identifiers; attach only similarly sanitized timing logs if reporting upstream.
