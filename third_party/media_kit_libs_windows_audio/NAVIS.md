# Navis changes

Copy of `media_kit_libs_windows_audio` 1.0.9 (MIT, see `LICENSE`) with one
purpose: bundle a pinned, full libmpv build instead of media_kit's minimal
2023-09-24 build, which has no libavfilter `volume`/`biquad` filters (needed by
the equalizer) and comes from an archived repository that no longer receives
FFmpeg fixes.

Changes from upstream, all in `windows/CMakeLists.txt`:

- `LIBMPV`, `LIBMPV_URL` and `LIBMPV_SHA256` name the pinned shinchiro
  `mpv-dev-x86_64` archive, mirrored on the Navis Forgejo release
  `third-party-binaries` (provenance in that release's `SOURCES.md`).
- The archive is verified with SHA-256 (upstream used MD5), and a failed
  download is deleted.
- The archive is extracted to a folder named after it, so changing the pin
  always extracts the new build.

Updating the pin is described in `docs/release-windows.md`.
