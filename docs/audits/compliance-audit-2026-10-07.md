> Historical record: this audit prepared the brief closed-source period (2026-10-07 to 2026-10-13). Navis is GPL-3.0-or-later again; the licensing findings no longer apply.

# Navis compliance audit: legal, closed-source and privacy

- **Audited:** branch `dev` at `f145399e` (version `1.4.3+10403`), 2026-10-07.
- **Scope:** read-only. Nothing in the repository was changed except this file. No builds were run and no signing keys were used. Secret values are never printed. The owner's personal name and e-mail are written as `<owner>` / `<personal e-mail>`.
- **Not legal advice.** Every ❌ item, and every item marked "lawyer", is worth a lawyer's look.

Status key: ✅ OK · ⚠️ Needs attention · ❌ Problem · ❓ Can't tell

---

## 1. Summary

**Overall readiness: 🔴 Blocked.** Ready after fixes; none of the blockers is large.

### Top 5 issues

1. **GPL code ships inside the app** (L-2, L-3).
   - `colornames` 0.2.0 is GPL-3.0 and is compiled into `libapp.so` on every platform, for one `ColorNames.guess()` call.
   - The Windows `libmpv-2.dll` is a GPLv3+ build. It is the shinchiro build with FFmpeg `--enable-gpl`, x264, x265, rubberband and dvdnav.
   - A closed-source release cannot ship either one.
2. **The app's privacy behaviour does not match the public policy** (P-1 to P-6).
   - Release builds use a **Last.fm key bundled with Navis**, preferred over the user's own key.
   - **AutoEQ** (`api.github.com`, `raw.githubusercontent.com`), **server-linked artwork** (any host) and the **Deezer image CDN** are not in the policy.
   - **Radio stream playback bypasses the master switch.**
3. **The project still declares itself GPL-3.0** (L-1).
   - This covers `LICENSE`, the README, `AGENTS.md`, `third_party/navis_android_storage/LICENSE` (whose GPL text appears on the in-app licence page) and the release docs.
   - The repository is currently **public** (`private: false` from the anonymous Forgejo API).
   - The owner is the only human author, so relicensing future versions is possible (L-7).
4. **The owner's personal name ships in the binaries** (B-1, B-2), in three places:
   - the `forgejoOwner` constant in the update and repository URLs;
   - the Inno Setup `MyAppPublisher`, shown in Windows "Apps & features";
   - the local build path (`/home/<owner>/…`) compiled into `libapp.so` and a Linux plugin `.so`.
5. **Update and signing integrity** (D-2, D-4).
   - Downloaded updates have **no SHA-256 or host check**. The Windows installer is run `/SILENT` from whatever URL the API returns.
   - A release build **silently falls back to the debug key** when `android/key.properties` is missing.

### Must happen before the next public release (1.5.0)

1. Remove `colornames`, and switch Windows to an **LGPL** libmpv/FFmpeg build with the LGPL notice and a source offer (L-2, L-3, L-4).
2. Replace `LICENSE` with the Porthorion EULA, relicense `navis_android_storage`, and fix the GPL statements (L-1).
3. Bring the policy and the app into line on four points (P-1 to P-6). Either change the app, or update the website policy and bring it back to the website session:
   - the bundled Last.fm key;
   - AutoEQ/GitHub;
   - server-linked artwork and the Deezer CDN;
   - the radio exception to the master switch.
4. Ship the R2 manifest update checker in 1.5.0. It should pin `https://downloads.porthorion.com/`, verify SHA-256 and link to navis.porthorion.com. Keep the Forgejo releases endpoint anonymously readable until 1.4.x users have moved (D-1, D-2). Per the owner, 1.5.0 is delivered through the existing Forgejo path, and every later update comes from R2.
5. Remove `<owner>` from shipped strings, set the publisher to Porthorion, and build releases from a neutral path (B-1, B-2).
6. Make release builds fail without the real upload key (D-4).
7. Add in-app links to the Website, Privacy policy, EULA and Contact (G-1).
8. Register the missing licence notices (AutoEQ, libmpv/FFmpeg, mimalloc, Rust crates) and add `applicationLegalese: '© 2026 Porthorion'` (L-6).

### Already in good shape

- **No analytics, crash reporting or ad SDKs** anywhere in `pubspec.lock`, Gradle or native code.
- **External calls go through one guarded client.** Every external call goes through `createExternalDio` plus `IntegrationGuardInterceptor`, with a master switch and per-service switches.
- **Logging.** The logger is silent in release builds, credentials are redacted, there are no log files, and the diagnostics server exists only in profile builds and is bound to localhost with a bearer token.
- **Secrets storage.**
  - The ListenBrainz token and the server password are in platform secure storage.
  - There is no plaintext fallback.
  - No developer infrastructure credentials have ever been committed.
- **Last.fm does not scrobble.** The app makes only three read calls.
- **Android permissions are minimal.** Cleartext traffic is limited to localhost, and no Play SDKs are used.
- **The licence page exists.** It is reached through Settings › About › Open-source licenses.

---

## Remediation status (updated 2026-10-07, branch `compliance-fixes`)

Fixes for every non-infrastructure finding are on the `compliance-fixes` branch (26 commits on top of `dev`). The tables in section 2 below show the **original** audit result; this table shows where each finding stands now.

Status key: ✅ fixed on the branch · 🧭 deferred (infrastructure or a product decision) · 👤 needs an owner action

### Licensing and secrets

| ID | Now | How |
|---|---|---|
| L-1 | ✅ | `LICENSE` is now a Porthorion proprietary notice that points to the EULA, and earlier GPL releases keep their licence. The same notice replaces the GPL text in `navis_android_storage`. README, AGENTS and the release docs are updated (`35d03969`). |
| L-2 | ✅ | `colornames` is removed. Colour names now come from an own table generated from meodai/color-names (MIT, v14.51.0) and matched by Lab ΔE (`b1409798`). |
| L-3 | ✅ | Windows uses zhongfly's LGPL libmpv: mpv `-Dgpl=false`, FFmpeg built without `--enable-gpl`. It is mirrored in the navis-third-party release `libmpv-windows-x86_64-lgpl-20261006` together with the mpv and FFmpeg sources, and verified by SHA-256, with fallback URLs. The VM smoke test loaded the DLL and played audio through the biquad+volume chain to EOF (`35a84d87`). |
| L-4 | ✅ | Linux bundles its own LGPL `libmpv.so.2`, built by `tool/libmpv/` (Docker, Ubuntu 22.04). It is mirrored in the release `libmpv-linux-x86_64-lgpl-20261007` with every source archive. The app loads it from `bundle/lib`, which a runtime gate confirms (`ae2890cd`). |
| L-5 | ✅ | libmpv stays a separate, replaceable shared library. The LGPL-2.1 text and a notice with the source offer are on the licence page. |
| L-6 | ✅ | The licence page now lists AutoEq, color-names, mimalloc (Linux), the Rust crates in the Windows SMTC DLL, libmpv/FFmpeg (LGPL) and `© 2026 Porthorion` (`ea65a758`, `7ba93fdc`). |
| L-7, L-8, L-10 | ✅ | No change was needed. |
| L-9 | ✅ | The Navi glyph is now original artwork, and its provenance is recorded (`a4d94b4c`). |
| S-1 | 👤 | The encrypted keystore is still in git history. Confirm the passphrase strength, make the repo private, and keep the backup out of the repo. |
| S-4 | ✅ | The bundled Last.fm key was kept, by the owner's decision. It is now disclosed in the app and must be disclosed in the policy (website handoff). |
| S-5 | ✅ | `.gitignore` gaps closed (`2f171673`). |

### Privacy

