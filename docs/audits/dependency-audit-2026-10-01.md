# Navis dependency audit (2026-10-01)

Checkout audited: branch `fix/windows-review` at `bb4f0de6`, read-only. Nothing was upgraded; every
recommendation needs a decision first.
Baseline example, already fixed: Windows `media_kit_libs_windows_audio` 1.0.9 fetched a 2023-09-24 libmpv from
the archived `media-kit/libmpv-win32-audio-build` (GitHub API: `archived: true`, last push 2024-02-28). Navis now
vendors it and pins a SHA-256-verified shinchiro build (`mpv-dev-x86_64-20261001-git-3186d369f9.7z`).

## Summary

**Update, same day:** the `codex/dependency-upgrades` work was ported onto dev
and merged (see `docs/history/completed-plans/Dependency_Upgrade_Plan.md`, "Port onto dev"). That resolves
the items marked "Covered by codex" below: Flutter 3.47.5, the Android
toolchain and wrapper checksum, the tracked SMTC `Cargo.lock` with current
crates, and the Windows sqlite3 asset verification. The other findings stand.


The Windows libmpv problem has an exact twin on macOS. `media_kit_libs_macos_audio` 1.1.4 (last published to pub
2023-09-27) downloads, during `pod install`, libmpv-darwin-build **v0.6.0, published 2023-09-24**. That build contains
FFmpeg 6.0, mpv 0.36.0, **Mbed TLS 3.4.1** (the TLS stack FFmpeg uses for every HTTPS stream on macOS) and libxml2
2.11.5. NVD lists CVEs for each of these. Its `audio-default` flavour enables only the `equalizer` and `overlay`
libavfilter filters, so the Navis EQ chain (`volume` + `biquad`) cannot run on macOS. Even upstream's newest
darwin build (v0.7.3, 2026-09-14) still uses FFmpeg 6.0, mpv 0.36.0 and Mbed TLS 3.4.1, so a version bump does not
help. A related security finding: no released mpv (up to v0.41.0) verifies TLS certificates by default
(`tls-verify` default off). Navis never sets the option, and desktop playback passes Subsonic stream URLs that
carry `u`/`t`/`s` auth parameters straight to libmpv. Only mpv master, which is the Windows pin, defaults to `yes`.
`mpv --list-options` on this host's mpv 0.41.0 confirms `--tls-verify` defaults to `no`, and Navis does not
set it. On Windows, the pinned build was tested at runtime (see the `tls-verify` section). Other similar cases:
- `google/flutter.widgets`, the upstream of `scrollable_positioned_list` and `visibility_detector`, is archived.
- Media3 in the just_audio fork is 1.4.1 (Aug 2024), seven minor versions behind.
- The Rust SMTC crate has no tracked `Cargo.lock`. Stale ignored locks in the main checkout carry
  RUSTSEC-2026-0190, RUSTSEC-2025-0023 and RUSTSEC-2025-0056, and `remote_build_windows.sh` ships whatever lock is
  on disk.
- The Android toolchain sits exactly on Flutter 3.47.1's error floor.
- On Linux, every clean build downloads and compiles an unused mimalloc 2.1.2.

I could not reproduce the sqlite3 hash mismatch. GitHub's asset digest, the pinned hash and a fresh download from
this host all equal `b1772918…`. No Pub package version in the lockfile has an OSV or pub.dev advisory.

## Findings by risk

