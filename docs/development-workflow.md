# Development Workflow

This document defines the local workflow expected before opening or merging changes.

## Bootstrap

Run once after clone:

```bash
./tool/bootstrap.sh
```

What it does:
- validates `flutter` and `dart` are installed
- checks Flutter minimum and active baseline expectations
- runs `flutter pub get`

## Branding Assets

`lib/src/icon/Navis_Logo.svg` is the canonical in-app mark. After changing it,
regenerate every raster and platform icon with:

```bash
./tool/generate_platform_icons.sh
```

The script requires ImageMagick and creates the light, dark, adaptive, and app
PNG sources before refreshing Android launcher/adaptive/status icons, iOS and
macOS icon sets, Linux hicolor icons, and the Windows ICO. It directly
downscales the macOS icon set after launcher generation so grayscale-alpha
artwork remains intact at every size. The launcher master is a dark circular
badge with a transparent outer canvas; Android legacy/adaptive, macOS, Linux,
and Windows outputs must preserve that transparency. iOS stays opaque because
shipping iOS icons cannot contain transparent regions. Open and inspect the
canonical mark, the Android notification icon, and representative
smallest/largest assets for each affected platform over both light and dark
backgrounds; non-empty files or successful generation alone do not prove the
artwork is legible, centred, or free of a baked square canvas.

For a Linux dev sidecar, refresh the user-level desktop entry, a
`~/.local/bin/navis` launcher, and the content-addressed icon without
launching the app:

```bash
./tool/dev_app.sh linux-icon
```

`./tool/dev_app.sh linux` performs the same refresh automatically. The
installed desktop file uses an absolute `Exec` path to that launcher so GLib
2.88+ and KDE/GNOME can resolve it even when `navis` is not on `PATH`. The
launcher execs the newest built
`build/linux/x64/{release,profile,debug}/bundle/navis`.
The content-derived icon name prevents Wayland compositor caches from retaining a
previous brand asset under the generic `navis` name.

Android uses the cache-busting `ic_launcher_navis` resource ID for both stable
and sideload/dev manifests. Keep that ID aligned across launcher generation,
the manifest contract test, and Android Auto manifest verification. Its
adaptive background remains transparent; the foreground owns the complete
circular badge.

## Multi-OS Host Preflight

Before preparing artifacts for desktop + mobile targets, run:

```bash
./tool/multi_os_host_preflight.sh --doctor
```

What it does:
- checks toolchain prerequisites for cross-platform release hosts
- prints OS-specific install commands for missing SDKs/tools
- can run best-effort macOS autofix installs with `--auto-fix`
- optionally runs `flutter doctor -v` at the end
- reports missing Xcode Simulator runtimes as a warning (required for iOS simulator work, non-blocking for macOS desktop-only releases)

## Quality Gate

Run before each commit/PR:

```bash
./tool/check.sh
```

Checks performed:
- Linux desktop-entry installer (`tool/linux_desktop_entry_test.sh`)
- Dart formatting (`dart format --set-exit-if-changed .`)
- code generation (`build_runner`)
- static analysis (`flutter analyze --no-fatal-infos`)
- migration and critical regression suites
- full tests (`flutter test`)

The script fails fast when `/tmp` is critically low to avoid misleading test hangs.

## Mandatory Runtime Validation

For exploratory Linux setup and sync routing, `./tool/dev_app.sh run -d linux`
accepts the isolated presets documented in
[Dev Testing Builds](dev-testing-builds.md). `--first-setup`, `--bad-cache`,
`--force-setup`, the full-screen repair entries, and deterministic
`--partial-album`/`--server-error` fixtures create disposable profiles under
`build/dev-sync-scenarios/`. The launcher uses profile-mode clone diagnostics,
so the normal local database and both rolling and cover-art caches are outside
the reset path. Network gates can be seeded at process start with `--offline`
or `--metered` and changed through `dev_app.sh scenario` while it runs. These
interactive presets complement, rather than replace, bounded authenticated
diagnostics scripts and their assertions.

`./tool/check.sh` does not by itself prove that a runtime-affecting change is
complete. Agents must also run the built app, exercise the changed behavior
through an app-owned control surface, inspect the result, fix any gap, and
repeat from a clean restart. Documentation-only changes and metadata changes
proven not to affect runtime behavior are exempt.

### Validation loop

1. Write the acceptance scenario and the closest regression scenario before
   editing. For a bug fix, reproduce the failure through the running app when
   possible.
2. Add or update focused unit, widget, integration, or API-contract tests.
3. Run the relevant focused diagnostics script when one exists. Otherwise
   launch Navis with an isolated profile and use Linux for platform-neutral
   work.
4. Call `GET /v1/health` and require a successful authenticated response before
   testing feature behavior.
5. Drive the scenario through the running app's API. Check the response,
   observable provider/domain state, persisted side effects, relevant logs, and
   the absence of new errors. Use status endpoints or bounded polling instead
   of fixed sleeps for asynchronous work.
   For remote playback startup, inspect `startupAttempts` in
   `GET /v1/playback/status`. Its monotonic elapsed stages distinguish
   provisional persistence, source resolution, player apply, readiness, and
   first advancing position. The source kind and external flag are included;
   song identity and stream URLs are omitted. Compare the client timeline to
   server time-to-first-byte and download stages before attributing a delay.
   For rapid navigation, inspect the redacted `navigation` field in
   `GET /v1/playback/status`. Clone-only `POST /v1/playback/next` and
   `POST /v1/playback/previous` call the production handler and may be sent
   concurrently. Confirm desired and final indexes, pending state, timeout
   count, at most one pending queue mutation, and an advancing position after
   the last input.
6. For a visible Flutter change, call `POST /v1/presentation/screenshot`, open
   the resulting PNG with image-viewing capability, inspect the affected
   region, and record the result. Merely creating a PNG is not confirmation.
7. Use deterministic widget tests for behavior and Flutter semantics. Add
   component goldens when stable layout, clipping, painting, responsive, or
   color output is part of the contract.