| ID | Now | How |
|---|---|---|
| P-1 to P-4 | ✅ in app / 👤 policy | The Integrations and Privacy copy now discloses the bundled Last.fm key, Instant Radio and top songs, both AutoEQ GitHub hosts, Deezer's image servers and server-linked images (`e70ba39b`). The website policy must say the same. |
| P-5 | ✅ | With Online services off, stations outside the user's server are refused without being contacted, and a notice explains why. Verified at runtime (`e8b1e077`, `b62c15f4`). |
| P-6, D-1, D-2 | 🧭 | Updater move to R2 (planned for 1.5.0): host pin, SHA-256 check, new manual links. |
| P-7 | ✅ | The runtime gate covers radio. The guard was already enforced for every other client. |
| P-8 | ✅ | Defaults stay on. "Skip setup" still shows the Integrations step, and that step now lists all eight services (`b461155c`). |
| P-10 | ✅ | The desktop database moves from Documents into the application-support folder, with a safe rollback if the move fails (`67079fed`). The diagnostics tools follow the move (`1659ecca`). |
| P-11 | ✅ | Android backup and device transfer are disabled. A `mailto` query was added for the Contact link (`26f2c487`). |
| P-12 | ✅ | Failed ListenBrainz token deletes now raise an error. Signing out of the server also disconnects ListenBrainz (`fe189b81`). |
| P-13 | ✅ | `api_key` is redacted (`b80e0b8a`). |
| P-15 | 🧭 | Needs a product decision, because a caller check risks breaking Android Auto and other clients. For now, mention it in the policy. |

### Third-party terms and distribution

| ID | Now | How |
|---|---|---|
| T-1, T-2 | ✅ | "From Deezer" and "From Last.fm" credits appear on artist sections, New Releases and top songs. Last.fm songs link to the artist on Last.fm, and fan counts read "on Deezer" (`08f37b39`). Last.fm `getsimilar` responses are cached for 24 h (`4abdca6c`). The non-commercial questions still need a lawyer. |
| T-3, T-4, T-5 | ✅ | The User-Agent is now `Navis/<ver> (+https://navis.porthorion.com; support@porthorion.com)` on every external client (`7e9d5ab2`). LRCLIB honours Retry-After (`25776e5f`). ListenBrainz rate-limit headers are respected (`26ee2b61`). |
| D-3 | 🧭 | Play remnants are left dormant. |
| D-4 | ✅ | A release build now fails without `key.properties`, unless an explicit local opt-in is set, and `release.sh` refuses to run without it (`2f171673`). |
| D-7 | 🧭 | AppStream and `.deb` changes are deferred. |

### Branding and in-app legal

| ID | Now | How |
|---|---|---|
| B-1 | 🧭 | The installer publisher is fixed (`30dfb477`). The `forgejoOwner` constant goes with the updater, and the build path with the release environment. |
| B-2 | ✅ | `Runner.rc`, `AppInfo.xcconfig`, the Inno installer and the deb now name Porthorion (`30dfb477`). |
| B-4 | ✅ / 🧭 | The Octo-Fiesta strings are removed. The Qobuz tool stays (repo-only). |
| B-5 | 👤 | Going private resolves this. |
| G-1 | ✅ | About links to the website, privacy policy, terms and support, and the Privacy page links to the full policy (`6075038d`). |
| G-2 | ✅ | See P-1 to P-4. |
| G-3 | ✅ | Old changelog entries reworded (`84c885ef`). |

### Owner actions still open

1. Copy both libmpv archives to R2 at `https://downloads.porthorion.com/navis/third-party/<file name>`. They are the build fallback.
2. Run a full Windows app check after logging in at the VM console: install, play, check the EQ, and check the publisher in Apps & features.
3. Do a real-server check of the Deezer and Last.fm credits.
4. Update the website privacy policy using the handoff list.
5. Confirm the S-1 keystore passphrase, then make the repo private, keeping the Forgejo releases endpoint public until 1.4.x users have upgraded.

---

## 2. Findings table

Effort: S < ½ day · M ≈ 1–3 days · L > 3 days

### Licensing (L)

| ID | Status | Title | Evidence | Fix | Effort |
|---|---|---|---|---|---|
| L-1 | ❌ | Project still declared GPL-3.0 | `LICENSE` (GPL-3.0 text; `<owner>` at :212,:224); `README.md:205-207`; `AGENTS.md:3`; `docs/release/release-windows.md:25` ("It is GPL, like Navis"); `third_party/navis_android_storage/LICENSE` (GPL-3.0, own code; shown in the in-app NOTICES); `tool/release.sh:667` deb `Homepage:` points at the public repo. `pubspec.yaml` is fine: `publish_to: 'none'`, no license/repository/homepage keys. No SPDX or GPL headers in sources. | Replace `LICENSE` with "Copyright © 2026 Porthorion. All rights reserved." plus the EULA. Relicense or remove `navis_android_storage/LICENSE`. Fix the README, AGENTS and docs lines. Add a copyright file to the `.deb`. Releases already shipped stay GPL for the people who received them, as the EULA says. | S |
| L-2 | ❌ | `colornames` 0.2.0 is GPL-3.0 and is a direct runtime dependency | `~/.pub-cache/hosted/pub.dev/colornames-0.2.0/LICENSE` ("GNU GENERAL PUBLIC LICENSE Version 3"); `pubspec.yaml:20`; one use at `lib/src/features/settings/presentation/appearance_settings_screen.dart:5,998`. Missed by the earlier audit (`resolved-licenses.json:405`, a removed raw dump retained in Git history). | Drop the package. Replace the label with the hex value or an own nearest-colour table built from a permissive dataset (e.g. meodai/color-names, MIT). | S |
| L-3 | ❌ | Windows `libmpv-2.dll` is a GPLv3+ build | `third_party/media_kit_libs_windows_audio/windows/CMakeLists.txt:61-75` pins `mpv-dev-x86_64-20261001-git-3186d369f9.7z` (shinchiro), mirrored at the navis-third-party release `libmpv-windows-x86_64-20261001`, whose `SOURCES.md` says "GPLv3 or later (mpv and FFmpeg built with GPL components)". The upstream recipe `packages/ffmpeg.cmake` has `--enable-gpl`, `--enable-version3`, `--enable-libx264`, `--enable-libx265`; mpv has the default `gpl=true`, rubberband and dvdnav. | Use an **LGPL** build: mpv `-Dgpl=false`, FFmpeg without `--enable-gpl`/x264/x265/rubberband/dvdnav. The EQ needs only the LGPL `volume`/`biquad` filters. Sources: media-kit's LGPL builds, zhongfly's LGPL variants, or your own build. Update `SOURCES.md`, `NAVIS.md` and `docs/release/release-windows.md`. Remove the stale pre-seed in `tool/remote_build_windows.sh:279-298`. | M |
| L-4 | ⚠️ | Linux relies on the system libmpv (usually a GPL build) | `media_kit` `DynamicLibrary.open` (`media_kit-1.2.6/.../native_library.dart:30`); deb `Depends: libmpv2 \| libmpv1` (`tool/release.sh:666`). The built bundle `lib/` contains no libmpv. `media_kit_libs_linux` statically links mimalloc (MIT, notice missing). | **Lawyer.** Dynamic loading of a GPL system library from a closed program is a grey area. The cleanest option is to bundle the same LGPL libmpv in `bundle/lib` as Windows, or to document the system-library position. Add the mimalloc notice either way. | M |
| L-5 | ⚠️ | LGPL obligations once L-3 and L-4 are fixed | None are bundled today. | Keep libmpv a separate replaceable `.dll`/`.so` (it already is). Ship the LGPL-2.1 text and the mpv/FFmpeg notices. Publish the exact source and configure flags in the navis-third-party release. Make sure the EULA's no-reverse-engineering clause allows what LGPL §6 needs. | S |
| L-6 | ⚠️ | Licence page is incomplete | `showLicensePage` at `lib/src/features/settings/presentation/about_screen.dart:100-108`. Route Settings › About › "Open-source licenses" (`app_en.arb:1761-1762`) matches the website, apart from the US spelling. Only Inter OFL is added (`lib/main.dart:42-56`). **Missing:** AutoEq MIT (`assets/autoeq/LICENSE`, shipped but not registered), libmpv/FFmpeg, mimalloc, the Rust crates in the `navis_windows_smtc` DLL (73 crates, only 10 verified MIT/Apache), Media3 NOTICE. The GPL text of `navis_android_storage` is shown. No `applicationLegalese`. | Add `LicenseRegistry.addLicense` entries next to Inter. Generate the crate notice with `cargo about` on the Windows host. Pass `applicationLegalese: '© 2026 Porthorion'`. | S |
| L-7 | ✅ | Contributors | `git shortlog -sne --all`: four e-mail identities, all the owner's (one personal address, one porthorion.com address, one local hostname, one noreply). Co-authored-by trailers are AI tools only. The only merged PR (#19) is the owner's own `dev`→`main`. | None. The owner holds all copyright, so relicensing future versions is possible. | — |
| L-8 | ✅ | Vendored and copied code | `third_party/`: just_audio (MIT + Apache text), just_audio_platform_interface (MIT), just_audio_media_kit (Unlicense), media_kit_libs_windows_audio (MIT wrapper), navis_windows_smtc (MIT, from smtc_windows; cargokit MIT). Licences and change notes are kept. No "adapted from" or Stack Overflow code found. The EQ uses the published RBJ Cookbook formulas only. | None, other than L-1 for `navis_android_storage`. | — |
| L-9 | ⚠️ | Changelog glyph provenance | `assets/changelog/navi.svg` was "traced from the supplied 500 px PNG" (commit `348e9ffc`) for the 1.4 "Navi" release. The source is not recorded. If it depicts Nintendo's Navi, there is a copyright and trademark risk. | Record the origin and licence in `assets/changelog/README.md`, or redraw it. | S |
| L-10 | ✅ | Fonts and icons | Inter OFL 1.1 is bundled with `OFL.txt` and registered. App icons are the owner's own. No sounds or shaders. `lib/src/icon/Backup/**` is not in the pubspec assets and does not ship. | — | — |