| Risk | What | Where pinned | Locked/bundled version & date | Latest | Maintainer status | Known advisories | Features lost / risk | Recommendation |
|---|---|---|---|---|---|---|---|---|
| High | macOS libmpv via `media_kit_libs_macos_audio` | `pubspec.yaml:64`; `~/.pub-cache/hosted/pub.dev/media_kit_libs_macos_audio-1.1.4/macos/Makefile:3-12` | pkg 1.1.4 (2023-09-27); libmpv-darwin-build v0.6.0 (2023-09-24): FFmpeg 6.0, mpv 0.36.0, Mbed TLS 3.4.1, libxml2 2.11.5 | pub 1.1.4; media-kit `main` has unpublished 1.1.6 → darwin v0.7.2; darwin latest v0.7.3 (2026-09-14) still FFmpeg 6.0 / mpv 0.36.0 / Mbed TLS 3.4.1 | darwin-build repo active (push 2026-09-14), but the component versions are frozen; pub package `isUnlisted: true` | Mbed TLS 3.4.1: CVE-2023-52353, CVE-2025-47917, CVE-2026-25835, CVE-2026-34877, among others (NVD returns 12 CPE matches). FFmpeg 6.0: NVD returns 37 CPE matches, e.g. CVE-2023-6603 (HLS); `hls` protocol is enabled. libxml2 2.11.5 (DASH only): 23 matches, e.g. CVE-2024-25062, CVE-2024-40896 | No `volume`/`biquad` filters, so Navis EQ is impossible (UI already disabled on macOS per `docs/features/equalizer.md:27`); 3-year-old TLS/demux stack on a supported platform | Same treatment as Windows: vendor and pin a current libmpv for macOS (needs a source; media-kit's own builds don't move FFmpeg/Mbed TLS) |
| High | libmpv TLS certificate verification off on desktop (related config finding) | Not set anywhere: `third_party/just_audio_media_kit/lib/mediakit_player.dart` sets only `force-seekable`, `prefetch-playlist`, `af`, etc.; media_kit 1.2.6 doesn't set it either | mpv v0.36.0 `stream/stream_lavf.c` defaults omit `tls_verify` (= false); mpv v0.41.0 docs show no default `yes`; this host's Linux libmpv is 0.41.0 | mpv master `stream/network.c:55` `.tls_verify = true`; `DOCS/interface-changes/tls-verify-default.txt` (unreleased) | n/a | n/a | Linux (distro mpv ≤0.41) and macOS (mpv 0.36.0): HTTPS stream likely not certificate-checked; stream URL carries `u`, `t`, `s` (`lib/src/api/subsonic_api_client.dart:1003-1013`). Windows pin = mpv master `3186d369f9`, so default `yes` | Decide whether to set `tls-verify=yes` explicitly on Linux and macOS; Navis's own API client already refuses bad certificates, so no working server would be lost. Default confirmed on Linux mpv 0.41.0; Windows verified at runtime. **Resolved 2026-10-02** for Linux and Windows: `JustAudioMediaKit.tlsVerify` sets `tls-verify=yes` on every player, and `tool/stream_open_diagnostics.py` proves an untrusted certificate is refused (and that the check fails with it off). macOS stays open until its libmpv is replaced. |
| Medium | Rust SMTC crate lockfile / crates | `third_party/navis_windows_smtc/rust/Cargo.toml:10-14`; `.gitignore:4` (`*.lock`) ignores `Cargo.lock` | This checkout: no `Cargo.lock` (fresh resolve). Main checkout (ignored, untracked): `Cargo.lock` anyhow 1.0.82, tokio 1.39.2, adler 1.0.2, windows 0.58.0 (0.58.0 released 2024-07-03); stale `rust/Cargo.lock` anyhow 1.0.75, tokio 1.34.0, FRB 2.1.0 | windows 0.62.2, anyhow 1.0.104, tokio 1.53.1, FRB 2.13.0 (crates.io) | Upstream `KRTirtho/smtc_windows` last push 2024-07-25 (fork is Navis-owned) | RUSTSEC-2026-0190 (anyhow), RUSTSEC-2025-0023 / GHSA-rr8g-9fpq-6wmg (tokio), RUSTSEC-2025-0056 (adler, unmaintained), all in the main checkout's locks | Unreproducible Windows builds; `tool/remote_build_windows.sh:92-99` tars the working dir incl. ignored locks, so the crate set shipped depends on which checkout built it; cargokit installs floating `stable` toolchain (`cargokit/build_tool/lib/src/rustup.dart:29`) | Covered by codex branch (tracked lock, OSV-clean); see Overlap |
| Medium | sqlite3 native asset: Windows offline path | `tool/remote_build_windows.sh:379-415` patches `description.dart` in the VM pub cache | Fallback copies any sibling `download-*/sqlite3.dll` before download | — | — | — | Bypasses the hook's SHA-256 check (`fetch()` in `description.dart:140-180` is skipped); could ship an older, unidentified SQLite | Covered by codex (`tool/sqlite3_windows_asset.py`); keep hash verification |
| Medium | sqlite3 Linux asset hash mismatch report | `pubspec.yaml:48`; `sqlite3-3.5.2/lib/src/hook/asset_hashes.dart` | 3.5.2 (2026-08-19); prebuilt SQLite 3.53.4 (source id 2026-07-24) | sqlite3 3.7.0 (2026-09-30); SQLite 3.53.4 is current per sqlite.org | Upstream very active (push 2026-09-30) | none | Not reproduced, see section below | Record host/network/bytes next time it happens |
| Medium | Android build toolchain | `android/settings.gradle.kts:22-23`; `android/gradle/wrapper/gradle-wrapper.properties:5`; `android/app/build.gradle.kts:33,65-66` | Gradle 8.14 (2025-04-25), AGP 8.12.1 (POM 2025-08-18), KGP 2.2.20 (2025-09-09), compileSdk 37, targetSdk 36, minSdk 24, JVM 17, NDK = Flutter default 28.2.13676358 | Gradle 9.8.0 (2026-09-24), AGP 9.4.1 (2026-09-18), Kotlin 2.4.20 | n/a | none found | Flutter 3.47.1 `DependencyVersionChecker.kt:96,105,109`: error floor Gradle 8.14.0, AGP 8.11.1, KGP 2.2.20, so Gradle and KGP sit exactly on the floor. Wrapper has no `distributionSha256Sum` | Covered by codex (AGP 9.3.1 / Gradle 9.5.0 + checksum / Kotlin 2.4.20) |
| Medium | Media3 (ExoPlayer) in just_audio fork | `third_party/just_audio/android/build.gradle.kts:71-75` | 1.4.1 (POM 2024-08-27) | 1.11.1 (2026-09-11) | Upstream just_audio 0.10.6 also pins 1.4.1; no upstream commits since 0.10.6 | OSV: none for media3-exoplayer/common/datasource/extractor 1.4.1 | 7 minor releases of playback/extractor fixes not taken (not reviewed per release) | Treat as High-tier audio change if pursued; not in codex scope |
| Medium | `scrollable_positioned_list`, `visibility_detector` | `pubspec.yaml:47,51` | 0.3.8 (2023-05-08); 0.4.0+2 (2023-03-09) | same | **`google/flutter.widgets` archived** (API `archived: true`, last push 2024-08-08); not discontinued on pub | none | No fixes possible upstream; `docs/development/dependency-upgrades.md` watch list retains them but doesn't record the archival | Add "upstream archived" to the watch-list entry; triggers unchanged |
| Low | Flutter SDK | `pubspec.yaml:9`; `tool/bootstrap.sh:4` | 3.47.1 / Dart 3.13.1 (2026-08-19) | 3.47.5 / Dart 3.13.4 (2026-09-18) | Google | not checked | 4 stable hotfixes behind | Covered by codex (>=3.47.5) |
| Low | mimalloc build-time download (Linux) | `~/.pub-cache/hosted/pub.dev/media_kit_libs_linux-1.2.1/linux/CMakeLists.txt:13,57-58` | mimalloc 2.1.2 (MD5-checked), downloaded and compiled on clean builds (seen in `build/linux/x64/profile/mimalloc-2.1.2.tar.gz`) | mimalloc tags up to v3.5.4 | media-kit `main` still pins 2.1.2 | not checked | Not linked: `linux/runner/CMakeLists.txt:23-24` links only flutter+GTK; `nm` finds no `mi_` symbols in the bundle. Dead network dependency (GitHub) + MD5 | Optionally set `MIMALLOC_USE_STATIC_LIBS OFF` to skip it |
| Low | media_kit libs packages unpublished/unlisted | `pubspec.yaml:59,64` | `media_kit_libs_linux` 1.2.1 (2025-03-24); macOS 1.1.4 (2023-09-27) | same on pub | pub `isUnlisted: true` for media_kit_libs_linux/_macos_audio/_windows_audio/_audio/native_event_loop; `media-kit/media-kit` active (push 2026-08-30); `main` has unpublished macOS 1.1.6 and a Windows switch to `libmpv-win32-audio-cmake` 20251213 | none | Fixes land in git but not on pub | Track git, not pub, for these |
| Low | Linux libmpv/FFmpeg | `tool/release.sh:616` (`Depends: libgtk-3-0`) | System libmpv at runtime (not bundled); this host: mpv 0.41.0, ffmpeg 9.0.2 | distro | distro-maintained | distro | `.deb` lacks libmpv dependency (documented in `docs/release/release-linux.md:111-121`); EQ relies on distro FFmpeg having `biquad`/`volume` | Already documented |
| Low | `js` (transitive, web) | via `audio_service` 0.18.19 | 0.7.2 (2025-02-11) | — | **Discontinued** on pub | none | Web-only | None needed now |
| Low | `colornames` | `pubspec.yaml:16` | 0.2.0 (2024-10-19) | same | Repo not archived, last push 2024-10-19 (~2 yrs) | none | — | Watch |
| Low | Majors behind on pub | `pubspec.yaml` | go_router 17.5.0, cached_network_image 3.4.1 (2024-08-13), file_picker 12.0.0, android_file_picker 1.0.1, very_good_analysis 10.3.0, dbus 0.7.15, flutter_lints 3.0.2 (2024-03-26), transitive nm 0.5.0 (2022-02-08), cli_util 0.4.2 | 18.0.2, 4.0.4, 13.1.0, 2.0.0, 11.0.0, 0.8.0, 6.0.0, 0.6.0, 0.6.0 | All active | none | — | All except flutter_lints/dbus/nm covered by codex; dbus/nm are documented holds |
| Low | Inno Setup | `tool/windows/build_inno_installer.ps1:19-34` | "Inno Setup 6", version not pinned or recorded | not checked | — | not checked | — | Record ISCC version in release notes |