8. Stop the app, fix implementation, visual, or observability gaps, reset the
   state as needed, and repeat from step 2. A missing control or observation
   endpoint is an implementation gap, not a reason to skip runtime validation.
9. When the focused loop passes, run `./tool/check.sh`, launch a clean app
   instance, and repeat the final acceptance and regression scenarios.

An **app API** is a control or observation interface executed by the running
Navis process and routed through the same production providers, controllers,
repositories, DAOs, and audio handlers as the UI. Unit-test method calls,
direct database edits, checking only that a process exists, and test-only state
changes that bypass the production path do not satisfy this requirement.

The clone-only `tool/sync_target_lane_diagnostics.sh` may prepare an isolated
database fixture with known future automatic and retry-cooldown deadlines before
launch. That is test setup only: its acceptance assertions use the running
app's authenticated `/v1/sync/automatic` and `/v1/sync/status` endpoints,
including after a clean restart, so they still exercise the production
controller and persistence path.
The same gate reads the bounded redacted `GET /v1/sync/ledger` trace. Its
`durableRuns` field is the cross-restart typed history (origin, intent, target
kind, plan kind, terminal outcome/reason, aggregate request/byte counts, and
timestamps and local request/attempt IDs); it must never contain credentials,
URLs, media/entity IDs, titles, or paths. The temporary `events` field is a bounded isolated-fixture compatibility
mirror and is not a scheduler input. Use `durableOperations` for the separate
atomic destructive-mutation audit.

`tool/manual_discovery_diagnostics.sh` is the corresponding bounded
unchanged-cursor discovery gate. It may seed a copied, isolated database and
loopback fixture before launch, but its acceptance action is the running
app's authenticated `POST /v1/sync/check` while offline; it then restores
Wi-Fi and drives the production automatic entry point to resume that queued
manual discovery. It observes both transitions through authenticated status,
ledger, and minimal album-existence APIs, renders the production detail route,
and repeats after clean restart. The fixture must use the standard singular
`artist.album` response shape, because the production client is responsible for
normalizing that protocol shape before sync logic.
For the narrower partial-detail disappearance regression, run it with
`NAVIS_MANUAL_DISCOVERY_OMIT_EXISTING=1` and
`NAVIS_MANUAL_DISCOVERY_FORCE_MANUAL_RESUME=1`. That fixture omits an existing
sibling from `getArtist`, then the running app must add the newest-feed album
without deleting the retained sibling before or after restart.
The forced-manual variant also queues an isolated higher-priority album target
before Wi-Fi reconnect. Its explicit `POST /v1/sync/check` must still record a
`deltaReconcile` terminal event with catalog endpoint evidence, retain the
target as durable pending work, and drain that target only through its later
explicit target request.

`tool/repair_confirmation_diagnostics.sh` is the bounded deletion-safety gate.
It marks only its disposable fixture clone current for the library sync model,
so the clean restart tests the pending explicit confirmation rather than an
unrelated model-upgrade repair from an older source export.
The fixture uses the production ten-minute sync lease for the large local
promotion instead of the six-second diagnostics default.
It uses an isolated fixture to require the production repair confirmation
boundary, proves the committed catalog remains untouched across a clean
restart, then verifies that only the explicit confirming repair request
promotes the candidate and that the durable operation ledger records matching
safe before/after/removal counts. It is required after changing repair
promotion, deletion analysis, ledger recording, or the confirmation
presentation. Open the resulting Sync Settings screenshot and verify the
`Last library change` summary matches the authenticated ledger counts; a later
no-op operation must not displace that destructive-operation explanation.

The endpoint's local `/library#section` destinations are deliberately mapped to
the production `librarySectionProvider`, matching the desktop rail and
navigation history. The target-lane gate uses `/library#liked` to prove that
the Liked surface remains a local read: its status, aggregate catalog counts,
and controller ledger must remain unchanged across the online and explicitly
offline navigation traces.

The required precedence is: focused diagnostics script, existing authenticated
Navis endpoints, then a new narrow endpoint with contract tests and a focused
script. Do not search for an operating-system automation substitute when an
endpoint is missing.

AT-SPI, accessibility D-Bus traversal, Dogtail, xdotool, wmctrl, OCR/window
scraping, and similar external desktop automation are not app APIs. Do not
enable accessibility services, override `NO_AT_BRIDGE`, or change the desktop
session. AT-SPI is permitted only for an explicitly scoped platform
accessibility-bridge task with user authorization. **App-owned semantics** are
values returned by the diagnostics API or asserted by Flutter widget tests;
the live accessibility tree does not qualify.

### Runtime target selection

Use the same loop on every host, but select the authoritative adapter for the
behavior under test:

| Change | Required runtime evidence |
|--------|---------------------------|
| Platform-neutral app behavior | Linux app launch plus the app API |
| Visible Flutter UI | App API state plus an opened and inspected app-owned screenshot |
| Stable layout, color, clipping, or painting | Runtime screenshot plus deterministic component golden |
| Flutter accessibility semantics | Widget semantics tests; AT-SPI only when the platform bridge itself is in scope |
| Linux media-session integration | Linux app API plus MPRIS |
| Android or Android Auto | Linux startup smoke plus the Android media-session/MediaBrowser API on a device, emulator, or DHU as appropriate |
| Windows media integration | Linux startup smoke plus `tool/windows_smtc_diagnostics.ps1` on Windows and GMTC |
| macOS or iOS integration | Linux startup smoke plus the affected Apple target and its supported platform interface |

MPRIS, SMTC, MediaBrowser, and corresponding Apple interfaces are authoritative
only for their OS-owned integration. They do not replace the Navis API for
ordinary Flutter state. If the affected target is unavailable, mark the work
unverified or blocked; only the user may explicitly accept deferred validation.

### Windows SMTC diagnostics

