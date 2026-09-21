# Android certification checklist — stale-cache recovery release

The plan's release acceptance requires recorded Android results. No device was
attached to the certification machine, so this checklist is prepared for the
user to run and record. Check items off and note evidence (screenshot, log
line, or diagnostics export) per row.

## Setup

- [ ] Build and install the dev side-by-side app:
      `./tool/dev_app.sh apk` then install `com.navis.app.navis.dev`.
- [ ] Confirm the app upgrades in place over an existing 1.4.0 install (do not
      uninstall first — the schema 79→80 migration and the post-upgrade
      one-shot reconciliation only run on upgrade).
- [ ] Record the pre-upgrade liked-songs count and one pinned album for the
      user-state checks below.

## Upgrade migration

- [ ] First launch after upgrade completes without a cache reset prompt.
- [ ] Library, favorites, and downloads all still present after the
      migration (schema 80).
- [ ] The startup reconciliation schedules exactly one full repair
      (Settings → Sync shows a repair running or queued); on cellular it
      waits for consent/Wi-Fi, and after it completes the model version is
      stamped (a later restart must not re-run the repair).

## User-state preservation (plan §4 acceptance)

- [ ] Liked songs, ratings, and play history survive the upgrade and the
      post-upgrade repair.
- [ ] Permanent downloads still play in offline/airplane mode after the
      repair.
- [ ] Renamed/re-ID'd server content (if the server scanned since the last
      sync) relinks: play a previously downloaded track that the server
      re-issued under a new ID; playback resumes from the local file and the
      like carries to the new ID.

## SAF / storage

- [ ] Download a new album to a SAF (custom folder) location; file lands in
      the picked tree and plays offline.
- [ ] Review `Settings → Sync → Unavailable items`: entries show reason
      labels; Find match opens the preview dialog; relink keeps downloads.

## Metered networks and consent

- [ ] On cellular, Repair Library asks for consent (in-memory session);
      granting proceeds, cancel/retry keeps behavior within the session.
- [ ] Background sync on metered networks stays bounded (single probe).

## Android Auto

- [ ] Cold-start gate passes: `./tool/android_auto_cold_start_diagnostics.sh`
      (phone emulator; asserts service init < 10 s and the four root tabs).
- [ ] If a head unit / DHU is available: browse Liked albums, play,
      shuffle-liked; confirmed-missing items without local copies do not
      appear in shuffle.

## Recording results

Append a short results block to `Fix_Stale_Cache_Execution_Plan.md` Stage 12
with device/Android version, pass/fail per section, and any diagnostics
exports. Android remains "user-pending" in the plan's acceptance until this
checklist is run.
