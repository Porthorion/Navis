# Flathub Readiness

This document tracks what Navis needs before it can be submitted to Flathub as
the primary cross-distro Linux release path.

Flathub is the best first target for Debian-, Fedora-, and Arch-based desktop
users because one Flatpak can cover all three families through Flathub-compatible
software centers and `flatpak`. It is not the same as being in Debian, Fedora,
or Arch official repositories.

## Current Repo Facts

- Flutter Linux desktop builds already exist.
- Linux application ID is `com.navis.app.navis`.
- Linux binary name is `navis`.
- Existing desktop file: `linux/packaging/com.navis.app.navis.desktop`.
- Current release pipeline already produces Linux portable bundles and `.deb`
  packages for Forgejo releases.
- Navis uses Linux desktop media integration through MPRIS.
- Navis needs network access for Subsonic/OpenSubsonic, Last.fm, ListenBrainz,
  LRCLIB, artwork, and optional update/release checks on non-Flatpak
  desktop builds.

## Submission Shape

Preferred Flathub identity:

- App ID: `com.navis.app.navis`
- Command: `navis`
- Manifest file: `com.navis.app.navis.yml` or `.json`
- Metadata should live upstream in this repo where possible, not only in the
  Flathub submission repo.

Expected top-level Flathub submission files:

- Flatpak manifest named after the app ID.
- `flathub.json` if architecture support needs to be restricted or customized.
- Dependency manifests for anything the build cannot fetch during the build
  phase.
- AppStream MetaInfo XML.
- Desktop file.
- Icons.
- Screenshots and release metadata referenced by AppStream.

## Flutter-Specific Work

Flutter can be published through Flatpak/Flathub, but Navis needs explicit
packaging work. Flutter does not currently provide a one-command Flathub export.

Required work:

- Choose the Flatpak runtime/SDK, probably Freedesktop SDK unless a GNOME/KDE
  runtime provides a better fit.
- Decide how Flutter SDK is provided in the Flatpak build:
  - use an existing Flutter Flatpak base/app pattern if accepted for Flathub, or
  - declare/download the Flutter SDK as a source before build, or
  - vendor/generated dependency sources in the manifest.
- Generate an offline-compatible dependency manifest for Dart/pub packages.
- Ensure `flutter build linux --release` works inside `flatpak-builder`.
- Ensure native Flutter plugin dependencies are available in the runtime or
  built as Flatpak modules.
- Verify `audio_service_mpris` and any DBus/MPRIS integration works inside the
  sandbox.
- Verify secure storage behavior under Flatpak. If the current secure-storage
  plugin cannot use the host keyring from sandboxed execution, provide a
  Flatpak-compatible path or document the limitation before submission.

## Reproducible Build Constraints

Flathub builds do not allow arbitrary network access during the build phase.
All sources and dependencies must be declared so the builder can fetch them
before the build starts.

Implications for Navis:

- Do not rely on `flutter pub get` reaching pub.dev during the build step unless
  dependencies have been declared through a generated manifest/source list.
- Do not download binary assets or native libraries from ad hoc scripts during
  build.
- Pin source URLs and hashes for vendored/native modules.
- Keep build scripts deterministic and avoid host-specific paths.
- Confirm the source and licenses for all bundled runtime dependencies are
  redistributable.

## Metadata Requirements

Add or verify:

- `com.navis.app.navis.metainfo.xml` with:
  - name, summary, description
  - project license and metadata license
  - developer/project URL
  - screenshots
  - content rating, if applicable
  - release entries
  - launchable desktop ID
- Desktop file has:
  - correct app ID filename
  - `Name=Navis`
  - suitable categories, likely `AudioVideo;Audio;Player;`
  - no stale paths
- Icons installed at standard hicolor sizes.
- Complete English metadata and user-facing strings.
- Store screenshots showing the real app, not placeholder art.

## Sandbox And Permissions

Start with the smallest viable `finish-args` set.

Likely needed:

- `--share=network`
- audio output access through the runtime/audio stack
- MPRIS/DBus permissions needed by `audio_service_mpris`
- notification portal support, if notifications are used
- URI opening portal support for Last.fm auth, external links, and help pages

Needs review before granting:

- Filesystem access for downloads and custom download folder support.
- Music library/media folder access, if Navis ever imports local files.
- Background behavior and media-session integration.
- Any access to secrets/keyrings for secure storage.

Prefer portals over broad filesystem or session-bus permissions wherever
possible. If custom download folders cannot be portal-based, limit filesystem
access to the narrowest practical paths and document why.

## App Behavior Adjustments

Flatpak builds should behave like store builds:

- Disable Linux self-update behavior inside Flatpak. Updates should come through
  Flathub.
- Keep changelog/about/license content.
- Keep external browser links working through portals.
- Use Flatpak-safe config/cache/data paths.
- Avoid assuming `/opt/navis`, `.deb` install paths, or direct package-manager
  access.
- Ensure downloads/cache cleanup still works with sandboxed paths.

## Local Validation Plan

Before submission:

1. Install Flatpak and `flatpak-builder`.
2. Build locally with `flatpak-builder --force-clean`.
3. Run the Flatpak build locally.
4. Test login, playback, artwork, downloads/cache, Last.fm auth browser launch,
   ListenBrainz validation, and lyrics.
5. Test MPRIS/media keys from a desktop shell.
6. Inspect permissions:
   `flatpak info --show-permissions com.navis.app.navis`
7. Run Flathub lint/validation tooling.
8. Confirm no network is needed during the build step after sources are fetched.
9. Confirm screenshots and AppStream metadata render correctly in a software
   center.

## Submission Flow

- Create a Flathub submission PR with the manifest and required files.
- Expect review feedback around metadata, permissions, bundled dependencies,
  licensing, and reproducibility.
- After merge, use Flathub builds as the Linux update path for Flatpak users.
- Keep Forgejo releases for `.deb`, portable bundles, release notes, tags, and
  non-Flatpak users.

## Limitations Compared To Native Packages

- Not an official Debian/Fedora/Arch repository package.
- Users may need to enable Flathub first, especially on Debian-derived systems.
- Sandbox permissions can limit direct filesystem, DBus, keyring, or background
  integration.
- Native package integrations such as `.deb` self-update paths do not apply.
- Flathub review can block release until metadata, permissions, or dependency
  issues are resolved.
- Some users on Arch may still prefer AUR; some Ubuntu users may prefer Snap or
  `.deb`.

## Open Questions For Navis

- Which Flutter Flatpak build pattern should Navis use?
- Can all Dart/pub dependencies be represented cleanly for offline Flathub
  builds?
- Does the secure storage plugin work correctly inside Flatpak on GNOME/KDE?
- Which exact DBus permissions are required for MPRIS without over-broad access?
- Should Flatpak builds disable the existing desktop update controls at compile
  time or detect the Flatpak runtime?
- What filesystem access is necessary for custom downloads?
- Should Flathub be the only Linux auto-update channel, with Forgejo artifacts
  remaining manual?

## References

- Flathub requirements:
  https://docs.flathub.org/docs/for-app-authors/requirements
- Flathub submission flow:
  https://docs.flathub.org/docs/for-app-authors/submission
- Flathub MetaInfo guidelines:
  https://docs.flathub.org/docs/for-app-authors/metainfo-guidelines
- Flatpak documentation:
  https://docs.flatpak.org/
- Flatpak dependency guidance:
  https://docs.flatpak.org/en/latest/dependencies.html