Run `tool/windows_smtc_diagnostics.ps1` from an isolated current-build
directory on Windows. It requires an isolated copy of a configured database,
an explicit diagnostics credential file, and two playable local song IDs. The
script starts a profile build with the authenticated diagnostics API, then uses
Windows Global Media Transport Controls (GMTC)—not desktop automation—to verify
Navis’s AppUserModelID, metadata, capabilities, transport commands, seek,
shuffle/repeat, timeline progress, and clean restart. It writes only under its
specified output root and never prints the bearer token, server URL, or media
metadata.

```powershell
.\tool\windows_smtc_diagnostics.ps1 `
  -SourceDatabase C:\path\to\navis.sqlite.sqlite `
  -CredentialFile C:\path\to\diagnostics-password `
  -SongId first-song-id -SecondSongId second-song-id
```

### Desktop app API

Linux and Windows profile diagnostics share the authenticated control-plane
contract. Android production builds remain observation-only. The planned SAF
download-folder diagnostics must be sidecar-only, restricted to an emulator
fixture tree, reject arbitrary paths, and never be enabled by the stable
package.

The profile source set contains the profile-only
`NavisDiagnosticsDocumentsProvider`. Its fixture tree lives under the profile
app's scoped files directory and is intentionally absent from debug and
release packages; Android requires document providers to be exported, so use
it only through the profile-sidecar diagnostics flow.

SAF fixture mutation is deliberately bounded: diagnostics can configure that
single tree, download a fixture-library track, detach/re-import known cache
ownership, and stage an unindexed copy for inaccessible-document review. The
unindexed copy never becomes a stable-package feature or arbitrary-path file
writer; it exists only to exercise a real `ContentResolver` read failure while
the tree remains otherwise usable.

- `SyncDiagnosticsServer` is enabled only for a supported profile build with
  valid diagnostics defines. Any future Android mutation diagnostics require a
  sidecar package suffix as an additional guard.
- `tool/sync_diagnostics.sh clone` demonstrates the supported isolated launch,
  while `tool/sync_diagnostics.sh throughput` measures one isolated Repair
  Library run without cancellation/restart scenarios affecting its result.
  `tool/sync_diagnostics.sh full-rescan` executes a full Repair Library run
  against an isolated copy of the configured library, records one-second
  planning/hydration traces, clears stale candidate/work rows only in that
  clone so the requested repair starts fresh, and captures the initial
  preparing Flutter frame.
  `tool/sync_diagnostics.sh cache-alias` seeds a cached provisional song only
  in the clone, hydrates its canonical album from the configured server, and
  asserts alias and cache ownership migration.
  handshake, authenticated requests, restart, reporting, and shutdown flow.
- `tool/repair_confirmation_diagnostics.sh` covers the explicit large-deletion
  confirmation lifecycle in an isolated fixture: pending confirmation,
  restart persistence, deliberate confirmation, and atomic promotion.
- `tool/sync_target_lane_diagnostics.sh` launches one isolated Linux clone,
  drives repeated Home-to-Library navigation and then sends
  `POST /v1/sync/target` through the production controller. It asserts neither
  action changes catalog status, verifies distinct automatic and retry
  deadlines, captures Sync Settings, and repeats the health/status/ledger/
  screenshot checks after a clean restart. Use it when changing navigation,
  catalog/target scheduling, cooldowns, or global sync presentation.
- Current observation endpoints include `GET /v1/health`,
  `GET /v1/sync/status`, `GET /v1/playback/status`,
  `GET /v1/playback/bootstrap/status`, and
  `GET /v1/diagnostics/report`. Actions use feature-scoped `POST` endpoints;
  `POST /v1/shutdown` provides clean termination.
- Presentation automation uses clone-only `GET /v1/presentation/status`,
  `POST /v1/presentation/navigate`, and
  `POST /v1/presentation/screenshot`. Navigation accepts local app routes;
  status distinguishes render-boundary readiness from the post-bootstrap app
  frame, while screenshots capture the Flutter surface at a deterministic 1.0
  pixel ratio and return only protected artifact metadata. Desktop-layout
  captures re-observe that ready surface after resize or restart transitions
  before recording final visual evidence, so an intermediate compositor frame
  cannot count as a clean-restart screenshot.
- Clone-only `POST /v1/presentation/search` submits a real query through the
  production Search providers, navigates to `/search`, waits for the final
  cached/API merge, and returns sanitized ordered IDs, relevance tiers, and
  on-server/remote classifications for acceptance assertions.
- The narrow `POST /v1/presentation/player-overlay` action shows or hides the
  queue or Now Playing through `playerOverlayStackProvider`; add similarly
  narrow production-controller actions for non-route UI instead of simulating
  coordinate clicks.
- Clone-only `POST /v1/presentation/playback-recovery` drives the production
  retry, cache-reset, and sign-out recovery controller after delayed playback
  bootstrap. It accepts only its bounded action names and never exposes
  session secrets.
- Clone-only `POST /v1/presentation/library-filter` applies a bounded
  type-to-filter query through the mounted production Library screen.
  `NAVIS_PRESENTATION_LIBRARY_FILTER_QUERY='no-match'` on `/library` captures
  the real Albums filtered-empty state before and after restart. Together with
  the deterministic `radioPresentationFixture` override,
  `NAVIS_PRESENTATION_RADIO_FILTER_QUERY='no-match'` on `/library#radio`
  captures the Radio equivalent without querying or modifying the configured
  server.
- `NAVIS_PRESENTATION_ARTIST_TOP_TRACKS_FIXTURE=1` on an existing local
  `/library/artists/<artist-id>/top-tracks` route supplies four deterministic
  Last.fm-shaped rows through the production artist-top-tracks provider. It is
  clone-only and makes the populated detail layout reviewable without using a
  Last.fm key or querying the configured server.
- Clone-only `POST /v1/presentation/notice` sends one bounded status notice to
  the mounted global notice host. `NAVIS_PRESENTATION_ERROR_NOTICE=1` uses it
  to capture the persistent error treatment and its explicit Dismiss action;
  production code never writes the diagnostics provider.