## Notes by category

### macOS libmpv
- `media_kit_libs_macos_audio.podspec` runs `system("make")`. The Makefile curls
  `libmpv-xcframeworks_v0.6.0_macos-universal-audio-default.tar.gz` from `media-kit/libmpv-darwin-build` and checks
  it with SHA-256 `916220b7…`. The supply chain is pinned and verified. The problem is the age of what it pins.
- Component versions come from `downloads.lock` at tag v0.6.0: FFmpeg 6.0, mpv 0.36.0, mbedtls 3.4.1, libxml2
  2.11.5, libass 0.17.1, harfbuzz 8.1.1, freetype 2.13.2, uchardet 0.0.8, dav1d 1.2.1, libvpx 1.13.0, plus
  fftools-ffi.
- v0.7.3 (`packages.lock.nix`) has the same FFmpeg, mpv, Mbed TLS and libxml2, plus libpng 1.6.40. So there is no
  upstream build with current FFmpeg.
- FFmpeg `audio-default` options (`scripts/ffmpeg/meson.build`) include `--enable-mbedtls`, `--enable-libxml2`, the
  `hls`/`https`/`tls` protocols, the `dash`/`mov`/`matroska`/`ogg` demuxers, and only these filters: `overlay` and
  `equalizer`.
- The NVD counts are CPE matches. I did not check each FFmpeg CVE against the enabled decoders.

