# Navis security audit

- **Audited:** branch `dev` at `f145399e`, 2026-10-09.
- **Scope:** code-level security, as a companion to `COMPLIANCE-AUDIT.md` (2026-10-07, not in the repo). Findings already listed there (D-2 update SHA-256, D-4 debug-key fallback, P-10, P-11, P-15, S-1 and S-5) are not repeated here.
- **Method:** read-only review of three areas: network and credentials; filesystem, updater and native code; build and supply chain. Findings marked ✔ were confirmed again by hand, in the code or on disk.
- **Fix ownership:**
  - App-side items are fixed on `fix/security-audit`.
  - The updater and release-tooling items (H-2, H-3, H-4, M-6, M-9, M-10, L-1 to L-5, L-10) touch files that `feat/r2-updates` is rewriting, so they are fixed there.

## Findings

### High
| ID | Finding | Evidence | Fix (reuse) |
|---|---|---|---|
| H-1 ✔ | **Path traversal from server data.** A malicious server sets `suffix` or `id` to `x/../../.config/autostart/evil.desktop`, and playing the song writes attacker bytes anywhere the user can write. On desktop that means code execution at next login. | `permanent_download_path_resolver.dart:187` `_normalizeExtension` (raw); `playback_source_resolver.dart:413` (raw `song.id` + ext), `:570-585`; `download_service.dart:2201` | Allowlist the extension (`^[A-Za-z0-9]{1,10}$`, else `bin`) in one shared helper used by both resolvers. Hash raw ids with `PlaybackArtCache.fileKey` (`playback_art_cache.dart:47`). Add a final `p.isWithin` guard (`_isWithinOrSame` in `utils/file_utils.dart`). |
| H-2 ✔ | **Linux `.deb` update leads to root code execution.** The download goes to the shared `/tmp/navis_updates`, which is reused if it already exists, and then `pkexec dpkg -i` runs on it. Another local user can swap the file or plant a symlink. | `update_service.dart:45-52,296` | Use `Directory.systemTemp.createTemp('navis_update_')` (mode 0700, random name; this pattern is already used in `permanent_download_import_service.dart:774`). |
| H-3 | **Linux portable update stages in a predictable `/tmp` path.** The staging dir `/tmp/navis_update_staging_<millis>` and the script are attacker-raceable, so another user can replace the binary before the move. | `update_service.dart:319-322`, `update_scripts.dart:65-68,120` | Use the same private `createTemp` dir for staging and the script. |
| H-4 ✔ | **The remote-build tarball ships the signing key to the build VMs and leaves it there.** `tar -C repo .` includes `android/key.properties` (passwords) and both `*.jks` files, and `source.tgz` is never deleted. | `tool/remote_build_linux.sh:103-111`, `tool/remote_build_windows.sh:107-115` | Build the tarball from `git ls-files -z \| tar --null -T -`. Delete the tarball and workspace in the existing `cleanup()` trap. **Operator:** delete the leftover copies on both VMs, then decide whether to rotate the key (see S-1). |