- Desktop volume memory exposes `GET /v1/playback/volume`, clone-only
  `POST /v1/playback/volume` with a numeric `value` from 0 through 1, and
  clone-only `POST /v1/playback/volume/toggle-mute`. The status response
  reports controller, persisted, and handler values without exposing media or
  server data.
- Song-row presentation exposes the read-only
  `GET /v1/presentation/song-indicator?songId=<id>` endpoint. It reports only
  production indicator and presentation roles; it never returns song metadata.
- Mix validation uses clone-only, authenticated `GET /v1/mix/status` and
  `POST /v1/mix/start`, `/v1/mix/stop`, and `/v1/mix/retry`. Start accepts
  `mode` (`server`, `lastfm`, `radio`, or `selected`), a `seedId` for song modes,
  and optional `likedOnly`/`downloadedOnly` booleans for radio. Status reports
  mode, operation generation, seed, request stage, source, candidate and actual
  inserted counts, error category, and retry state, without credentials or
  server URLs. The clone has no Last.fm key by default. Set
  `NAVIS_DIAGNOSTICS_LASTFM_KEY_FILE` to an owned regular mode-600 key file
  only for an isolated authenticated Last.fm run. The diagnostics launcher
  rejects symlinks and permissive file modes.
  Clone-only `POST /v1/playback/queue-index` accepts a bounded zero-based
  index to advance the production handler and exercise recommendation refills.

Authentication lifecycle work uses:

```bash
./tool/auth_lifecycle_diagnostics.sh clone
./tool/auth_lifecycle_diagnostics.sh partial
```

The script creates isolated database/cache profiles, uses the authenticated
`/v1/session/*` API to create a first-sync state through
`ServerDataResetService`, exercises offline recovery, captures app-owned setup
screenshots, waits for safe promotion, verifies a clean restart, starts real
playback, and signs out through `SessionLifecycleService`. A second clone
verifies initial-sync cancellation and restart at login. The clones use a
deterministic loopback Subsonic fixture and a mode-600 fixture credential file;
credential save/clear operations remain memory-wrapped and never modify device
secure storage. Clone diagnostics also use an empty process-local external
credential store and disable Last.fm, so saved ListenBrainz/Last.fm credentials
and personalized discovery services are outside the run. Direct database
changes are limited to pointing the isolated
fixture profile at that loopback process; lifecycle actions run through the
production app API and services.
The `partial` mode uses a second fixture album whose advertised count exceeds
the returned song list. It verifies that a safely promoted first catalog opens
Home with a separate usable marker and pending hydration, remains ready after
clean restart, then fills the missing tracks through the production automatic
sync path after the fixture response is corrected. It captures an app-owned Home
screenshot and keeps the full-sync timestamp null until verification completes.
With the incomplete response restored, it then visits all four full-screen
rebuild routes and verifies each partial catalog reaches Home with the album
still pending, using the durable run ledger for completion evidence.
The clone-only `POST /v1/diagnostics/sync-foreground` control sets the same
foreground admission provider as Flutter lifecycle events, allowing the
headless desktop fixture to exercise automatic work even when the window is not
focused. `POST /v1/diagnostics/automatic-sync-due` advances only the isolated
profile's durable check deadline so the production automatic entry point can
run immediately. Primary certification rejects both controls.
`GET /v1/sync/status` chooses the newer production-controller run when a UI
rebuild follows an older diagnostics-API run, and reports UI-triggered running
work as active. The durable ledger remains the cross-restart run history.
Session status is deliberately bounded to route/sync phases, queue counts, and
playback/activity flags; URLs, usernames, credentials, and tokens are forbidden.

The sync diagnostics script runs its own catalog test sequence. Its isolated
profile disables the separate destructive cache-layout upgrade route, so the
restart gate certifies committed-catalog preservation rather than performing a
cache reset. It also uses a short, heartbeated execution lease only in that
profile: the script first records the safe `leaseHeld` result after an
interruption, then retries once expiry permits recovery. For unrelated
features, add the smallest focused launcher or scenario script that reuses the
same lifecycle rather than pretending the sync sequence tested that feature.
Do not document or call an endpoint until its implementation and contract test
exist.

Use the generic presentation scenario for an app-owned runtime screenshot:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/presentation_diagnostics.sh clone / home
```

It checks presentation readiness, navigates through the live `GoRouter`, then
waits for the acknowledged destination route and transient Flutter animations
to settle before it captures the requested route before and after a clean
restart, validates PNG
signature, digest, dimensions, containment, and permissions, and records the
artifact paths under `build/presentation-diagnostics/`. The agent must open and
inspect both PNGs; the script intentionally cannot certify visual correctness
from file existence alone.

To validate a mandatory cache-contract renewal without modifying the primary
profile, use `cache-upgrade` as the label. The isolated clone starts with its
cache marker removed; the script requires the router to hold the initial
navigation on the rebuild route, waits for the screen's production rebuild to
clear the read-only renewal state, then requires the clean restart to reach
onboarding or Home as appropriate:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/presentation_diagnostics.sh clone / cache-upgrade
```