### libmpv `tls-verify`
- Released mpv versions do not verify server certificates by default. Navis streams with `https://…/rest/stream.view?u=…&t=…&s=…`
  on all three desktops (`docs/architecture.md:1296-1302`). Without verification, a man-in-the-middle can read the
  token/salt pair and swap the audio.
- Windows is the exception, because its pin is mpv master, where the default is now `yes`.
- On this host, `mpv --list-options` shows `--tls-verify  Flag (default: no)` for mpv 0.41.0.
- On the Windows 11 VM, the pinned `libmpv-2.dll` (curl 8.22.0-DEV with OpenSSL) played an HTTPS WAV with a
  valid certificate and refused `https://expired.badssl.com/` ("TLS certificate verification failed"). It loads
  trust anchors through OpenSSL's `org.openssl.winstore`, so a private CA trusted by Windows is trusted for
  streaming as well. Navis's Dart client never bypasses certificate checks, so a server it can sign in to also
  streams.
- On 2026-10-02 Navis itself refused an untrusted certificate on Linux (`tool/stream_open_diagnostics.py`,
  a self-signed HTTPS radio station) and on the Windows VM (the same station flow: a TLS connection attempt,
  no HTTP request, no playback, while the plain-HTTP station played). macOS was not tested.
- Upstream `just_audio_media_kit` added only mTLS `tlsCertFile`/`tlsKeyFile` options after 2.1.0 (PR #30,
  2026-04-27). It did not add `tls-verify`.

