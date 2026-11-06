# macOS hand-off, 2026-11-06

Coordinator hand-off for the macOS owner test-feedback work. Ledger:
[macOS_Parity_Plan.md](macOS_Parity_Plan.md) (rows M12, M13) and the comments on
Porthorion/Navis#209. Previous hand-off: #209 comment 6651698183.

## State (verified 2026-11-06)

- `dev` = `origin/dev` = `2ad5fec1`, checkout clean. Merged on `dev`: #282 (folder
  picker can create folders), #283 (search ranking), #285 (album colour fades),
  #256 (Navis LGPL libmpv), #300/#302/#303 (media info dialog, search hero; owned by
  the other session).
- **#295** `fix/macos-control-center-pause` (M12), worktree
  `../Navis-worktrees/cc-pause`, head `4dfc782b` (merge of `dev`; changelog
  conflict resolved by keeping both 1.5.2 entries). Reviews done (Sonnet ×2, Flash),
  findings fixed, owner confirmed the snap-back is gone. Next: CI green → squash-merge
  `fix(macos): stop Control Center showing a stale position on pause`, delete branch
  and worktree, update M12 and #209.
- Owner-installed test app: `~/Applications/Navis.app`, built from #295 at `00414f0f`,
  signed "Navis Local Dev".

## Next item: M13, Control Center time at non-1× speed

Owner report (0.8×): app 2:03 of 2:12; Control Center 02:34 elapsed, -00:11 left.
Both numbers are the app's divided by 0.8, so this is the projection working as
designed, not drift:

- `lib/src/features/player/data/real_time_projection_audio_handler.dart`
  (`projectPlaybackStateToRealTime`, `projectMediaItemToRealTime`, ~line 255)
  divides position, buffered position and duration by the speed and publishes speed
  1.0. Added in f70f4a6d (2026-09-30) because Bluetooth AVRCP has no rate field and car,
  headphone and lock-screen displays tick at 1× ("we had this same issue with
  bluetooth before"). It wraps the handler on every platform
  (`navis_audio_handler_bootstrap.dart:196`). System seeks are converted back with
  `realTimeToTrackPosition`.
- Windows SMTC publishes real time on purpose (`docs/architecture.md` ~5757); Linux
  MPRIS publishes Rate (f70f4a6d).
- macOS MPNowPlayingInfoCenter has `MPNowPlayingInfoPropertyPlaybackRate` and
  extrapolates with it, so it can show track time at the real speed. The vendored
  plugin also sets `DefaultPlaybackRate` to the speed; Apple defines it as the normal
  rate (1.0).

Design question for Opus (decide before any code; ask the owner only if the choice
is a product call): what should the system surfaces show at non-1×?

- **A (likely):** on macOS, publish track time with the real `PlaybackRate` and
  `DefaultPlaybackRate` 1.0, so Control Center matches the app; keep the projection
  on Android (AVRCP), Windows (SMTC has no rate) and iOS until iOS is a target
  (CarPlay/AVRCP from iOS need checking). Keep the queue window and Android art
  parts of the handler on every platform; only the time projection is gated.
- **B:** keep real time everywhere and show remaining real time in the app. Bigger
  product change, not asked for.

Plan points for the Sonnet build (if A):

- Gate only the time projection (playback state, media item duration, system seek
  conversion) on `Platform.isMacOS`, inside the existing handler, not a new
  handler. Linux and Windows behaviour must not change (parity plan rule).
- Vendored `third_party/audio_service/.../AudioServicePlugin.m`: `DefaultPlaybackRate`
  1.0; check the #295 drift check uses the real rate (`publishedRate`), so a
  0.8× state does not republish every tick. Note it in `NAVIS_CHANGES.md`.
- Failing tests first: the projection tests for macOS vs other platforms (speed
  0.8 and 1.5, seek from the system at 0.8), and the speed change mid-song.
- Runtime check on a signed release build: 1×, 0.8×, 1.5×; Control Center elapsed
  and remaining match the app for 30 s; scrub from Control Center lands at the right
  track time; pause/resume (M12 must not regress); change speed while paused.
- Risk: playback, cross-platform handler → Opus plan, Sonnet build, fresh Sonnet
  review, owner hands-on. Can land on its own branch after #295 merges (both touch
  the vendored plugin).

## After M13

- Changelog lines for M3/M4/M5/M11 in `lib/src/features/changelog/changelog_data.dart`
  (not yet added).
- Desktop media-info dialog belongs to the other session ("Navis — 1.5.2 #236 runtime +
  dev build"); don't duplicate.

## Owner actions

- Apple Development certificate (free, Personal Team) for test builds, so the
  keychain prompt stops; paid Developer account before store submissions. Details in
  the parity plan's Owner actions.
- Android cover-art check (M6, #257).

## Rules that bit this session

- Owner test builds come from `dev` (or the PR branch under test):
  `flutter build macos --release --dart-define=NAVIS_UPDATE_CHANNEL=stable`, `ditto`
  to `~/Applications/Navis.app`, then
  `codesign --force --deep --preserve-metadata=entitlements,identifier --sign "Navis Local Dev" ~/Applications/Navis.app`.
- 8 GB Mac: one heavy job at a time through the lockf gate, focused tests with
  `-j 2`, no full suite locally (CI runs it). Never `kill` processes; wait for them.