To validate the full required-rebuild → onboarding → Home warm-up path, use
`home-warmup`. It removes the cache marker and makes setup pending only in the
isolated clone, waits for the bounded six-cover warm-up to report all selected
cache entries ready, completes onboarding through the production completion
service, verifies that the aggregate warm-up state remains ready on Home, and
captures both the warmed onboarding and Home frames:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/presentation_diagnostics.sh clone / home-warmup
```

The diagnostic response contains aggregate target and ready counts only; it
must never expose cover IDs, titles, paths, URLs, or credentials. Open the
resulting Home screenshot as part of the runtime validation loop.

To validate seamless playback startup recovery, set
`NAVIS_DIAGNOSTICS_AUDIO_BOOTSTRAP_FAIL_ATTEMPTS=2` for the same clone-only
presentation command. The launcher injects two failures before audio-handler
construction, asserts the authenticated bootstrap status reports a scheduled
retry, captures the still-loading gate, then verifies normal post-bootstrap
presentation after recovery.

To validate the user recovery controls, inject four failures and set
`NAVIS_PRESENTATION_BOOTSTRAP_RECOVERY=1`. The launcher waits past the
ten-second threshold, captures the startup-recovery UI, drives its production
retry controller through `POST /v1/presentation/playback-recovery`, and then
verifies normal presentation after the fresh bootstrap attempt.

For `/library/listenbrainz/<sourcePatch>` routes, the script enables a
clone-only cached-playlist presentation override through the authenticated
diagnostics API. Navis reads the most recent weekly cache through the
production discovery provider, without copying a ListenBrainz token or
returning the cached username, so remote/local row alignment can be inspected
before and after restart.

For a Search scenario, set `NAVIS_PRESENTATION_SEARCH_QUERY`, navigate to
`/search`, and optionally require both source classes with
`NAVIS_PRESENTATION_SEARCH_REQUIRE_MIXED=1`. The script then invokes
`POST /v1/presentation/search`, validates the relevance/source ordering without
persisting display labels, and captures the settled result list on both runs.
With the songs filter and `NAVIS_PRESENTATION_SEARCH_PLAY_REMOTE=1`, it also
uses `POST /v1/presentation/search/play` plus the player-overlay controller to
capture the selected remote result in Now Playing. When the selected song
remains loading long enough, it captures a separate app-owned
`*-remote-loading-screenshot` before playback completes. The playback check requires
a ready player and an advancing position recorded in the startup timeline;
`playing: true` with an idle player or zero progress is not successful audio
startup. A terminal `queueLoadFailed` stage ends the diagnostic immediately
instead of waiting for the full polling window.
For paired or repeated runs, set `NAVIS_PRESENTATION_REMOTE_SONG_ID` to a remote
ID returned by the search result. The script requires that exact remote result
to be present on both runs, preventing a changing result order from silently
turning a warm replay into a cold test of another song.
Set `NAVIS_PRESENTATION_REMOTE_SEEK=1` with remote playback to seek the selected
track to 30 seconds on both the initial and restarted runs. The script then
requires a ready player with an advancing position at or beyond that point.
For a recoverable Search-failure capture, use an intentionally unmatched query
with `NAVIS_PRESENTATION_FORCE_SEARCH_REMOTE_FAILURE=1`. The clone-only
launcher applies the authenticated diagnostics override before submitting the
query, so the production page can be inspected without introducing a device or
server failure. Cached/local matches must remain visible when they exist; only
an otherwise empty failed search should render the retryable error state.
For an independent Now Playing capture, set
`NAVIS_PRESENTATION_OPEN_NOW_PLAYING=1`; the clone-only launcher opens the
existing production overlay and captures it without starting a remote stream.
For a deterministic transport state, set
`NAVIS_PRESENTATION_TRANSPORT_ACTION` to `baseline`, `manualNext`,
`manualPrevious`, `automaticAdvance`, `restartCurrent`, `unavailableNext`,
`unavailablePrevious`, or `rapidNext`. The authenticated clone-only control
uses local cloned songs only; it never starts audio or alters the persisted
queue.
For an Albums filtered-empty capture, use route `/library` with
`NAVIS_PRESENTATION_LIBRARY_FILTER_QUERY='no-match'`. For Radio's equivalent,
use `/library#radio` with `NAVIS_PRESENTATION_RADIO_FILTER_QUERY='no-match'`.
The latter enables a deterministic clone-only station fixture; both paths use
the authenticated Library-filter control and capture the settled state before
and after a clean restart.
For a populated Artist Top Tracks capture, use an existing artist route with
`NAVIS_PRESENTATION_ARTIST_TOP_TRACKS_FIXTURE=1`. The clone-only fixture is
applied through the authenticated diagnostics override before navigation, so
the real detail screen can be reviewed without external Last.fm traffic.
For persistent error-notice review, set `NAVIS_PRESENTATION_ERROR_NOTICE=1`.
The isolated launcher posts the recovery message through the mounted notice
host, validates its accepted level, and captures the visible action without
simulating a device-level error.

Use the focused volume-memory scenario for desktop volume changes:

```bash
./tool/volume_memory_diagnostics.sh
```

It launches a Linux profile build against one isolated clone three times. The
scenario sets 37%, verifies a clean restart, persists mute across another
restart, then verifies that Unmute returns to 37%. Sanitized JSON responses and
the local app log are retained under `build/volume-memory-diagnostics/`.

Use the focused desktop window scenario for shell, bottom-player, resize-gate,
or Mini Player changes:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/desktop_layout_diagnostics.sh
```

It drives `GET/POST /v1/presentation/window`, captures 1306×853 standard,
1159×678 short, 887×900 compact, and minimum 800×600 Desktop View plus the
canonical 720×405 and minimum 560×360 Mini Player through the app-owned
screenshot endpoint, verifies Keep Mini returns to 720×405, checks the log, and
repeats after a clean restart. Open and inspect every generated PNG, including
the bottom-player action/volume region at each Desktop width and the embedded
Mini Player volume row at both Mini sizes. Inspect both Desktop entry gates
(799×599 and short 799×444) and confirm both choices remain fully visible.

Use the focused song-indicator scenario for shared song-row changes:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/playback_indicator_diagnostics.sh clone
```

It starts and pauses songs through the production playback API, polls playback
and presentation state, verifies that the marker moves between songs, reviews
hard-fail log patterns, opens the queue through its narrow app API, captures
current, paused, and switched states, and repeats after a clean restart. Its
app-owned screenshots and widget semantics are the canonical visual evidence;
do not attempt native desktop automation.

For desktop seek and remote-recovery changes, run:

```bash
python3 tool/seek_cache_diag.py
```

The clone-only scenario sets the application volume to zero and verifies the
effective player volume before it starts media. It records seeks past the
current buffer, recovery events, and the post-seek transport state under
`build/sync-diagnostics/`; do not use it as evidence if mute verification
fails.