### Secrets (S)

| ID | Status | Title | Evidence | Fix | Effort |
|---|---|---|---|---|---|
| S-1 | ⚠️ (❌ if the passphrase is weak) | Encrypted Android release keystore is in a **public** repo | `tool/secrets/navis-release.jks.enc` (openssl AES-256-CBC, PBKDF2 600k) plus `tool/secrets/README.md`, since `fa42158d` (2026-03-31). It is reachable from `main`, `dev` and the tags from v0.9.4. The passphrase is the `storePassword`. The repo is anonymously readable today. The same key signs the sideload APKs that the self-updater installs. | Confirm `storePassword` is about 20 or more random characters. If it isn't, treat the key as exposed: rotate it with APK Signature Scheme v3 rotation (or a Play upload-key reset if Play is used). Keep the backup outside the repo from now on. Deleting the file does not remove it from history. Make the repo private, or rewrite history before making it private if the key matters. Reconcile with `docs/release/release-secrets.md` ("never committed"). | S–M |
| S-2 | ✅ | No plaintext secrets in the tree or history | Manual `git grep` and `git log -p --all -G/-S` over 1,300 commits and 88 tags. The only hits are placeholders (`android/key.properties.example:16-17`), fixture credentials against 127.0.0.1, `example.invalid` URLs and fake MBIDs. No AKIA, ghp_, github_pat_, glpat-, xox, sk-, private-key blocks, Cloudflare or R2. `FORGEJO_TOKEN` appears only as placeholders or `${{ secrets.* }}`. gitleaks and trufflehog are **not installed**; run one before going private. | Optional: `gitleaks detect --redact`. | — |
| S-3 | ✅ | No infrastructure credentials compiled into the app | `fromEnvironment` defines cover only diagnostics, the update channel, self-update, app name/ID and the Last.fm pair. No R2, Cloudflare, GitHub or Forgejo tokens. The update check is an anonymous `GET` (`lib/src/features/settings/data/update_repository.dart:57-67`). | — | — |
| S-4 | ⚠️ | Last.fm key bundled into release builds | `lib/src/utils/constants.dart:56-83` holds the masked define pair, injected by `tool/lib/lastfm_key_defines.sh` and required by `tool/release.sh:165-168` for Android. A Last.fm API key is a client identifier and can be extracted. The secret is not bundled. Never committed. | Acceptable as a credential. But see P-1: it contradicts the policy, and it makes Porthorion the Last.fm API account holder (T-2). | — |
| S-5 | ⚠️ | `.gitignore` gaps | Ignored: `key.properties`, `*.jks`, `android/**/*.keystore`, `tool/release.env`, `build/`. **Not** ignored: top-level `*.keystore`, `*.p12`, `*.pfx`, `*.p8`, `.env`, `google-services.json`, `credentials.json`, `*service-account*.json`. | Add them. | S |

### Privacy (P)