### sqlite3 hash mismatch
- The hook downloads `https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.2/<file>`. It hashes
  the stream and rejects a mismatch (`description.dart:140-180`). The pins ship inside the pub package, which is
  itself content-hashed in `pubspec.lock`.
- GitHub release API (asset `libsqlite3.x64.linux.so`, uploaded 2026-08-19T21:49:16Z, never updated) reports digest
  `sha256:b1772918…`. That equals the pin.
- A fresh `curl` from this host on 2026-10-01 also gave `b1772918…`. `sqlite3_libversion()` = 3.53.4.
- All cached copies in this checkout and in `../Navis` match. They include
  `.dart_tool/hooks_runner/shared/sqlite3/build/download-b1772918/`.
- `839488eb…` was seen once during the Windows review (recorded in
  `docs/audits/windows-review-2026-10-01.md`); it matches no asset in 3.5.2, 3.6.0 or 3.7.0. Why is
  **unverified**. A truncated or intercepted download on a different host or network would produce this exact
  error.
- Upstream issue #405 is about glibc. The prebuilt Linux libs needed GLIBC_2.38, through one `__isoc23_strtol`
  symbol in the sqlcipher builds; it was fixed in 3.6.0. Navis's `libsqlite3.x64.linux.so` 3.5.2 needs at most
  GLIBC_2.34 (`objdump -T`), which is fine for Ubuntu 22.04.
- Issue #384 fixed a nondeterministic download cache dir name (`Object.hash()`). `remote_build_windows.sh` still
  works around that behaviour.
- `sqlite3_flutter_libs` 0.6.0+eol and `sqlcipher_flutter_libs` 0.7.0+eol are empty end-of-life shells that
  `drift_flutter` 0.3.1 requires on purpose. They bundle no SQLite. (Update 2026-10-07: Navis imported nothing from `drift_flutter`, so it was removed together with these shells.)

### Android toolchain
- `flutter.ndkVersion` resolves to 28.2.13676358 (Flutter `FlutterExtension.kt:42`).
- No jcenter or jitpack repositories in Navis or the checked plugins.
- OSV query for Media3 1.4.1, Guava 33.0.0-android, androidx.media 1.7.0 and work-runtime 2.11.2: no matches.
- The previous audit (the removed `android-advisories.json` dump, retained in Git history) found no matches across
  the 89 resolved Maven coordinates.

### Rust crates
- OSV batch run over the locks:
  - `../Navis/third_party/navis_windows_smtc/Cargo.lock` (95 crates) and `rust/Cargo.lock` (70 crates): the three
    advisories in the table.
  - Codex `Cargo.lock` (92 crates; anyhow 1.0.104, tokio 1.53.1, windows 0.62.2, adler2 2.0.1): none.
- No cargokit precompiled-binary config exists (no `cargokit.yaml`), so nothing is downloaded beyond crates.io and
  rustup.