After `./tool/check.sh` passes, set `NAVIS_QUALITY_GATE_RESULT=passed` on the
final invocation so the sanitized runtime-validation record captures the gate.

### App API extension and safety contract

Every diagnostic or agent-control surface must:

- Be unavailable in production release builds, bind only to loopback on an
  ephemeral port, and require a random bearer token communicated through a
  handshake file. Linux/macOS profiles apply mode `0600`; Windows profiles use
  their isolated per-user diagnostics directory and must not wait for a POSIX
  permission command before serving requests. Android publishes the same
  bounded handshake through an app-owned native bridge to its external-files
  directory; do not attempt to create `/sdcard/Android/data/...` with Dart I/O.
- Use an isolated clone of the configured database and cache by default. Use
  primary certification only when explicitly justified, after the clone
  scenario passes, with its backup and mutation restrictions intact.
- Expose feature-scoped actions and state/status queries, deterministic
  completion or bounded polling, structured error responses, and clean
  shutdown.
- Invoke the production app path. Direct state or database mutation is allowed
  only for isolated fixture setup or an explicitly named fault-injection
  operation.
- Avoid returning or logging credentials, bearer tokens, private server URLs,
  raw cloned records, or other sensitive values.
- Store screenshots only below the validated diagnostics root in a mode-`0700`
  directory with mode-`0600` PNGs. Treat them as potentially sensitive local
  artifacts: never commit, upload, embed in logs, or share without redaction.
- Add focused server/contract tests and update this document plus
  `docs/architecture.md` when the interface or lifecycle changes.

For goldens, use fixed fixtures, deterministic themes, and the existing
adaptive viewport helper. Prefer component crops. Avoid live catalog data,
network artwork, continuous animation, and platform-font-dependent full-screen
goldens. Test animations through state transitions and capture stable start/end
states.

### Completion evidence

For runtime-affecting work, the final handoff and any applicable `PROGRESS.md`
entry must record, without secrets:

- Runtime target and whether an isolated clone or explicitly approved primary
  certification profile was used.
- Acceptance and regression scenarios exercised.
- App API endpoints and native service APIs used.
- Results, relevant log review, app-owned screenshot artifacts that were
  actually opened and inspected, and widget/golden evidence when applicable.
- A short summary of fix-and-retest iterations.
- Final `./tool/check.sh` result and the clean-restart runtime result.

## Core Release Gate

Use this focused release-ready gate when the full development test matrix is
not required:

```bash
./tool/release_gate_core.sh
```

Quick mode (skips full `flutter test` pass):

```bash
./tool/release_gate_core.sh --quick
```

## Phase 1 Close-Out Gate

When Phase 1 is ready to close, run the dedicated close-out script:

```bash
export NAVIS_SMOKE_BASE_URL="https://your-subsonic-host"
export NAVIS_SMOKE_USERNAME="your-username"
export NAVIS_SMOKE_PASSWORD="your-password"
# Optional:
export NAVIS_SMOKE_API_VERSION="1.16.1"
export NAVIS_SMOKE_USE_LEGACY_AUTH="false"

./tool/phase1_closeout.sh
# or: make phase1-closeout
```

This gate ensures:
- drift DB tests execute (not skipped)
- migration tests execute (not skipped)
- real-server `ping()` + `getOpenSubsonicExtensions()` smoke succeeds

## Phase 4 Codec Close-Out Gate

Before opening Phase 5 implementation, run the codec close-out preflight and then complete the runtime matrix on a physical Android device:

```bash
./tool/phase4_codec_closeout.sh <device-id> [server-variant]
# or: make phase4-codec-closeout DEVICE_ID=<device-id> [SERVER_VARIANT=OpenSubsonic]
```

Environment alternatives:

```bash
export NAVIS_CODEC_DEVICE_ID="<device-id>"
export NAVIS_CODEC_SERVER_VARIANT="OpenSubsonic"
./tool/phase4_codec_closeout.sh
```

This gate ensures:
- codec-critical tests execute (not skipped)
- device metadata is captured for evidence rows
- matrix row templates are generated for FLAC/ALAC/MP3/AAC/Opus/Vorbis
- release checklist protocol in `docs/troubleshooting.md` is followed end-to-end

## Optional Pre-commit Hook

Enable local guardrails:

```bash
git config core.hooksPath .githooks
chmod +x .githooks/pre-commit
```

This runs `./tool/check.sh` before each commit.

## Publishing a Release

When a feature, bug fix, or phase is complete and merged to `main`:

```bash
./tool/release.sh v0.2.0
```

This runs the full quality gate, builds a release APK, tags the commit, creates a Forgejo release, and uploads the APK. See [ci-cd.md](ci-cd.md) for setup details.

For Android releases, `tool/release.sh` cleans stale APK build outputs before
building, removes an existing same-name root release asset before copying, and
fails publication if the final APK metadata/signature or release string
sentinels do not match the expected release.

`tool/release.sh` fails when `pubspec.yaml` already contains the exact requested
release version. Use a new version for normal releases; reserve
`--allow-existing-version` for intentional rebuilds or failed-release retries.

Advanced release packaging options:

```bash
# Linux native package
./tool/release.sh v0.2.0 --targets=linux --linux-package=deb

# Windows installable .exe (Inno Setup)
./tool/release.sh v0.2.0 --targets=windows --windows-package=exe

# macOS signed + notarized artifact
./tool/release.sh v0.2.0 --targets=macos --macos-notarize
```

Pre-release builds (from `dev` branch when needed):

```bash
./tool/release.sh v0.3.0-beta.1
```

Tags containing `-alpha`, `-beta`, `-rc`, or `-dev` are automatically marked as pre-release on Forgejo.

## Dependency Health

Run periodically to check for outdated packages:

```bash
flutter pub outdated
dart pub outdated
```

Or: `make outdated`

## Runtime Verification

Preferred runtime targets for this project are Android and iOS.

### Android Sidecar Install