| ID | Status | Title | Evidence | Fix | Effort |
|---|---|---|---|---|---|
| P-1 | ❌ | Last.fm uses a **Navis key bundled with the app**, not "the user's own key", and does more than Same Vibes | `lastFmApiKeyProvider` prefers the build-time key (`lib/src/providers/app_providers.dart:643-670`). The UI says "Key included with this build" (`app_en.arb:803`). Last.fm methods: `chart.getTopArtists` (key check), `track.getsimilar`, `artist.getTopTracks` (`lib/src/api/lastfm_api_client.dart:108,199,381`). Used for Same Vibes, **Instant Radio** and **artist top songs when Deezer has none** (`app_en.arb:772-777`). ✅ No `track.scrobble`, `updateNowPlaying`, `auth.*` or `api_sig`. | Either update the policy ("a Navis API key included with the app, or your own; for Same Vibes, Instant Radio and artist top songs"), or stop bundling the key. The policy's "Navis does not scrobble to Last.fm" is correct. | S |
| P-2 | ❌ | AutoEQ talks to GitHub, which the policy does not mention | `lib/src/features/equalizer/data/autoeq_catalogue.dart:195,204,234` call `api.github.com` (commits) and `raw.githubusercontent.com` (index and profiles). The trigger is user-initiated (`eq_import_dialogs.dart:419`). It is gated by the master switch, the AutoEQ switch and its feature switch. The Integrations page shows only `raw.githubusercontent.com` (`integration_feature.dart:54`). | Add AutoEQ to the policy. Add `api.github.com` to the in-app host label. | S |
| P-3 | ❌ | Server-linked artwork loads from any host and is not in the policy | `integration_artwork.dart:30-39`, `cover_art_cache_manager.dart:551-600`. The "Linked images" switch is on by default; it re-checks the switches on every redirect. Includes ListenBrainz playlist covers (e.g. coverartarchive.org, `listenbrainz_playlist_artwork.dart:24-38`). | Add "images your server links to (any host)" to the policy. The in-app text (`app_en.arb:759`) already says it. | S |
| P-4 | ⚠️ | Deezer image CDN not named | `*.dzcdn.net` / `*.deezer.com` image GETs for artist photos and covers (`integration_artwork.dart:27-29`). No cookies; default Dart User-Agent. | Name "Deezer's image servers" next to `api.deezer.com` in the policy. | S |
| P-5 | ❌ | Radio stream playback ignores the master switch | `playRadioStream` in `lib/src/features/player/data/navis_audio_handler.dart:9296-9346` has no policy check (`masterEnabled` is never referenced in the handler). The AzuraCast and ICY metadata *is* gated (`app_providers.dart:1182-1192`). The in-app text "Off: Navis only talks to your server" (`app_en.arb:713`) is therefore inaccurate while a station plays. | Block or confirm `playRadioStream` when `!policy.masterEnabled` and the host differs from the server's. Or write the exception into the policy ("…except radio stations you choose to play"). | S |
| P-6 | ⚠️ | Update check sends different data to a different host | **Planned transition, not a blocker.** 1.4.x: `GET https://git.porthorion.com/api/v1/repos/<owner>/Navis/releases` (`constants.dart:13-26`) with no query and no extra headers; default `Dart/x (dart:io)` User-Agent; **neither version nor channel is sent** (filtered on the client, `update_repository.dart:51-55,74-79`); no install or device ID (`update_check_store.dart` stores only a timestamp). The Integrations host is `git.porthorion.com` (`integration_feature.dart:48`; `app_en.arb:708,751`). Per the owner, the step to 1.5.0 uses this path and later updates use R2. | 1.5.0: the R2 manifest checker on `downloads.porthorion.com`. Update `integration_feature.dart:48` and `app_en.arb:708,751`. Make the policy's "version and channel may be included" match what the new request actually sends. | M |
| P-7 | ⚠️ | Master switch otherwise works; add a runtime check | `IntegrationGuardInterceptor.onRequest` (`integration_guard_interceptor.dart:57-80`). Every external Dio comes from `externalDioFactoryProvider`. The policy is `denyAll` while settings load (`app_providers.dart:849-851`). User-initiated calls (key or token checks, Check now, AutoEQ, update download) skip only the per-service switch, not the master switch. Can only be fully confirmed at runtime. | **Manual test.** Turn the master switch off, then open Home, an artist, lyrics, About, the EQ and a radio station. Expect only the server host, plus radio stream hosts until P-5 is fixed. Ways to watch: profile build `GET /v1/diagnostics/integrations`, where only `blocked` outcomes should appear; Android PCAPdroid (SNI per app) or `adb shell dumpsys netstats detail`; Linux `sudo tcpdump -n -i any port 53 or port 443` (Dart ignores `HTTPS_PROXY`); Windows Wireshark with `tls.handshake.extensions_server_name`. | S |
| P-8 | ⚠️ | Everything is on by default, and "Skip setup" bypasses the Integrations step | Defaults (`app_settings_table.dart:133-134,162,165-166,286-312`) are all **on**: master switch, Deezer (all 6 features), Last.fm (active wherever the key is bundled), LRCLIB, automatic update checks, AutoEQ, radio now-playing, linked images. ListenBrainz is on but inactive with no token. Onboarding shows Integrations as step 3 of 4 (`onboarding_screen.dart:54`), with no third-party calls before Home. **But:** "Skip setup" (`:224-247`) finishes with the defaults; the step lists only Deezer, Last.fm, ListenBrainz, LRCLIB and Updates (`:1017-1023`), not AutoEQ, radio or artwork; and upgrading users get the calls together with a notice card. | **Lawyer (GDPR).** These are lookups of public metadata, but opt-out defaults should be described in the policy. Smallest fix: make Skip land on the Integrations step, list every service there, and say in the policy that services are on by default. | S–M |
| P-9 | ✅ | Secret storage | Server password: flutter_secure_storage 11.2.0 (Android Keystore, libsecret, Windows Credential Manager/DPAPI), with a memory-only fallback and no plaintext (`secure_credential_store.dart:56-116`). Token+salt are made per request. **ListenBrainz token: secure storage** (`external_scrobble_credentials.dart:31-86`), matching the policy. The user's Last.fm key is plaintext in the Drift DB (`app_settings_table.dart:141-147`), which is fine for a public client ID and disclosed in-app. | — | — |
| P-10 | ⚠️ | Desktop database lives in the user's Documents folder | `getApplicationDocumentsDirectory()` (`navis_database.dart:215-219`) is `~/Documents` on Linux and `%USERPROFILE%\Documents` on Windows, which OneDrive often syncs. Server URL, username, play history and cached lyrics can leave the device. The file stays after uninstall. | Move it to `getApplicationSupportDirectory()` with a migration. | M |
| P-11 | ⚠️ | Android Auto Backup is on | No `allowBackup`, `fullBackupContent` or `dataExtractionRules` (`android/app/src/main/AndroidManifest.xml:26`; also absent from the merged manifest). The DB (server URL, username, history, custom Last.fm key) goes to Google Drive backup. Restored secure-storage entries break because the Keystore keys don't migrate. | Add `android:allowBackup="false"`, or exclusion rules for the DB and secure prefs. | S |
| P-12 | ⚠️ | Sign-out edge cases | ✅ ListenBrainz Disconnect deletes the token and username (`integrations_settings_screen.dart:474-500`). ✅ Server sign-out deletes the password (`server_config_repository.dart:112-150`). ⚠️ `_delete` swallows errors (`external_scrobble_credentials.dart:77-85`), so a failed delete looks like success. ⚠️ Server sign-out does **not** remove the ListenBrainz token (`sign_out_service.dart`). ❓ Queued ListenBrainz scrobbles may not be purged on Disconnect. | Rethrow or report delete failures. Decide whether a full sign-out also clears integrations, and word the policy to match. | S |
| P-13 | ✅ | Logs | `AppLogger` uses logger's `DevelopmentFilter` and is silent in release (`app_logger.dart:9-11`). Redaction of `u/t/s/p/apiKey` (`credential_redaction.dart:7,43-64`; `subsonic_logging_interceptor.dart:72-80`). The integration recorder drops query strings. No log files, no export. The diagnostics server needs `kProfileMode` plus `NAVIS_SYNC_DIAGNOSTICS`, binds to 127.0.0.1 and needs a 32-byte bearer token. Minor: Last.fm `api_key` is not on the redaction list (debug and profile builds only). | Add `api_key` to the redaction list. | S |
| P-14 | ✅ | Android permissions and network config | INTERNET, ACCESS_NETWORK_STATE, WAKE_LOCK, FOREGROUND_SERVICE(_MEDIA_PLAYBACK), POST_NOTIFICATIONS, VIBRATE, REQUEST_IGNORE_BATTERY_OPTIMIZATIONS; RECEIVE_BOOT_COMPLETED is merged in from WorkManager. `REQUEST_INSTALL_PACKAGES` only in the sideload flavour. No location, contacts, phone or broad storage. `usesCleartextTraffic="false"` with cleartext allowed only to localhost (`res/xml/network_security_config.xml`), so `http://` servers and radio streams fail on Android. That is a product choice; documented in `docs/development/troubleshooting.md:224`. `debuggable` is not set. | Optional: mention the battery-optimisation request in the policy. | — |
| P-15 | ⚠️ | Exported `MediaBrowserService` with no caller check | `AudioService` is exported (`AndroidManifest.xml:~70-84`), so any installed app can browse library titles. This is common for music apps. `NavisArtworkProvider` is read-only and validates keys. | Optional: check the caller in `onGetRoot`, or mention it next to the policy's Android Auto line. | M |
| P-16 | ✅ | Children | No age data and no child-targeted features. | — | — |

### Third-party terms (T)

