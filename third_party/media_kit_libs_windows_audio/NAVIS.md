# Navis changes

Copy of `media_kit_libs_windows_audio` 1.0.9 (MIT, see `LICENSE`) bundling
Navis's own audio-only LGPL-2.1-or-later Windows x86_64 libmpv. Upstream's
minimal 2023-09-24 engine lacks the FFmpeg `volume`/`biquad` filters needed
by the equalizer. The former zhongfly pin captured only mpv/FFmpeg sources;
our build captures all statically linked playback dependencies.

- `LIBMPV`, `LIBMPV_URLS` and `LIBMPV_SHA256` pin
  `libmpv-windows-x86_64-lgpl-20261013.zip`, built by
  `tool/libmpv/Dockerfile.windows` and `build_windows_lgpl.sh`.
- mpv `eb0ee1031590b3f369a5b783e8aa91eeaaded7e6` uses `gpl=false`;
  FFmpeg `151814650` uses Schannel TLS and no GPL/nonfree options. Both
  commits match the Linux recipe. Static libass, libplacebo (with submodules),
  FreeType, FriBidi, HarfBuzz and zlib sources accompany the archive.
- The stripped DLL imports only Windows system DLLs. GCC runtimes and
  winpthreads are static; toolchain versions and all flags are in BUILDINFO.
- Downloads use only the per-build Porthorion R2 folder and verify SHA-256,
  deleting failed downloads. A verified cached archive works offline.
- Extraction is per archive filename. ZIP preserves `libmpv-2.dll`,
  `include/mpv/*.h` and `libmpv.dll.a`; the plugin bundles only the DLL.

The release operator publishes the archive, SOURCES.md and every source
archive into `navis/third-party/libmpv-windows-x86_64-lgpl-<date>/`, with
no flat copy. Rebuild/update instructions are in `tool/libmpv/README.md`
and `docs/release/release-windows.md`. There is no upstream download fallback.