### Forks
| Fork | Base | Upstream latest | Gap |
|---|---|---|---|
| `third_party/just_audio` | 0.10.6 (`NAVIS_CHANGES.md`) | 0.10.6 (2026-06-29); 0 commits on `ryanheise/just_audio` since | None, but upstream itself pins Media3 1.4.1 |
| `third_party/just_audio_platform_interface` | 4.6.0 | 4.6.0 (2025-08-13) | None |
| `third_party/just_audio_media_kit` | 2.1.0 + Navis patches | 2.1.0 (2025-04-13); repo active (2026-04-27) | Unreleased upstream: mTLS cert/key options only |
| `third_party/navis_windows_smtc` | smtc_windows 1.1.0 (CHANGELOG) | pub 1.1.0 (2025-08-18); GitHub repo last push 2024-07-25 | Upstream effectively idle. windows-rs 0.58 → 0.62.2 is in codex |
| `third_party/media_kit_libs_windows_audio` | 1.0.9 + pinned libmpv | — | Baseline, fixed |

### CI
- There is no CI. `.forgejo/` doesn't exist, and `.github/` holds only `copilot-instructions.md`.
  `docs/development/ci-cd.md:3` confirms that gates run locally.
- So there are no action versions or container images to audit. There is no `.fvmrc`. The Flutter floor lives in
  `pubspec.yaml:9` and `tool/bootstrap.sh:4-5`.

## Not a concern (checked)
- No locked Pub package version is affected by any advisory. OSV querybatch over 202 hosted packages returned no
  matches. pub.dev advisories exist for dio (GHSA-9324-jv53-9cc8 / CVE-2021-31402, fixed 5.0.0), archive
  (CVE-2023-39139, CVE-2023-39137, fixed 3.3.8) and http (CVE-2020-35669, fixed 0.13.3). The locked dio 5.11.0,
  archive 4.2.0 and http 1.6.0 are past those fixes.
- No direct dependency is discontinued on pub. The only discontinued package is the transitive `js`.
- The sqlite3 prebuilt SQLite is 3.53.4, the current release. Downloads are pinned and SHA-256 verified.
- `audio_service` 0.18.19, `audio_session` 0.2.4 and `just_audio` 0.10.6 are at latest, and their upstreams are
  active (2026-06/07).
- `drift` and `drift_dev` are one minor behind; `drift_flutter` is at latest; upstream is active.
- `flutter_secure_storage` 11.0.0 → 11.2.0 is a minor; upstream is active. `path_provider` 2.1.6 is latest.
- `dio` 5.11.0 → 5.11.1 is a patch; upstream is active. `connectivity_plus` and `package_info_plus` are latest.
- The googletest `FetchContent` in `flutter_secure_storage_windows`, `screen_retriever_windows` and
  `url_launcher_windows` CMake is guarded by `include_<plugin>_tests` (example builds only).
- The `objective_c` hook compiles locally and downloads nothing.
- The Windows libmpv is pinned to mpv master `3186d369f9` (2026-09-30), which equals the mpv master HEAD seen
  today.
- `flutter_rust_bridge` 2.13.0 is latest. `win32` 6.4.0 is latest.
- No Flatpak, AppImage, Snap or RPM manifests exist (`docs/release/release-linux.md` explains why). The Linux desktop file
  pins nothing.
- compileSdk 37, targetSdk 36 and minSdk 24 are at or above Flutter's defaults (36/36/24).

## Overlap with codex/dependency-upgrades
- `~/.codex/worktrees/dependency-upgrades/Navis` is uncommitted work: 551 files, on base `646275b8`
  (2026-09-26).
- It already covers:
  - root pub bumps: dio, drift/drift_dev 2.35.0, sqlite3 3.6.0, file_picker 13, android_file_picker 2,
    go_router 18, cached_network_image 4, flutter_secure_storage 11.2, riverpod 3.4.3, freezed 4.0.2,
    very_good_analysis 11, logger, octo_image, flutter_cache_manager, flutter_local_notifications;
  - new `material_ui`/`cupertino_ui` and `navis_android_storage`;
  - Flutter >=3.47.5;
  - Android AGP 9.3.1, Gradle 9.5.0 + `distributionSha256Sum`, Kotlin 2.4.20, androidx/Guava;
  - iOS 16 and macOS 12 deployment targets;
  - SMTC: windows 0.62.2, anyhow 1.0.103, a tracked `Cargo.lock`, FRB/ffigen/CargoKit;
  - `tool/sqlite3_windows_asset.py` and a reworked `remote_build_windows.sh`;
  - `just_audio_media_kit` changes.