To install a temporary debug build on Android without replacing the normally
installed app, set a debug-only package suffix and app name before running the
build:

```bash
export NAVIS_APP_ID_SUFFIX=".sidecar"
export NAVIS_APP_NAME="Navis Sidecar"

flutter run -d <device-id> --debug
```

For this repo's currently attached phone:

```bash
export NAVIS_APP_ID_SUFFIX=".sidecar"
export NAVIS_APP_NAME="Navis Sidecar"

flutter run -d R5CX14TVQEE --debug
```

The sidecar package installs as `com.navis.app.navis.sidecar`, so it lives
next to the regular `com.navis.app.navis` install. Remove it later with:

```bash
adb uninstall com.navis.app.navis.sidecar
```

Unset the variables to go back to the normal package:

```bash
unset NAVIS_APP_ID_SUFFIX
unset NAVIS_APP_NAME
```

### Dev Sidecar Helper Script

Use the helper script to run or build a sidecar app without manually exporting variables each time:

```bash
./tool/dev_app.sh run -d <device-id>
./tool/dev_app.sh apk
./tool/dev_app.sh apk-debug
```

Defaults used by this script:

- `NAVIS_APP_ID_SUFFIX=.dev`
- `NAVIS_APP_NAME="Navis Dev"`
- `--dart-define=NAVIS_UPDATE_CHANNEL=dev`
- `--dart-define=NAVIS_SELF_UPDATE=true`
- Android builds use the `sideload` flavor and emit
  `build/app/outputs/flutter-apk/app-sideload-release.apk`.

`apk-debug` emits an installable debug sidecar and accepts normal Flutter build
arguments. The Android Auto emulator gate uses its x86_64 split APK so it can
fit reliably on a standard phone AVD.

This ensures the dev app can live next to stable and the in-app updater checks dev-channel release assets.

For Android Auto phone-projection work, validate the source or merged manifest
before starting DHU:

```bash
./tool/verify_android_auto_manifest.sh
```

The verifier requires the automotive descriptor, projection metadata, exported
canonical `com.ryanheise.audioservice.AudioService`, media-browser intent
filter, icon/theme metadata, and the absence of the privileged bind permission.
If an APK already exists, it also confirms that the descriptor was packaged.

Before physical-phone DHU validation, run the automated cold-start regression
on a standard Android phone emulator:

```bash
./tool/android_auto_cold_start_diagnostics.sh
```

The command installs only the `.dev` sidecar, force-stops it, then uses an
external MediaBrowser client to start the canonical audio service without ever
launching `MainActivity`. It is intentionally not an AAOS test and does not
replace DHU projection validation.
The sidecar install permits replacing a newer dev build with the diagnostics
build while retaining sidecar app data.

When Android SDK/device is not available locally, you can still verify app startup behavior with Linux desktop:

```bash
flutter run -d linux
```

This is a local workaround and does not replace Android runtime validation.

### Linux Sync Diagnostics

After `./tool/check.sh` passes, exercise catalog promotion against a consistent
clone of the configured library and the real server:

```bash
NAVIS_DIAGNOSTICS_PRIMARY_DB=/absolute/path/to/navis.sqlite.sqlite \
  ./tool/sync_diagnostics.sh clone
```

The profile-only launcher stores its authenticated loopback handshake, logs,
JSON report, and database checks under `build/sync-diagnostics/`. It rewrites
cached-file paths in the clone so cancellation, restart, and deletion tests
cannot unlink primary cache files. Clone mode first drains startup work under
the host's real network policy before applying scenario overrides, so a
schema-migrating or mid-repair primary clone cannot leak its startup model
repair into the metered guardrail scenarios. The cellular automatic,
manual-check, and metered-Wi-Fi checks correlate each posted action with new
redacted ledger events, durable requests, and attempt endpoint counts. A
preceding repair's displayed status is not attributed to a later bounded
action. After startup work settles, clone mode saves the idle sync status and
captures an app-owned Library screenshot for visual inspection of the hydration
backlog notice, then returns to Home before applying guardrail overrides.
Clone mode can simulate metered/cellular policy through diagnostics overrides
and asserts hard-probe, interactive hydration, explicit repair-consent deferral
with zero requests,
budget, and one-time override guardrails without requiring a real modem. The
clone suite also certifies the foreground cellular
Check for updates path: exactly one newest-album page, no artist/bulk-song
sweep, and at most three changed-album details. Its authenticated
`recent-albums` observation also proves the Library's production Recently Added
query follows the server's
newest-feed positions first, then server creation date for entries outside that
feed, after the check.

To validate cache migration for a provisional song after the server has
canonicalized it, run the focused clone-only scenario:

```bash
./tool/sync_diagnostics.sh cache-alias
```

It creates a disposable cache row in the clone, uses the running Navis app API
to hydrate the matching real album, and asserts that the persisted identity
alias exists, the old cache row is gone, the canonical row owns the cache, and
the cache file remains present. It never writes to the primary database or
cache directory.

For a live-scale full Repair Library trace without changing primary data, run:

```bash
./tool/sync_diagnostics.sh full-rescan
```

The result records the immediate `preparing` state and captures its app-owned
Flutter frame before durable planning, then records catalog hydration and the
per-album fallback request counts. It clears stale candidate/work state only
in its disposable clone, so an interrupted earlier run cannot replace the
requested full repair. If deletion safety requires confirmation, the clone
runner makes one explicit confirmation pass.

When a newly changed server password has not yet been saved in desktop secure
storage, provide a separately permissioned temporary credential file through
`NAVIS_DIAGNOSTICS_CREDENTIAL_PATH`; the clone reads it without altering the
primary credential store. `NAVIS_DIAGNOSTICS_USERNAME` similarly replaces the
username only in the clone when validating a different account.

Run primary certification only after the clone suite passes:

```bash
./tool/sync_diagnostics.sh primary-certification
```