Sources: [Deezer ToU](https://developers.deezer.com/termsofuse), [Deezer guidelines](https://developers.deezer.com/guidelines), [Last.fm API ToS](https://www.last.fm/api/tos), [Last.fm intro](https://www.last.fm/api/intro), [ListenBrainz API](https://listenbrainz.readthedocs.io/en/latest/users/api/index.html), [MetaBrainz tiers](https://metabrainz.org/supporters/account-type), [LRCLIB docs](https://lrclib.net/docs).

| ID | Status | Title | Evidence | Fix | Effort |
|---|---|---|---|---|---|
| T-1 | ⚠️ | **Deezer:** non-commercial only; attribution shown only on Trending | ToU §IV: "strictly limited for a non-commercial purpose", with no "moneys, incomes, revenues… directly or indirectly". Brand use must follow the Trademark Guidelines. No rate limit is published; the "~50 req/5 s" figure comes from third parties. The app limits itself to 5/s with 4 in flight and backs off on code 4 (`deezer_request_limiter.dart:31-34`). Cache 6 h–30 days (`deezer_cache.dart:27-34`). A credit is shown only on Trending (`library_tabs.dart:306`). Artist photos, fan counts, top songs, similar artists, missing albums and New Releases are uncredited. Keyless use with no developer account. | Add a small "Data from Deezer" line to the artist-page sections and New Releases. **Lawyer:** keyless use, and any Porthorion revenue (donations, paid tier) could make it "commercial". | S |
| T-2 | ⚠️ | **Last.fm:** non-commercial; credit required; public apps need written approval | ToS 3.1 non-commercial; 2.7 "powered by AudioScrobbler" and link back to `last.fm/music/<artist>`; public pages need prior written approval; 4.2.2 credit; 4.3.4 "suitable caching" per HTTP headers, 100 MB cap; intro page: "identifiable User-Agent". The app shows **no Last.fm credit** on Top Tracks, "This Is", listener counts or Same Vibes. Top tracks are cached for 24 h; similar tracks are not cached. 429 and error 29 are shown to the user. **Because of the bundled key (P-1), Porthorion is the API account holder.** | Add a "Last.fm" credit and a link to `https://www.last.fm/music/<artist>`. Cache `track.getsimilar` briefly. **Lawyer:** whether written approval is needed for a public app using Porthorion's key. | S |
| T-3 | ❌ | **ListenBrainz:** User-Agent must include contact information | "We require that all requests… include a valid User-Agent header, with enough information for us… to contact the application maintainers." Also "never make more than ONE call per second". The app sends `Navis/<ver>` (`lib/src/utils/constants.dart:10`), with no contact. The `X-RateLimit-*` headers are not read; the scrobble queue backs off from 15 s to 30 min. Free for non-commercial use; MetaBrainz expects "popular mobile apps" from companies with revenue to become paying supporters. | Change the User-Agent to `Navis/<ver> (https://navis.porthorion.com; support@porthorion.com)`. All clients already share the constant. Optionally honour `X-RateLimit-Remaining`. | S |
| T-4 | ❌ | **LRCLIB:** User-Agent must include a homepage or e-mail, and Retry-After must be honoured | Docs: User-Agent with "name, version, and a link to its homepage… or an email address". On 429, "Your client **must** honor [Retry-After]… may result in a temporary ban". The client handles only 404 (`lib/src/api/lrclib_client.dart:68`). The backfill keeps 250 ms gaps (fine; `download_service.dart:1606`). Attribution "Lyrics provided by LRCLIB" ✅ (`now_playing_lyrics.dart:28-32`). Lyrics cached 1 day, or 1 year for downloaded songs. | Use the same User-Agent fix. On 429/503, pause LRCLIB until Retry-After (reuse the `subsonic_retry_interceptor` parsing). **Lawyer:** cached lyrics are third-party copyrighted works. | S |
| T-5 | ✅ | **Radio** | No central terms. The station's own AzuraCast `/api/nowplaying` and ICY. No station directory (no radio-browser). Polls every 5 s, falling back to 30 s. Metadata requests use Dio's default User-Agent (`app_providers.dart:1190`). | Optional: pass `AppConstants.userAgent`. | S |
| T-6 | ✅ | **Subsonic/OpenSubsonic** | The user's own server. Handles 429 and Retry-After (`subsonic_retry_interceptor.dart:94,130`). Sends `Navis/<ver>`. | — | — |

### Distribution (D)

| ID | Status | Title | Evidence | Fix | Effort |
|---|---|---|---|---|---|
| D-1 | ⚠️ | Updates come from the Forgejo Releases API; making the repo private strands 1.4.x | `releasesApiUrl` (`constants.dart:25-26`). No GitHub API is used. "Download manually" and release-notes links open the Forgejo `html_url` (`update_repository.dart:142`, `update_dialog.dart:416,432,444`, `about_screen.dart:210`, `home_support_widgets.dart:166`). `tool/release.sh:864-897` publishes only to Forgejo: no R2 upload, manifest or SHA256SUMS. Per the owner, 1.5.0 still goes out this way and later updates use R2. | Before making the repo private, keep `/api/v1/repos/<owner>/Navis/releases` anonymously readable: a public releases-only repo at that path, or a reverse-proxy rule that returns compatible JSON. Keep it until 1.4.x installs have upgraded. In 1.5.0, point all manual links at `https://navis.porthorion.com`. | M |
| D-2 | ❌ | Downloaded updates are not verified | `update_service.dart:35-81` downloads from the response's `browser_download_url` (any host). `:185-202` checks only that the file exists and is at least 10 KB. Windows runs it with `/SILENT /CLOSEAPPLICATIONS` (`:227-233`). Linux extracts it and swaps it in (`:317-339`). Android is protected by the installer's same-signature rule. No Authenticode signing in `tool/`. | In the 1.5.0 R2 checker: accept only `https://downloads.porthorion.com/`, require a `sha256` per asset in the manifest, verify it before install or apply, and generate SHA256SUMS in `release.sh`. Consider Authenticode signing. | M |
| D-3 | ✅ | Google Play remnants are dormant | No in_app_review, in_app_update, Play Core, Billing or Integrity. Leftovers: the `play` flavour (`build.gradle.kts:80-85`), the store-installer redirect (`update_delivery_resolver.dart:7-36`), the Play URL (`constants.dart:51-54`), `updatePlayStore*` strings, `tool/play_release.sh` and `docs/platforms/google-play-readiness.md`. No fastlane or metadata directory. If a Play listing exists, its Data Safety form must match the policy, and Play-signed and sideload builds cannot update each other. | Remove them when convenient. They are harmless for sideload builds. | S |
| D-4 | ❌ | A release build silently falls back to the **debug key** | `android/app/build.gradle.kts:125-128`: `signingConfig = if (keyPropertiesFile.exists()) release else debug`. The signer check in `tool/release.sh:492` runs only `if [[ -f android/key.properties ]]`. The live keystore is under `android/app/` (gitignored, but `git clean -fdX` deletes it). The 1.4.2 sideload APK is correctly signed (not the debug certificate). | Throw a `GradleException` for release builds without `key.properties`, and make `release.sh` exit 1. Move the keystore out of the working tree. | S |
| D-5 | ✅ | Certificate subject | The 1.4.2 APK certificate DN has C/ST/L/O/OU/CN. O and CN mention Navis; ST and L are "Unknown"; C is a country code. No personal name; valid to 2053. The DN, including the country, is public. To check without printing key material: `keytool -printcert -jarfile app.apk \| grep -E 'Owner\|Issuer'` or `apksigner verify --print-certs app.apk \| grep DN`. | — | — |
| D-6 | ✅ | `applicationId` | `com.navis.app.navis` (`build.gradle.kts:65`). Reported only; do not change. | — | — |
| D-7 | ⚠️ | Version consistency | `pubspec.yaml:5` is `1.4.3+10403`. About uses `PackageInfo`. The latest changelog entry is 1.4.3 and still has no date (`changelog_data.dart:129`). `Runner.rc` follows the pubspec. **No Linux AppStream metainfo.** The `.deb` is still built although only `.tar.gz` is planned. | Date the entry at release. Optionally add metainfo and drop the `.deb`. | S |

### Branding (B)

| ID | Status | Title | Evidence | Fix | Effort |
|---|---|---|---|---|---|
| B-1 | ❌ | The owner's personal name is in shipped binaries | `lib/src/utils/constants.dart:16` (`forgejoOwner`), compiled into the URLs inside `libapp.so` (confirmed with `strings` on the APK and Linux `libapp.so`). `tool/windows/build_inno_installer.ps1:58` `MyAppPublisher "<owner>"`. `libapp.so` contains `file:///home/<owner>/Documents/forgejo_projects/Navis/.dart_tool/...`, and `liburl_launcher_linux_plugin.so` contains `/home/<owner>/…`; `--obfuscate` does not remove these. | Remove the Forgejo constants in 1.5.0, or use a neutral repo owner. Set the Inno publisher to `Porthorion` and add `AppPublisherURL`/`AppSupportURL`/`AppCopyright=© 2026 Porthorion`/`LicenseFile=` (EULA). Build releases from a neutral path (e.g. `/build/navis` or a CI user). | S–M |
| B-2 | ⚠️ | Publisher and copyright are not "Porthorion" | `windows/runner/Runner.rc:92,96`: `CompanyName "com.navis.app"`, `LegalCopyright "Copyright (C) 2026 com.navis.app…"`. Same in `macos/Runner/Configs/AppInfo.xcconfig:14`. The `.deb` Maintainer is the placeholder `Navis Team <noreply@example.com>` (`tool/release.sh:617`). About shows no publisher. Linux `.desktop`, Android `app_name` and ProductName are all "Navis" ✅. No `com.example`. | Use `Porthorion` and `© 2026 Porthorion`. Use `Porthorion <support@porthorion.com>` as the deb maintainer. Add `applicationLegalese`. | S |
| B-3 | ✅ | Third-party trademarks | Deezer, Last.fm, ListenBrainz, LRCLIB, Subsonic and Navidrome appear only as names describing compatibility or data sources. No logos bundled. No Spotify, YouTube or Apple Music. No piracy wording. | — | — |
| B-4 | ⚠️ | Sensitive repo-only material | `tool/qobuz_extract_credentials.py` extracts a Qobuz token from a browser session. "Octo-Fiesta" (a Deezer/Qobuz proxy) appears in arb `@description` metadata (`app_en.arb:1046,1116`) and in comments. Neither is user-visible. | Remove the Qobuz tool. Strip the arb descriptions before any wider sharing of the source. | S |
| B-5 | ⚠️ | Personal name in repo-only files and git metadata | `LICENSE:212,224`, `third_party/navis_android_storage/LICENSE`, `third_party/navis_windows_smtc/pubspec.yaml:4`, `AGENTS.md:141`, `docs/project/progress.md`, `docs/history/completed-plans/Dependency_Upgrade_Plan.md`, `tool/release.env.example:8`, git author metadata (including `<personal e-mail>`), and the repo path itself. | Matters only while the repo is public. Making it private solves it. | S |

### In-app legal surface (G)

| ID | Status | Title | Evidence | Fix | Effort |
|---|---|---|---|---|---|
| G-1 | ❌ | No links to the website, privacy policy, EULA or contact | No `navis.porthorion.com`, `/privacy/app`, `/eula`, `support@porthorion.com` or `mailto:` anywhere in `lib/` or l10n. About has Changelog, Open-source licenses, an in-app Privacy page (`app_en.arb:148-156,707-709`) and Integrations. | Add About tiles for Website, Privacy policy, EULA and Contact (`mailto:support@porthorion.com`). Link the policy from the Privacy page. Optionally show the EULA in onboarding and the Inno installer. | S |
| G-2 | ⚠️ | Integrations text vs policy | ✅ Deezer (`:727`, could add "album"). ✅ LRCLIB (`:745`). ✅ ListenBrainz (`:739`; Privacy page `:149-151` mentions secure storage and now-playing). ❌ Last.fm "Key included with this build" (`:803`) vs the policy's "your own key" (P-1). ❌ Updates host `git.porthorion.com` (`:751`) vs `downloads.porthorion.com` (P-6). ⚠️ AutoEQ: in-app lists raw.githubusercontent.com only, and the policy lists nothing (P-2). ⚠️ Linked artwork is in-app only (P-3). ⚠️ Master "Off: Navis only talks to your server" (`:713`) has the radio exception (P-5). ⚠️ ListenBrainz weekly-playlist reads (`:782-783`) are not in the policy. | Change the app and policy text together. The in-app privacy page is currently **more accurate** than the website, so it can serve as the source when the policy is updated. | S |
| G-3 | ⚠️ | Old in-app changelog entries contradict the policy | `lib/src/features/changelog/changelog_data.dart`: `:2298` (1.0.3) "External scrobbling now supports **Last.fm** and ListenBrainz"; `:2294` "prepared for **Google Play**, with Android self-updates removed"; `:2182,2186` "Forgejo/sideload…", "background **Forgejo** requests"; `:2206` "member.status **telemetry**" (retired Listen Together). No open-source, GPL or analytics claims. | Reword or trim these, or add a note that older entries describe retired behaviour. | S |

---

## 3. Dependency licence table

- **Method:** Every `pubspec.lock` entry (206 packages) was classified from its LICENSE file in `~/.pub-cache` or `third_party/`, and every non-permissive hit was checked by hand. "Shipped" means the package is in the `flutter pub deps --no-dev` closure (169 shipped, 37 build-only). Tree-shaking may remove unused code.
- **Summary:** 199 permissive (BSD-3 119, MIT 63, BSD-2 7, Apache-2.0 5, Apache+MIT 2, Unlicense 1, Flutter SDK 5), 2 weak copyleft (MPL-2.0: `dbus`, `nm`; unmodified, keep the notice), 2 strong copyleft (`colornames` ❌, `navis_android_storage` own code to relicense), 0 unknown.
- **Native libraries:**
  - **Android:** ✅ `libapp.so`, `libflutter.so`, `libsqlite3.so` (public domain) and `libdartjni.so` (BSD-3). Media3/ExoPlayer is Apache-2.0. No FFmpeg or libmpv.
  - **Windows:** ❌ `libmpv-2.dll` (GPLv3+, L-3). Also `sqlite3.x64.windows.dll` (public domain) and the Rust SMTC DLL (MIT; crate notices ❓).
  - **Linux:** ⚠️ no bundled libmpv; it uses the system `libmpv.so` (L-4). Also mimalloc (MIT, static) and `libsqlite3.so`.

| Group | Package | Version | Relation | Licence | How linked / bundled | Shipped | Verdict |
|---|---|---|---|---|---|---|---|
| strong copyleft | colornames | 0.2.0 | direct | GPL-3.0 | Dart AOT (libapp.so) | yes | **Problem** |
| permissive wrapper / GPL payload | media_kit_libs_windows_audio | 1.0.9+navis.1 | direct | MIT wrapper; bundles GPL libmpv | Downloads + bundles libmpv-2.dll (GPLv3+ shinchiro build) [vendored/path] | yes | **Problem** (payload) |
| strong copyleft | navis_android_storage | 0.1.0 | direct | GPL-3.0 (owner code) | Dart AOT + platform plugin code [vendored/path] | yes | Needs attention (relicense) |
| weak copyleft | dbus | 0.7.15 | direct | MPL-2.0 | Dart AOT (libapp.so) | yes | OK (keep notice; unmodified) |
| weak copyleft | nm | 0.5.0 | transitive | MPL-2.0 | Dart AOT (libapp.so) | yes | OK (keep notice; unmodified) |
| permissive | android_file_picker | 2.0.0 | direct | MIT | Dart AOT + platform plugin code | yes | OK |
| permissive | archive | 4.3.0 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | args | 2.7.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | async | 2.13.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | audio_service | 0.18.19 | direct | MIT | Dart AOT + platform plugin code | yes | OK |
| permissive | audio_service_platform_interface | 0.1.3 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | audio_service_web | 0.1.4 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | audio_session | 0.2.4 | direct | MIT | Dart AOT + platform plugin code | yes | OK |
| permissive | boolean_selector | 2.1.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | build_cli_annotations | 2.1.1 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | cached_network_image | 4.0.2 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | cached_network_image_platform_interface | 5.0.2 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | cached_network_image_web | 2.0.2 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | characters | 1.4.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | clock | 1.1.3 | transitive | Apache-2.0 | Dart AOT (libapp.so) | yes | OK |
| permissive | code_assets | 2.1.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | collection | 1.19.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | connectivity_plus | 7.3.1 | direct | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | connectivity_plus_platform_interface | 2.1.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | convert | 3.1.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | cross_file | 0.3.5+5 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | crypto | 3.0.7 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | cupertino_icons | 1.0.9 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | cupertino_ui | 1.1.1 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | dio | 5.11.1 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | dio_web_adapter | 2.2.2 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | drift | 2.35.0 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | drift_flutter | 0.3.1 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | fake_async | 1.3.3 | dev | Apache-2.0 | Dart AOT (libapp.so) | yes | OK |
| permissive | ffi | 2.2.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | ffi_leak_tracker | 0.1.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | file | 7.0.1 | dev | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | file_picker | 13.1.0 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | file_picker_darwin | 2.1.2 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | file_picker_linux | 2.0.0 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | file_picker_platform_interface | 4.0.0 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | file_picker_web | 4.0.0 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | fixnum | 1.1.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter | 0.0.0 | direct | SDK(Flutter BSD-3) | Flutter SDK | yes | OK |
| permissive | flutter_cache_manager | 3.4.5 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_local_notifications | 22.3.1 | direct | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | flutter_local_notifications_linux | 8.0.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_local_notifications_platform_interface | 12.2.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_local_notifications_web | 1.0.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_local_notifications_windows | 3.1.1 | transitive | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | flutter_localizations | 0.0.0 | direct | SDK(Flutter BSD-3) | Flutter SDK | yes | OK |
| permissive | flutter_markdown_plus | 1.0.12 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_riverpod | 3.4.3 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_rust_bridge | 2.13.0 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_secure_storage | 11.2.0 | direct | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | flutter_secure_storage_darwin | 0.4.3 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_secure_storage_linux | 3.0.3 | transitive | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | flutter_secure_storage_platform_interface | 2.1.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_secure_storage_web | 2.1.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_secure_storage_windows | 4.2.2 | transitive | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | flutter_svg | 2.3.0 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | flutter_test | 0.0.0 | dev | SDK(Flutter BSD-3) | Flutter SDK | yes | OK |
| permissive | flutter_web_plugins | 0.0.0 | transitive | SDK(Flutter BSD-3) | Flutter SDK | yes | OK |
| permissive | freezed_annotation | 3.1.0 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | glob | 2.2.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | go_router | 18.0.1 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | hooks | 2.2.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | http | 1.6.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | http_parser | 4.1.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | image | 4.10.1 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | intl | 0.20.3 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | jni | 1.0.3 | transitive | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | jni_flutter | 1.0.3 | transitive | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | jni_util | 1.0.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | js | 0.7.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | json_annotation | 4.12.0 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | just_audio | 0.10.6 | direct | MIT (+Apache-2.0 text for ExoPlayer) | Android: Media3/ExoPlayer AARs (Apache-2.0) [vendored/path] | yes | OK |
| permissive | just_audio_media_kit | 2.1.0 | direct | Unlicense (public domain) | Dart AOT (libapp.so) [vendored/path] | yes | OK |
| permissive | just_audio_platform_interface | 4.6.0 | override | MIT | Dart AOT (libapp.so) [vendored/path] | yes | OK |
| permissive | just_audio_web | 0.4.16 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | leak_tracker | 11.0.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | leak_tracker_flutter_testing | 3.0.10 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | leak_tracker_testing | 3.0.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | listen | 1.0.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | logger | 2.8.0 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | logging | 1.3.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | markdown | 7.3.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | matcher | 0.12.20 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | material_color_utilities | 0.13.0 | transitive | Apache-2.0 | Dart AOT (libapp.so) | yes | OK |
| permissive | material_ui | 1.4.0 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | media_kit | 1.2.6 | dev | MIT | Dart FFI -> dlopen libmpv | yes | OK |
| permissive | media_kit_libs_linux | 1.2.1 | direct | MIT | Plugin .so; dlopens SYSTEM libmpv; statically links mimalloc (MIT) | yes | Needs attention (system GPL libmpv, mimalloc notice) |
| permissive | media_kit_libs_macos_audio | 1.1.4 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | meta | 1.19.0 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | mime | 2.1.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | native_toolchain_c | 0.19.5 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | navis_windows_smtc | 1.1.0 | direct | MIT (smtc_windows) + Rust crates | Rust cdylib DLL (Windows) [vendored/path] | yes | OK (crate notices not in app) |
| permissive | objective_c | 9.6.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | octo_image | 2.1.1 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | package_config | 3.0.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | package_info_plus | 10.2.1 | direct | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | package_info_plus_platform_interface | 4.1.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | path | 1.9.1 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | path_parsing | 1.1.0 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | path_provider | 2.1.6 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | path_provider_android | 2.3.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | path_provider_foundation | 2.6.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | path_provider_linux | 2.2.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | path_provider_platform_interface | 2.1.3 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | path_provider_windows | 2.3.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | petitparser | 7.1.0 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | platform | 3.2.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | plugin_platform_interface | 2.1.8 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | posix | 6.5.2 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | process | 5.0.6 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | pub_semver | 2.2.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | record_use | 1.1.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | riverpod | 3.4.3 | dev | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | rxdart | 0.28.0 | direct | Apache-2.0 | Dart AOT (libapp.so) | yes | OK |
| permissive | safe_local_storage | 2.0.6 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | screen_retriever | 0.2.2 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | screen_retriever_linux | 0.2.2 | transitive | MIT | Dart AOT + platform plugin code | yes | OK |
| permissive | screen_retriever_macos | 0.2.2 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | screen_retriever_platform_interface | 0.2.2 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | screen_retriever_windows | 0.2.2 | transitive | MIT | Dart AOT + platform plugin code | yes | OK |
| permissive | scrollable_positioned_list | 0.3.8 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | sky_engine | 0.0.0 | transitive | SDK(Flutter BSD-3) | Flutter SDK | yes | OK |
| permissive | source_span | 1.10.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | sqflite | 2.4.4 | transitive | BSD-2-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | sqflite_android | 2.4.4 | transitive | BSD-2-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | sqflite_common | 2.5.13 | transitive | BSD-2-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | sqflite_darwin | 2.4.4 | transitive | BSD-2-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | sqflite_platform_interface | 2.4.2 | transitive | BSD-2-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | sqlcipher_flutter_libs | 0.7.0+eol | transitive | MIT (+Apache-2.0 text) | Dart AOT (libapp.so) | yes | OK |
| permissive | sqlite3 | 3.6.0 | direct | MIT | Native asset libsqlite3.so/.dll (SQLite public domain) | yes | OK |
| permissive | sqlite3_flutter_libs | 0.6.0+eol | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | stack_trace | 1.12.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | state_notifier | 1.0.0 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | stream_channel | 2.1.4 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | string_scanner | 1.4.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | synchronized | 3.4.2 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | term_glyph | 1.2.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | test_api | 0.7.12 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | timezone | 0.11.1 | transitive | BSD-2-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | typed_data | 1.4.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | universal_platform | 1.1.0 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | uri_parser | 3.0.2 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | url_launcher | 6.3.2 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | url_launcher_android | 6.3.33 | transitive | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | url_launcher_ios | 6.4.2 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | url_launcher_linux | 3.2.3 | transitive | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | url_launcher_macos | 3.2.6 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | url_launcher_platform_interface | 2.3.2 | dev | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | url_launcher_web | 2.4.3 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | url_launcher_windows | 3.1.6 | transitive | BSD-3-Clause | Dart AOT + platform plugin code | yes | OK |
| permissive | uuid | 4.6.0 | direct | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | vector_graphics | 1.2.3 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | vector_graphics_codec | 1.1.13 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | vector_graphics_compiler | 1.3.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | vector_math | 2.4.3 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | visibility_detector | 0.4.0+2 | direct | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | vm_service | 15.3.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | web | 1.1.1 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | win32 | 6.4.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | window_manager | 0.5.2 | direct | MIT | Dart AOT + platform plugin code | yes | OK |
| permissive | windows_file_picker | 2.0.0 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | xdg_directories | 1.1.0 | transitive | BSD-3-Clause | Dart AOT (libapp.so) | yes | OK |
| permissive | xml | 7.0.1 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | yaml | 3.1.4 | transitive | MIT | Dart AOT (libapp.so) | yes | OK |
| permissive | _fe_analyzer_shared | 108.0.0 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | analyzer | 14.4.0 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | analyzer_buffer | 0.3.4 | transitive (dev/build only) | MIT | not shipped | no | OK (not shipped) |
| permissive | build | 4.0.11 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | build_config | 1.3.3 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | build_daemon | 4.1.6 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | build_runner | 2.16.1 | dev | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | built_collection | 5.1.1 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | built_value | 8.13.0 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | charcode | 1.4.0 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | checked_yaml | 2.0.4 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | cli_util | 0.4.2 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | dart_style | 3.1.13 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | drift_dev | 2.35.0 | dev | MIT | not shipped | no | OK (not shipped) |
| permissive | flutter_launcher_icons | 0.14.4 | dev | MIT | not shipped | no | OK (not shipped) |
| permissive | flutter_lints | 3.0.2 | dev | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | freezed | 4.0.2 | dev | MIT | not shipped | no | OK (not shipped) |
| permissive | graphs | 2.3.2 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | http_multi_server | 3.2.2 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | io | 1.1.0 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | json_serializable | 6.14.1 | dev | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | lints | 3.0.0 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | mocktail | 1.0.5 | dev | MIT | not shipped | no | OK (not shipped) |
| permissive | pool | 1.5.3 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | pubspec_parse | 1.6.0 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | recase | 4.1.0 | transitive (dev/build only) | BSD-2-Clause | not shipped | no | OK (not shipped) |
| permissive | shelf | 1.4.2 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | shelf_web_socket | 3.0.0 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | source_gen | 4.3.0 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | source_helper | 1.3.13 | transitive (dev/build only) | Apache-2.0 | not shipped | no | OK (not shipped) |
| permissive | sqlparser | 0.45.0 | transitive (dev/build only) | MIT | not shipped | no | OK (not shipped) |
| permissive | stream_transform | 2.1.2 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | very_good_analysis | 11.0.0 | dev | MIT | not shipped | no | OK (not shipped) |
| permissive | watcher | 1.2.1 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | web_socket | 1.0.1 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | web_socket_channel | 3.0.3 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |
| permissive | yaml_edit | 2.2.4 | transitive (dev/build only) | BSD-3-Clause | not shipped | no | OK (not shipped) |

Rust crates in `third_party/navis_windows_smtc/rust/Cargo.lock` (73 crates, shipped as a Windows DLL): ❓. The top-level dependencies (`flutter_rust_bridge`, `windows`, `anyhow`) are MIT/Apache, and 10 of the crates are verified locally. Run `cargo about` or `cargo deny check licenses` on the Windows build host to confirm the rest.

---

## 4. Network inventory

The **switch** column lists every switch that must be on for the connection to happen. "Master" is the Online services switch. "Feature" is the per-feature switch inside the Integrations page.

| Host | What's sent | Trigger | Switch | In policy | Match |
|---|---|---|---|---|---|
| User's Subsonic/OpenSubsonic server | `u` plus token and salt (`t`/`s`) or `p=enc:`; `User-Agent: Navis/<ver>` | Everything | None (by design) | Yes | ✅ Yes |
| `api.deezer.com` | Search `q` (artist, album or track names), artist IDs, `chart/0/tracks`; `Navis/<ver>` | Artist pages, Home New Releases and Trending, playlist Trending | Master + Deezer + feature | Yes | ✅ Yes |
| `*.dzcdn.net` / `*.deezer.com` (images) | Image GET, no cookies, Dart default User-Agent | Artist photos, Deezer covers | Master + Deezer + feature | No | ⚠️ No (P-4) |
| `ws.audioscrobbler.com` | `api_key` (**bundled Navis key**, or the user's own), artist and track names; `chart.getTopArtists`, `track.getsimilar`, `artist.getTopTracks` | Same Vibes, Instant Radio, artist top songs fallback, key check | Master + Last.fm + feature + key | Partly | ❌ No (P-1) |
| `api.listenbrainz.org` | `Authorization: Token …`; `playing_now` and `single` listens (artist, track, release, duration, `listened_at`), likes, `metadata/lookup`, weekly-playlist reads | Playback, likes, Home weekly playlists, token check | Master + ListenBrainz + feature + valid token | Yes | ⚠️ Mostly (now-playing and playlist reads not mentioned) |
| Hosts in ListenBrainz playlist `image` (e.g. coverartarchive.org) | Image GET | Weekly playlist covers | Master + ListenBrainz + weekly playlists | No | ⚠️ No (P-3) |
| `lrclib.net` | `artist_name`, `track_name`, `album_name`, `duration`; `/api/search` | Lyrics | Master + LRCLIB + lyrics | Yes | ✅ Yes |
| Radio station stream host | Stream GET via the player | User plays a station | **None** | Yes | ❌ No (P-5: bypasses master) |
| Station AzuraCast `/api/nowplaying/<id>`, ICY | GET; Dio default User-Agent | While a station plays | Master + Radio + Now playing | Yes | ✅ Yes |
| `git.porthorion.com` | `GET /api/v1/repos/<owner>/Navis/releases`; no query, no ID; Dart default User-Agent | Home or About open (automatic, once per 24 h) or Check now | Master + Updates + Automatic | No (policy says downloads.porthorion.com) | ⚠️ No (P-6, planned for 1.5.0) |
| Release asset URL (`browser_download_url`, any host) | Download GET | User taps install | Master | No | ❌ No (D-2: no host pin or hash) |
| `api.github.com`, `raw.githubusercontent.com` | GET commits/master, README/INDEX, profile `.txt` | User refreshes or downloads in AutoEQ | Master + AutoEQ + feature | No | ❌ No (P-2) |
| Any host the server links (artist images, Last.fm CDN, …) | Image GET | Artist and album views | Master + Artwork + Linked images | No | ❌ No (P-3) |
| Browser-only links (musicbrainz.org, last.fm/api/accounts, listenbrainz.org/settings, Play Store, release page) | Nothing from the app; the system browser opens the link | User taps a link | — | n/a | ✅ OK |

None found: Firebase, Sentry, Crashlytics, analytics SDKs (Amplitude, PostHog, Bugsnag), `google_fonts`, Gravatar, Play Services, MusicBrainz API calls, or native-code HTTP on Windows, Linux or Android. AudioMuse is hard-disabled (`app_providers.dart:3041-3049`).

---

## 5. What was run

- **Read-only checks:** `git grep`, `git log -p --all -G/-S` across all branches and tags, `git shortlog -sne --all`, `flutter pub deps --no-dev`, reads of `~/.pub-cache` LICENSE files, `unzip -l` and `strings` on existing build outputs, a parse of the APK signing certificate (DN fields only), and an anonymous Forgejo API visibility check.
- **Web sources:** the third-party terms pages listed above, and the upstream shinchiro build recipe.
- **Not run:** builds, `./tool/check.sh`, the app itself, gitleaks or trufflehog (not installed).
- **Runtime confirmation still needed:** P-7 (master switch). See the manual test described in P-7.
