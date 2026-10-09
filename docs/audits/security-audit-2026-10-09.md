# Navis security audit

- **Audited:** branch `dev` at `f145399e`, 2026-10-09.
- **Scope:** the shipped app (release builds and what they do on users' devices), as a companion to `COMPLIANCE-AUDIT.md` (2026-10-07, not in the repo). Findings already listed there (D-2 update SHA-256, D-4 debug-key fallback, P-10, P-11, P-15, S-1 and S-5) are not repeated here.
- **Out of scope:** local development, testing and diagnostics (profile-build diagnostics server, dev/profile signing, release and remote-build tooling, build hosts). These are used locally and are intentionally lightly protected. Items the audit noticed there are listed under "Local tooling notes" for information only; they are not findings.
- **Method:** read-only review of three areas: network and credentials; filesystem, updater and native code; build and supply chain. Findings marked ✔ were confirmed again by hand, in the code or on disk.
- **Fix ownership:**
  - App-side items in the requested remediation scope are fixed on `fix/security-audit`; see the scoped status below.
  - The in-app updater items (H-2, H-3, M-6, M-10) touch files that `feat/r2-updates` is rewriting, so they are fixed there.

## Remediation status — 2026-10-09

| IDs | Status | Implemented change |
|---|---|---|
| H-1, L-9 | Fixed on fix/security-audit | One shared extension allowlist, hashed rolling/SAF identities, final root-containment checks, and an exception when permanent filename collisions exhaust 100 attempts. |
| M-4 | Fixed on fix/security-audit | Mutable browser links use the hosted HTTP(S) launcher; MusicBrainz path identifiers must be UUIDs. The file-manager helper remains a local directory action. Store links in the protected updater service are constants. |
| M-5, L-6 | Fixed on fix/security-audit | Radio requires hosted HTTP(S), stream URLs stay in handler memory rather than media-session extras, and only `/listen/` or `/hls/` stream shapes produce AzuraCast polling endpoints. |
| M-2 | Fixed on fix/security-audit | Code 41 is mapped explicitly and is the only legacy-fallback trigger. Wrong passwords and reported old versions never downgrade authentication. Remote HTTP legacy retries fail with a localized HTTPS requirement. |
| M-3 (redaction and storage) | Fixed on fix/security-audit | Request logs and free-text redaction strip URL user info. Drift stores only a credential-free server URL; user info uses its own key beside the server password in the existing secure store, with memory-only fallback. Loads migrate legacy rows once and active configs merge it back in memory for HTTP/media Basic authentication, including Android background sync. Both sign-out paths delete it. |
| L-11a | Fixed on fix/security-audit | System cover keys use HMAC-SHA256 over cover IDs, truncated to 32 lowercase hex characters, with a random persisted per-install secret loaded before media-service setup. Kotlin requires that exact key format and reads only v2 filenames, ignoring old guessable files. The independent rolling-cache and SAF SHA-1 identities are unchanged. |
| L-11b | Fixed on fix/security-audit | Wipe sign-out clears the ListenBrainz secure token, username and connection flags through the existing credential store and settings writer; keep-data sign-out retains them. Secure deletion errors are rethrown into teardown warning reporting. |
| Thin artwork (validation follow-up) | Fixed on fix/security-audit | Both palette callers check decoded dimensions before Material's 112px scaling can truncate an edge to zero. Extremely thin images retain default tint/theme seed, and decode/extraction failures are contained. |
| L-8 (AudioMuse, dormant) | Deferred | Secure API-key storage and guarded transport must be fixed before the feature is re-enabled. |
| M-1, L-1 (cover-art redirects) | Fixed on fix/security-audit | The shared cache manager strips credentials from all insertion URLs and URL keys; the HTTP service re-signs only the active server's exact cover endpoint at dispatch. Startup purges both old app-owned JSON/SQLite repositories and image directories before marking completion; both current repositories use v2 keys. Both sign-out modes clear shared and system covers. HTTPS→HTTP artwork redirects are refused. |
| M-7 | Fixed on fix/security-audit | Both external artwork decode edges are bounded, radio prewarm/display share the same decoded frame, and all artwork response bodies have a 20 MiB cap. |

### Independent review follow-up

| Gap | Status | Change |
|---|---|---|
| A | Fixed | AudioService artwork signs the active server's cover endpoint with current credentials after queue admission; external paths and hosts remain unsigned. |
| B | Fixed | The same startup migration purges both legacy repositories. AudioService shares its Riverpod-owned manager with session teardown and all cover-clear actions. |
| C | Fixed | Cleanup deletes both old image directories before writing the v3 marker, including after a prior v2 cleanup. Storage accounting and clear covers include both current directories. |
| D | Fixed | External artwork and radio prewarm use one provider wrapped by `boundedDecode` with a 1024×1024 fit bound. A decoded-frame regression checks tall/wide images and immediate reuse after prewarm. The artist detail golden is updated for the Image layout. |
| E | Fixed | A shared 20 MiB response cap rejects oversized Content-Length and aborts cumulative streamed overflow, including chunked, redirected and discarded bodies. Rejections record an error outcome and release the download slot. |

**Open owner decision:** Existing accounts with stored `useLegacyAuth=true`
over non-loopback `http` still send `p=enc:` on reconnect, media requests and
Android background sync (`app_providers.dart`, `subsonicApiProvider`, and
`android_background_sync_entrypoint.dart`, client construction). The probe guard
covers only new logins; it does not migrate or block those stored accounts.
The owner must decide how to handle existing insecure legacy configurations.

**Thin-artwork follow-up (fixed):** Material's async palette listener can throw
`Invalid image dimensions` outside its returned future when its 112px scaling
truncates a short edge to zero. The shared app-side `artworkColorScheme` guard
checks the decoded dimensions before invoking that listener, retains the default
tint/theme seed for unsafe aspect ratios, and catches decode/extraction failures.
Both 32×4096 and 4096×32 regression images now exercise full Now Playing prewarm
and dynamic accent fallback; 128×4096 and 4096×128 still extract a palette. All
four verify bounded decode and immediate display reuse, and malformed-image
coverage verifies a contained decode failure.

**Follow-up validation:** All selected final runs passed: cover cache migration,
response sizes, system-artwork signing, playback artwork, sign-out, cache settings,
library-cache reset, external-artwork policy/display/decode, Now Playing transition
and adaptive tests, artist Deezer detail, and radio screen tests. Every test run
used `flutter test --concurrency=4 --timeout 60s <files>`. Only the test named
“phone artist page with Deezer header and sections” used `--update-goldens`,
updating `test/src/features/library/presentation/goldens/artist_detail_phone_deezer.png`;
its old/new rendered images were inspected. File-level `dart analyze` ran before
each commit, with no errors or warnings; remaining infos predate these changes.
Initial runs exposed test/implementation regressions which were corrected and
rerun, including the palette follow-up now fixed above. App/runtime/native validation,
emulators, VMs, `tool/check.sh`, and the full suite were skipped under the host
rules. No model/schema change required generation.

**Deferred:** L-8 remains deferred while AudioMuse is dormant; fix its API-key
storage and guarded transport before re-enabling it. The legacy-auth owner
decision above remains open. Updater/tooling files remain with their assigned
branch. Cleanup is confined to app-owned repository files; archived or Trash
copies outside app storage are not modified.

**Final remediation validation:** The task-specific runs passed: 27 tests for
server-config storage/migration, sign-out and Android background sync; 18 for
playback artwork and Android projection/HMAC keys; 11 for sign-out and external
scrobble credentials; and 12 for artwork decode, dynamic accent and Now Playing
transitions. Counts overlap across task runs. The final combined focused run
passed 63 tests. All invocations used
`flutter test --concurrency=4 --timeout 60s <files>`. File-level `dart analyze`
ran before every implementation commit and again before the audit commit;
there were no errors or warnings, only existing infos (three changelog quoting
infos and two discarded-future infos in playback artwork tests). Initial runs
exposed formatting/compilation and fixture mismatches; these were corrected and
the affected tests rerun. No database schema/model change required generation.

The coordinator must validate a legacy `user:pass@` account through migration,
clean restart, API requests, mpv/mobile streaming, and Android headless sync;
check that the DB URL is credential-free and both sign-out modes delete the
secure user-info key. Verify memory-only operation when secure storage is
unavailable. On Android, build the changed Kotlin provider and verify new content
URIs open from Android Auto/media controls after restart, guessed/old IDs cannot
open covers (including old IDs consisting of 32 hex characters), and permanent
download artwork remains available offline. Verify wipe sign-out removes the
ListenBrainz token/username while keep-data sign-out retains them, and a failed
secure deletion produces a cleanup warning. Exercise both thin artwork
orientations with Now Playing and dynamic accents enabled, inspect the app-owned
screenshot, and confirm normal artwork still produces tints.

**Validation:** focused tests passed for file utilities, permanent paths,
playback-source resolution (including MIME and requested-format traversal), URL
launching, radio handler/metadata, connection probing/login, credential logging,
cover-cache persistence and queued authentication, both sign-out modes, playback
artwork, and the affected cache callers. Every Flutter test invocation used
`--concurrency=4 --timeout 60s`. File-level Dart analysis ran before implementation
commits; its remaining findings are existing infos, with no errors or warnings.
Localization output was regenerated with `flutter gen-l10n`; no model or schema
change required generation.

Per the host rules, no app, emulator, or VM was launched, and `tool/check.sh` was
not run. The coordinator must run that gate and validate runtime downloads/cache
containment, allowed/blocked links, radio playback and metadata, code-41 login
behavior, cover re-fetching with current authentication, legacy-repository
cleanup (JSON and SQLite targets), and keep-data sign-out/re-login. Disposable
cover art is refetched after the repository bump; durable download artwork is
preserved.

## Findings

### High
| ID | Finding | Evidence | Fix (reuse) |
|---|---|---|---|
| H-1 ✔ | **Path traversal from server data.** A malicious server sets `suffix` or `id` to `x/../../.config/autostart/evil.desktop`, and playing the song writes attacker bytes anywhere the user can write. On desktop that means code execution at next login. | `permanent_download_path_resolver.dart:187` `_normalizeExtension` (raw); `playback_source_resolver.dart:413` (raw `song.id` + ext), `:570-585`; `download_service.dart:2201` | Allowlist the extension (`^[A-Za-z0-9]{1,10}$`, else `bin`) in one shared helper used by both resolvers. Use the existing hashed rolling-cache and SAF identities independently of artwork keys. Add a final `p.isWithin` guard (`_isWithinOrSame` in `utils/file_utils.dart`). |
| H-2 ✔ | **Linux `.deb` update leads to root code execution.** The download goes to the shared `/tmp/navis_updates`, which is reused if it already exists, and then `pkexec dpkg -i` runs on it. Another local user can swap the file or plant a symlink. | `update_service.dart:45-52,296` | Use `Directory.systemTemp.createTemp('navis_update_')` (mode 0700, random name; this pattern is already used in `permanent_download_import_service.dart:774`). |
| H-3 | **Linux portable update stages in a predictable `/tmp` path.** The staging dir `/tmp/navis_update_staging_<millis>` and the script are attacker-raceable, so another user can replace the binary before the move. | `update_service.dart:319-322`, `update_scripts.dart:65-68,120` | Use the same private `createTemp` dir for staging and the script. |

### Medium
| ID | Finding | Evidence | Fix (reuse) |
|---|---|---|---|
| M-1 ✔ | **Cover-art cache stores signed URLs** (`u/t/s`, or the `p=enc:` password with legacy auth) in a mode-644 JSON file. There are 1516 tokens on this machine and about 150 old copies in the Trash, and they survive "sign out, keep data". | `cover_art_cache_manager.dart:1009-1020`, `cover_art_image.dart:522`, `sign_out_service.dart:212` | Give the cache only unsigned URLs or keys and have `CoverArtHttpFileService.get()` sign them. Purge the old cache files once, and clear the cache on every sign-out. |
| M-2 ✔ | **Login silently downgrades to the reversible password.** It retries with `p=enc:` on *any* auth error (including a wrong password), or when the ping reports a version below 1.13, which a fake server can claim. | `server_connection_service.dart:44-61,81-96,129-142` | Fall back only on Subsonic error code 41. Never over non-loopback `http://`. Ask the user before turning legacy auth on. |
| M-3 | **`user:pass@` in the server URL** is saved in the DB, sent on every URL and logged at WARNING in release. | `server_config_repository.dart:240-246`, `subsonic_logging_interceptor.dart:72-80`, `credential_redaction.dart` | Keep user info beside the server password under its own secure-store key, migrate plaintext rows on load, and merge it into active in-memory URLs to preserve HTTP/media Basic auth. Strip `userInfo` in both redaction helpers. |
| M-4 | **Server-supplied URLs are opened with no scheme allowlist.** `lastFmUrl` and the release `htmlUrl` reach Windows ShellExecute and xdg-open (`file://`, `search-ms:`, `.desktop`). | `album_detail_screen.dart:2060`, `update_dialog.dart:415,431,443`, `integrations_settings_screen.dart:502`, `home_support_widgets.dart:165` | Add one `launchExternalHttpUrl` helper built on `isHostedHttpUri` (`integration_artwork.dart:100`) and route every `launchUrl` call through it. Check that `musicBrainzId` is a UUID. |
| M-5 | **Radio `streamUrl` has no scheme check**, so mpv will accept `file://`, `lavfi://` and `edl://`. The URL is also published in `MediaItem.extras`. | `navis_audio_handler.dart:~9338-9346,9529` | Require `isHostedHttpUri` and drop the URL from extras (follow `navis_playback_rules.dart:743`). |
| M-6 ✔ | **Inno relaunches Navis as Administrator after a silent update.** | `tool/windows/build_inno_installer.ps1:99` | Add the `runasoriginaluser` flag. |
| M-7 | **Untrusted images are decoded at full size with no byte cap**, so a decompression bomb can crash the app with out-of-memory. | `now_playing_screen.dart:230,253,1485`, `dynamic_accent_provider.dart:152,168`, `external_artwork_image.dart:107`, `home_onboarding_warmup.dart:494`, `CoverArtHttpFileService` | Wrap them with `_boundedImageProvider` (`cover_art_image.dart:655-673`) and add a body-size cap in `CoverArtHttpFileService`. |
| M-10 | **Windows portable update script ignores robocopy failure**, then runs `rd /s /q` on the backup. A `%` in the install path is not escaped. | `update_scripts.dart:41-50,132` | Restore the backup on `if errorlevel 8`, and escape `%` as `%%`. |

### Low
- **L-1:** https→http redirects are followed and resend `t/s` (Dio default; the cover redirect loop at `cover_art_cache_manager.dart:616`). Reject scheme downgrades.
- **L-3:** Only the sideload APK ships with obfuscated Dart symbols; desktop and iOS release binaries do not. Apply `--obfuscate --split-debug-info` to every release target.
- **L-6:** AzuraCast polling guesses the endpoint from the server-set homepage host, which means blind GETs to LAN hosts. Poll only when the stream URL matches `/listen/` or `/hls/`.
- **L-8 (deferred until re-enabled):** AudioMuse (dormant): the API key is stored in the DB and the client uses a raw `Dio()`, bypassing the integration guard. Fix this before the feature is re-enabled.
- **L-9:** `permanent_download_path_resolver.dart:145` returns an occupied path after 100 attempts, so it overwrites. Throw instead.
- **L-11:** Extensions of P-15 / P-12:
  - **L-11a (fixed):** `NavisArtworkProvider` used guessable cover IDs. Persisted per-install HMAC keys and v2 filenames prevent probing known IDs.
  - **L-11b (fixed):** A full wipe kept the ListenBrainz token. Wipe sign-out now clears the token and username; keep-data sign-out retains them.

### Local tooling notes (out of scope, informational)
These concern local development, testing and diagnostics, which are intentionally lightly protected. They are not findings. `fix/security-tooling` holds optional changes for some of them; merging it is the owner's choice.
- The remote-build tarball packed the whole working tree, which included `android/key.properties` and the keystores, and the tarball was left on the build VMs.
- Local secret files were mode 644; they are now 600 on the release host.
- Debug and profile builds are signed with the release key, including under the production app ID (deliberate, so dogfood builds can update release installs).
- Release scripts pass the keystore password and the Forgejo token in argv.
- Builder pinning is loose: no `rust-toolchain.toml`, only a Flutter version floor, no `--enforce-lockfile`.
- The remote asset name is not validated before `scp`.
- `tool/security_audit.sh` can never fail.
- The builder sshd docs leave password logins on.
- Profile-build diagnostics: the handshake file is briefly world-readable, and the token compare is not constant-time.

### Checked and fine
- Salt comes from a CSPRNG.
- No TLS bypass anywhere.
- Credential art is stripped before Android, MPRIS and SMTC see it.
- Both loopback servers are token- or uuid-gated, and diagnostics is compiled out of release.
- SQL is all parameterised.
- EQ and AutoEQ input is bounds-checked.
- SAF and FileProvider are scoped.
- The APK signature is checked before install.
- libmpv and sqlite3 downloads are SHA-256 pinned, and the Gradle wrapper is pinned.
- No git dependencies.
- Release macOS is sandboxed.