Primary mode refuses to start beside another Navis process, disables mutation
and cancellation endpoints, requires the normal Linux database path, and
retains a timestamped SQLite online backup in
`~/Documents/navis-certification-backups` unless
`NAVIS_DIAGNOSTICS_BACKUP_ROOT` overrides that location.

### Android read-only scheduler observation

For a connected Android device, build an isolated profile sidecar with the
internal background-sync and diagnostics flags. The user must authenticate in
the sidecar; do not pass credentials as Dart defines or through ADB. The app
publishes the loopback handshake through `getExternalFilesDir()`; retrieve it
from `/sdcard/Android/data/<sidecar-package>/files/navis-diagnostics/handshake.json`
without printing its bearer token, then forward its port with `adb forward`.
Use the token only for authenticated `GET /v1/sync/status`, `GET /v1/health`,
and the read-only `POST /v1/presentation/screenshot` request. Screenshots are
written below that same sidecar-scoped diagnostics directory and must be pulled
and visually inspected; primary Android certification permits no navigation,
scheduling, cancellation, or other mutation.

## MacBook Testing Guide

For complete MacBook test procedures (quick smoke, full regression, release/notarization validation), use:

`docs/macos-testing-playbook.md`

The manual discovery gate also calls `GET /v1/library/album?verifySongs=true`
(with the fixture album `id`) and requires `persistedSongCount` before and after
restart. A hydration flag or declared server count alone is insufficient proof
that an album's tracks were actually stored.

Set `NAVIS_ANNOTATION_FIXTURE=true` when running
`tool/manual_discovery_diagnostics.sh` to also queue offline song/album/artist
favorites and a rating, then verify exact protocol parameters and a drained
outbox after reconnect. This explicitly enables
`NAVIS_DIAGNOSTICS_ANNOTATION_FIXTURE` only for an HTTP loopback server with the
fixture username; ordinary diagnostics still refuse annotation delivery. The
fixture clears copied outbox entries before launch. Its copied catalog is marked
recently track-verified so the one-album fixture does not pretend to serve the
unrelated live library's historical metadata.

Clone-only `POST /v1/presentation/library-scroll` accepts `pixels` (0–100000)
and animates the mounted Albums view through its real scroll controller, returning
the actual position. `POST /v1/diagnostics/metrics/reset` clears frame/canary samples
and playback-failure counts between timed scenarios. Reports include current and
process-lifetime peak RSS. These support controlled sync/playback/scroll trials;
API action latency and build+raster samples are not hardware input-latency or
hardware dropped-frame measurements.
Reports retain `frames` as build-plus-raster for comparison with earlier traces,
and expose `frameBuild`, `frameRaster` and `frameSpan` separately using the same
latest-5,000-sample window. `frameSpan` is Flutter's vsync-to-raster-finish duration;
none of these fields measures presentation by the compositor or audible gaps.
The reset endpoint clears all four windows together. Use the separate phases to
locate UI-thread versus raster cost before choosing a performance change.


### Isolated Android worker fixture

A profile **clone** sidecar with a nonempty `NAVIS_APP_ID_SUFFIX` may opt into
`NAVIS_DIAGNOSTICS_ANDROID_WORKER_FIXTURE=true`. This uses that sidecar's real
Android secure storage so a separate headless Flutter engine can read the
fixture session after process death. Normal clone diagnostics keep credential
changes in memory. Connect a loopback fixture through authenticated
`POST /v1/session/connect`; never pass real credentials in Dart defines or ADB.
Use a fresh sidecar package and its own `app_flutter/navis.sqlite.sqlite` path
for both foreground and worker access. Observe WorkManager through Android's
JobScheduler service API, and inspect results through authenticated Navis status
and durable history. Primary certification remains read-only.

For a metering/process-death worker check, constrain the emulator fixture Wi-Fi
through Android's network-policy API, enqueue the production catch-up schedule
via a diagnostics background-policy change, close the sidecar activity, and kill
only that background sidecar process. Restoring unmetered Wi-Fi lets WorkManager
start a new process; inspect the persisted worker result and actual song counts
after reopening the sidecar. Restore the emulator's original network policy.
Forcing a periodic JobScheduler job early is insufficient because WorkManager
still enforces its own next-run timestamp.

Diagnostics reports label persisted promotion statistics with
`promotionScope: lastCommittedCatalogPromotion` and `promotionGeneration`.
Those statistics may predate the current incremental check; current endpoint
counts and pending counts come from the active/terminal operation state.

`./tool/dev_app.sh run -d linux --first-setup` and the other interactive clone
presets compile with `NAVIS_SYNC_DIAGNOSTICS_LEASE_SECONDS=600`, the production
lease duration. For a direct large first-sync benchmark, pass that same define.
The default six-second diagnostic lease is deliberately short for
interrupted-owner tests and can expire while a large atomic promotion holds the
database writer. The override is bounded to 1–600 seconds and has no effect
outside diagnostics builds; it does not disable ownership checks.


Authenticated `GET /v1/sync/attempts` returns up to 20 recent active, recovered or
terminal attempts for the active server, including their bounded telemetry.
The `reportedAttempt` field of `GET /v1/diagnostics/report` selects the exact `sync.runAttemptId`,
not the most recent auxiliary attempt; it is null when that status has no attempt.
Sync status and durable outcomes expose request/attempt IDs and start timestamps.
`workSummary` groups durable work by safe target kind, status, cooldown and next
retry time. Work-row, pending-album and pending-artist counts are separate axes
and must not be added together as an operation count.

Inspect `captureComplete`, omitted phase/attempt counts and checkpoint failures
before interpreting a trace. A complete capture is not a durable completion
claim; consult the attempt status and outcome. Request ordinals link retries,
while endpoint totals survive trace truncation. Phase elapsed times include
awaited network/database work; applying-to-cleaning covers publication including
commit, and should not be confused with the narrower persisted reported-apply
counter. Capture evidence before its opportunistic seven-day detail pruning;
aggregate terminal history lasts 90 days. API tests cover redaction, migration,
recovery and correlation; runtime certification should compare the same attempt
before and after a clean restart.