- Not touched there: the macOS libmpv (`media_kit_libs_macos_audio`), mpv `tls-verify`, Media3 in the just_audio
  fork, the archived flutter.widgets packages, the media_kit_libs_linux mimalloc download, `flutter_lints`, Inno
  Setup.
- Merge risk: the codex base predates the vendored `third_party/just_audio` (EQ fork),
  `just_audio_platform_interface` override and `media_kit_libs_windows_audio`. Its `pubspec.yaml`/`pubspec.lock`,
  `just_audio_media_kit` and `remote_build_windows.sh` edits will conflict with this branch.

## Method
- Read `docs/development/dependency-upgrades.md`, `docs/history/completed-plans/Dependency_Upgrade_Plan.md`, `docs/audits/dependency-upgrades-2026-09-27.md`
  (raw dump contents remain in Git history), `docs/release/release-windows.md`, `docs/release/release-linux.md`, `docs/features/equalizer.md`, `docs/architecture.md`
  (desktop streaming), `docs/development/ci-cd.md`, `README.md`.
- Read `pubspec.yaml`, `pubspec.lock`, Android Gradle files, `linux/`/`windows/`/`macos/` CMake/Podfile/pbxproj,
  `tool/release.sh`, `tool/remote_build_windows.sh`, `tool/windows/build_inno_installer.ps1`, the fork
  pubspecs/CHANGELOGs/NAVIS notes, and the SMTC `Cargo.toml` and cargokit sources.
- pub.dev: `/api/packages/<p>`, `/options` and `/advisories` for all 202 hosted locked packages, saved in the
  scratchpad `pub/`. OSV `querybatch` for Pub (202), crates.io (3 lockfiles) and 7 Maven coordinates.
- GitHub REST, unauthenticated (rate-limited, so used sparingly): repo `archived`/`pushed_at` for 17 repos;
  libmpv-darwin-build releases; sqlite3.dart release assets (digests) for 3.5.2/3.6.0/3.7.0; sqlite3.dart issue
  search plus issue #405; commits since base for just_audio and just_audio_media_kit.
- Shallow clones into the scratchpad (not the repo): libmpv-darwin-build v0.6.0 and v0.7.3, mpv master. Raw
  GitHub files: mpv v0.36.0, v0.38–v0.41 `stream_lavf.c`/`options.rst`; media-kit `main` lib pins.
- NVD CVE API by CPE: mbed_tls 3.4.1, ffmpeg 6.0, libxml2 2.11.5. crates.io API, Google Maven metadata, Maven
  Central (Kotlin), services.gradle.org, Flutter `releases_linux.json`, sqlite.org.
- Local: `flutter --version`, `objdump -T`/`ctypes` on the downloaded `libsqlite3.x64.linux.so`, `sha256sum` of
  cached copies, `nm` on the Linux bundle, `pacman -Q mpv ffmpeg`, Flutter `DependencyVersionChecker.kt`.
- Codex worktree: `git status --short`, `git diff --stat`, `git diff` on manifests, `git log`.
- I ran no pub, cargo, gradle or build commands.

**Not verified:**
- Which host and network produced `839488eb…`.
- Runtime TLS behaviour of libmpv on Linux and macOS (Windows was tested).
- Per-CVE reachability in the macOS FFmpeg/Mbed TLS build.
- What Rust crate versions the Windows VM actually compiled into shipped builds.
- The Inno Setup version on the VM.
- Media3 per-release changelogs between 1.4.1 and 1.11.1.
- Flutter 3.47.2–3.47.5 hotfix content (the "engine security" claim is from the earlier plan, not re-read).
- GitHub archive dates (the API gives only the flag).
- Google Play target-API deadlines.
- iOS, which was out of scope.
