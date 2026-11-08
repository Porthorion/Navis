# Navis changes

Copy of `media_kit_libs_macos_audio` 1.1.4 (MIT, see `LICENSE`) bundling
Navis's own audio-only LGPL-2.1-or-later universal (arm64 + x86_64) libmpv.
Upstream downloads media-kit's libmpv-darwin-build v0.6.0 (mpv 0.36, FFmpeg
6.0, Mbed TLS), whose libavfilter lacks the `volume`/`biquad` filters the
equalizer needs and whose Mbed TLS cannot read the macOS trust store.

- `macos/fetch_libmpv.sh` pins `LIBMPV`, `LIBMPV_URL` and `LIBMPV_SHA256`
  (`libmpv-macos-universal-lgpl-20261104.tar.gz`, built by
  `tool/libmpv/build_macos_lgpl.sh`). The podspec runs it on every
  `pod install` and raises if it fails. CocoaPods only re-evaluates the
  podspec on `pod install`, so after changing the pin (or the archive named by
  `NAVIS_LIBMPV_MACOS_ARCHIVE`) delete `macos/Pods/Manifest.lock`, or run
  `flutter clean`, to make the next build re-run it.
- mpv `eb0ee1031590b3f369a5b783e8aa91eeaaded7e6` uses `gpl=false` and carries
  one patch (`tool/libmpv/patches/mpv-macos-coreaudio-channelmap.patch`: drops
  a CoreAudio call current macOS rejects, as mpv master did); FFmpeg
  `151814650` uses Apple SecureTransport TLS (system trust store) and no
  GPL/version3/nonfree options. Both commits match the Linux and Windows
  recipes. Static libass, libplacebo (with submodules), FreeType, FriBidi and
  HarfBuzz sources accompany the archive; the framework links only Apple
  system libraries.
- A single `Mpv.xcframework` replaces upstream's Mpv, Avcodec, Avformat,
  Avfilter, Avutil, Swscale, Swresample and Mbed TLS frameworks;
  `media_kit` loads `Mpv.framework/Mpv`.
- Downloads use only the per-build Porthorion R2 folder and verify SHA-256
  (a mismatch deletes the file and fails). A verified cached archive works
  offline, and `NAVIS_LIBMPV_MACOS_ARCHIVE=/path/to/<tarball>` supplies a local
  archive (still checked against the pin) before it is published.
- Deployment target 12.0, matching `macos/Podfile`.

The release operator publishes the tarball, SOURCES.md and every source
archive into `navis/third-party/libmpv-macos-universal-lgpl-<date>/`, with no
flat copy. Rebuild/update instructions are in `tool/libmpv/README.md` and
`docs/release/release-macos.md`. There is no upstream download fallback.
