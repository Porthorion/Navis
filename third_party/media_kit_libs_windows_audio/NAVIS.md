# Navis changes

Copy of `media_kit_libs_windows_audio` 1.0.9 (MIT, see `LICENSE`) with one
purpose: bundle a pinned, full libmpv build instead of media_kit's minimal
2023-09-24 build, which has no libavfilter `volume`/`biquad` filters (needed by
the equalizer) and comes from an archived repository that no longer receives
FFmpeg fixes.

Changes from upstream, all in `windows/CMakeLists.txt`:

- `LIBMPV`, `LIBMPV_URLS` and `LIBMPV_SHA256` pin the zhongfly/mpv-winbuild
  `mpv-dev-lgpl` x86_64 variant (LGPL-2.1+): mpv v0.41.0-1104-geb0ee1031
  with `-Dgpl=false`, FFmpeg N-127222-g151814650 without `--enable-gpl`.
  The `volume` and `biquad` filters are present.
- Downloads try the Porthorion R2 copy, then upstream, verifying SHA-256 on every attempt and deleting failures.
  A verified cached archive is reused offline. The mirror preserves daily
  builds pruned upstream, with `SOURCES.md` and mpv/FFmpeg source tarballs.
- The archive is extracted to a folder named after it, so changing the pin
  always extracts the new build.

Updating the pin is described in `docs/release-windows.md`.
