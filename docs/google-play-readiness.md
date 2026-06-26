# Google Play Readiness

This is the canonical checklist for making Navis Play-ready while keeping
Forgejo releases for desktop artifacts, tags, release notes, and optional
non-Android assets.

## Android Distribution

- Android has two release paths:
  - **Forgejo APK** (`tool/release.sh --targets=android`) ships in-app APK
    self-update (`NAVIS_SELF_UPDATE=true`, `REQUEST_INSTALL_PACKAGES`, and
    FileProvider in the `src/selfupdate` manifest overlay).
  - **Google Play AAB** (`tool/play_release.sh`) must stay Play-safe
    (`NAVIS_SELF_UPDATE=false`, no install permissions, no APK installer
    MethodChannel registration).
- Runtime install-source detection redirects Play-delivered installs to the
  Play Store listing even when a newer Forgejo release exists.
- Package name: `com.navis.app.navis`.
- Target SDK: 36.
- Release signing certificate SHA-256:
  `12:C6:41:1B:2A:9F:D3:0B:2B:B8:63:01:9D:63:08:5E:5F:36:A1:D2:09:A1:D1:F1:55:9D:70:95:50:E9:B0:C7`.
- `REQUEST_INSTALL_PACKAGES` must not be present in Play AAB builds (only in the
  optional `src/selfupdate` manifest overlay used by Forgejo APK builds).
- Play builds must not register the APK installer MethodChannel at runtime.
- Forgejo update checks run on Android and desktop; Play installs are redirected
  to the Play Store instead of downloading APKs.

## Signing Continuity

- Use the existing `navis-release.jks` as the Google Play app signing key.
- During first Play setup, choose the Play App Signing path that uploads or
  provides the existing signing key instead of letting Google generate a new
  app signing key.
- A separate upload key can be generated after app signing is configured.
- Validate migration:
  1. Install the latest Forgejo APK.
  2. Upload an internal-test AAB signed/configured with the existing key.
  3. Confirm the Play-delivered build updates over the Forgejo APK without
     uninstalling.
- If the existing keystore or password is unrecoverable, seamless migration is
  not possible; use a new package name or require uninstall/reinstall.

## External Scrobbling

- Subsonic/OpenSubsonic server scrobbling remains independent.
- Last.fm and ListenBrainz can be enabled independently.
- Last.fm requires a user API key, shared secret, browser auth token flow, and
  session key.
- ListenBrainz requires the user token from ListenBrainz settings.
- Shared secret, Last.fm session key, and ListenBrainz token are stored in
  secure storage; only non-secret status/enabled flags live in Drift.
- Queue entries capture resolved title, artist, album, and duration so external
  scrobbles can flush later without current library metadata.
- The v46 migration rebuilds `scrobble_queue` so upgraded installs use
  provider-aware uniqueness (`song_id`, `provider`, `submission`,
  `session_key`), allowing Subsonic, Last.fm, and ListenBrainz to queue the
  same listen independently.
- Invalid Last.fm sessions disable Last.fm scrobbling and mark Last.fm
  disconnected.
- Invalid ListenBrainz tokens disable ListenBrainz scrobbling and mark the
  token invalid until updated.
- Missing Subsonic API state must not block Last.fm or ListenBrainz queue
  flushing; Subsonic events remain queued until the Subsonic client is
  available again.
- Setup screens catch Last.fm/ListenBrainz credential and network failures and
  show redacted user-facing notices.

## Voyage Servers

- `NAVIS_VOYAGE_SERVERS` remains the build-time bundled default list.
- Users can add/delete custom Voyage servers in settings.
- Bundled and custom servers are merged in the selector.
- Bundled servers are selectable only.
- Custom server entries are non-sensitive Drift settings data.
- Custom server URLs are normalized and accepted only when the Voyage transport
  policy allows them.

## Play Console Work

- Create the Play app with package `com.navis.app.navis`; package names are
  permanent.
- Complete Play App Signing with the existing release key.
- Complete Data safety, privacy policy URL, content rating, target audience,
  app access instructions, and Android Auto/media review materials.
- Store listing must clearly mention the Subsonic/OpenSubsonic requirement.
- Re-check policy-sensitive permissions:
  - no `REQUEST_INSTALL_PACKAGES`
  - foreground services tied to media playback
  - `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` disclosure
  - Android Auto behavior within media app quality rules

## Automation

- `tool/play_release.sh` builds a signed release AAB and uploads it through the
  Google Play Developer Publishing API.
- Local-only configuration lives in `tool/release.env`:
  - `PLAY_SERVICE_ACCOUNT_JSON=/absolute/path/service-account.json`
  - optional `PLAY_PACKAGE_NAME=com.navis.app.navis`
- Defaults: `--play-track=internal`, `--play-status=draft`.
- `--dry-run` builds the signed AAB and exits before creating a Play edit.
- Track aliases accepted by the script:
  - `internal` -> `internal`
  - `closed` -> `alpha`
  - `open` -> `beta`
  - `production` -> `production`
- Staged rollout requires `--play-status=inProgress` plus
  `--play-user-fraction`, for example `--play-user-fraction=0.05`.
- Stable releases can use `--play-track=production --play-status=completed`
  after internal testing proves the setup.
- Play review and Managed Publishing can still delay public availability.

## Verification

- `flutter analyze`
- `flutter test`
- `flutter build appbundle --release`
- `tool/security_audit.sh`
- `tool/play_release.sh --dry-run`
- Check AAB signing certificate before internal release.
- Migration acceptance:
  - Upgrade a v45 database with queued scrobbles.
  - Confirm the queue allows one Subsonic, one Last.fm, and one ListenBrainz
    event for the same song/session.
- Manual acceptance:
  - Last.fm and ListenBrainz both scrobble when both are enabled.
  - Either external service can be disabled independently.
  - Offline scrobbles flush after reconnect.
  - Radio playback remains suppressed.
  - Play internal update works on a real device.