### Medium
| ID | Finding | Evidence | Fix (reuse) |
|---|---|---|---|
| M-1 ✔ | **Cover-art cache stores signed URLs** (`u/t/s`, or the `p=enc:` password with legacy auth) in a mode-644 JSON file. There are 1516 tokens on this machine and about 150 old copies in the Trash, and they survive "sign out, keep data". | `cover_art_cache_manager.dart:1009-1020`, `cover_art_image.dart:522`, `sign_out_service.dart:212` | Give the cache only unsigned URLs or keys and have `CoverArtHttpFileService.get()` sign them. Purge the old cache files once, and clear the cache on every sign-out. |
| M-2 ✔ | **Login silently downgrades to the reversible password.** It retries with `p=enc:` on *any* auth error (including a wrong password), or when the ping reports a version below 1.13, which a fake server can claim. | `server_connection_service.dart:44-61,81-96,129-142` | Fall back only on Subsonic error code 41. Never over non-loopback `http://`. Ask the user before turning legacy auth on. |
| M-3 | **`user:pass@` in the server URL** is saved in the DB, sent on every URL and logged at WARNING in release. | `server_config_repository.dart:240-246`, `subsonic_logging_interceptor.dart:72-80`, `credential_redaction.dart` | Move it to secure storage and send an `Authorization: Basic` header. Strip `userInfo` in both redaction helpers. |
| M-4 | **Server-supplied URLs are opened with no scheme allowlist.** `lastFmUrl` and the release `htmlUrl` reach Windows ShellExecute and xdg-open (`file://`, `search-ms:`, `.desktop`). | `album_detail_screen.dart:2060`, `update_dialog.dart:415,431,443`, `integrations_settings_screen.dart:502`, `home_support_widgets.dart:165` | Add one `launchExternalHttpUrl` helper built on `isHostedHttpUri` (`integration_artwork.dart:100`) and route every `launchUrl` call through it. Check that `musicBrainzId` is a UUID. |
| M-5 | **Radio `streamUrl` has no scheme check**, so mpv will accept `file://`, `lavfi://` and `edl://`. The URL is also published in `MediaItem.extras`. | `navis_audio_handler.dart:~9338-9346,9529` | Require `isHostedHttpUri` and drop the URL from extras (follow `navis_playback_rules.dart:743`). |
| M-6 ✔ | **Inno relaunches Navis as Administrator after a silent update.** | `tool/windows/build_inno_installer.ps1:99` | Add the `runasoriginaluser` flag. |
| M-7 | **Untrusted images are decoded at full size with no byte cap**, so a decompression bomb can crash the app with out-of-memory. | `now_playing_screen.dart:230,253,1485`, `dynamic_accent_provider.dart:152,168`, `external_artwork_image.dart:107`, `home_onboarding_warmup.dart:494`, `CoverArtHttpFileService` | Wrap them with `_boundedImageProvider` (`cover_art_image.dart:655-673`) and add a body-size cap in `CoverArtHttpFileService`. |
| M-8 ✔ | **Secret files are mode 644**: `tool/release.env` (Forgejo token), `android/key.properties` and both `.jks` files. | `stat` | Run `chmod 600`, and make `release.sh` and `tool/security_audit.sh` fail on a wider mode. |
| M-9 | **Debug and profile builds are signed with the release key** under the production app ID when `NAVIS_APP_ID_SUFFIX` is unset. A leaked debug APK installs over a user's app as a debuggable "update". | `android/app/build.gradle.kts:100-117` | Use the debug key for debug and profile builds (fold this into the D-4 fix). |
| M-10 | **Windows portable update script ignores robocopy failure**, then runs `rd /s /q` on the backup. A `%` in the install path is not escaped. | `update_scripts.dart:41-50,132` | Restore the backup on `if errorlevel 8`, and escape `%` as `%%`. |

### Low
- **L-1:** https→http redirects are followed and resend `t/s` (Dio default; the cover redirect loop at `cover_art_cache_manager.dart:616`). Reject scheme downgrades.
- **L-2:** Secrets appear in argv: `keytool -storepass` and `curl -H "Authorization: token"` (`release.sh:504,865,889`, `play_release.sh`, docs). Use `-storepass:env` and pass headers via stdin.
- **L-3:** Only the sideload APK is built with `--obfuscate --split-debug-info`. Apply the flags to every target in `release.sh` and in both remote scripts.
- **L-4:** Builder pinning:
  - no `rust-toolchain.toml`;
  - only a Flutter version floor;
  - no `pub get --enforce-lockfile`;
  - the Windows pub-cache hash mismatches are tolerated (`remote_build_windows.sh:256-267`);
  - dead MD5 libmpv pre-seed code (`:283-303`, delete it).
- **L-5:** The remote builder's `asset_name.txt` goes unchecked into a local `scp` destination (`remote_build_*.sh:265,525`). Validate it against `^[A-Za-z0-9._-]+$`.
- **L-6:** AzuraCast polling guesses the endpoint from the server-set homepage host, which means blind GETs to LAN hosts. Poll only when the stream URL matches `/listen/` or `/hls/`.
- **L-7:** Diagnostics handshake file (profile builds only): it is world-readable until a separate `chmod` runs, and the token compare is not constant-time (`sync_diagnostics_server.dart:299,4700`).
- **L-8:** AudioMuse (dormant): the API key is stored in the DB and the client uses a raw `Dio()`, bypassing the integration guard. Fix this before the feature is re-enabled.
- **L-9:** `permanent_download_path_resolver.dart:145` returns an occupied path after 100 attempts, so it overwrites. Throw instead.
- **L-10:** `tool/security_audit.sh` can never fail (`|| true`), and its regex misses unquoted `storePassword=`. Fix both.
- **L-11:** Extensions of P-15 / P-12:
  - `NavisArtworkProvider` lets any app probe the library's covers. Use HMAC keys.
  - A full wipe keeps the ListenBrainz token.
- **L-12:** The Windows sshd setup docs don't disable password auth or limit `AllowUsers`.

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

