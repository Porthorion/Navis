# Linux LGPL libmpv recipe

This Ubuntu 22.04 x86_64 recipe builds an audio-only LGPL-2.1+ `libmpv.so.2`
for Navis's Linux bundle. It pins mpv and FFmpeg in `build_linux_lgpl.sh`,
links FFmpeg, libass and libplacebo statically, and keeps desktop system
libraries dynamic. FFmpeg's libavfilter includes the equalizer filters.

From the repository root:

```bash
docker build -t navis-libmpv-lgpl tool/libmpv
docker run --rm -v "$PWD/out:/out" navis-libmpv-lgpl
```

Use an x86_64 host. The build needs network access and writes `libmpv.so.2`,
`include/`, `BUILDINFO.txt`, `Dockerfile`, `build.sh`, source archives under
`src/`, and `SHA256SUMS` to `out/`. `BUILDINFO.txt` records versions and ELF
`NEEDED` libraries. The script rejects FFmpeg `--enable-gpl`/`--enable-nonfree`
strings and requires mpv's embedded `-Dgpl=false` configuration. These checks
consume the complete strings output so shell pipe failures cannot hide a match.
Review source licences and configurations when changing pins; string checks
alone do not establish the licence of every dependency.

Package the binary and recipe with this layout (keep source archives separate):

```bash
mkdir -p out/libmpv-linux-x86_64-lgpl
cp -r out/libmpv.so.2 out/include out/BUILDINFO.txt out/Dockerfile out/build.sh \
  out/libmpv-linux-x86_64-lgpl/
artifact_date=$(date -u +%Y%m%d)
tar -czf "out/libmpv-linux-x86_64-lgpl-${artifact_date}.tar.gz" \
  -C out libmpv-linux-x86_64-lgpl
sha256sum "out/libmpv-linux-x86_64-lgpl-${artifact_date}.tar.gz"
```

Upload to R2 at `navis/third-party/libmpv-linux-x86_64-lgpl-<date>/` that tarball, `SOURCES.md` (versions, source URLs, SHA-256, LGPL configuration
and licence inventory), and every corresponding archive from `out/src/`,
including mpv, FFmpeg, libass and libplacebo with submodules. Preserve older
folders. Also copy the identical tarball to the flat path
`https://downloads.porthorion.com/navis/third-party/<tarball-name>` and verify it.
Update the filename, ordered URLs and SHA-256 in `linux/CMakeLists.txt`, plus
the in-app source location in `assets/licenses/libmpv-ffmpeg-NOTICE.txt`.
See [the Linux release guide](../../docs/release-linux.md) for the current pin,
runtime dependencies and packaging validation.
