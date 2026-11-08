# Demo library

40 CC0 or public-domain tracks in 6 albums for the demo Navidrome. Licence policy:
CC0 1.0 or public domain for **both** composition and recording; no BY, NC or ND.
Per-track evidence: [LICENSES.md](LICENSES.md).

## Rebuild

```
./build-library.sh <output-dir>
```

Host needs only `docker`, `curl` and `sha256sum`. Re-runnable: downloads are cached in
`<output-dir>.cache` (outside the library so Navidrome never scans it) and every source is
checked against its sha256 in `manifest.tsv`; a mismatch aborts. Tagging runs in the
`Dockerfile` image (pinned Alpine, ffmpeg, mutagen, ImageMagick); files are re-tagged, never
re-encoded (MP3, FLAC and OGG stay as published).

`manifest.tsv` columns: sha256, source URL, source page, target path, album artist, album,
track artist, title, track, track total, disc, disc total, year, genre, compilation flag,
licence, lyrics file. Komiku is a two-disc album (tracks 1-6 disc 1, 7-12 disc 2);
"Public Domain Voices" is a compilation by "Various Artists".

## Method

- **ReplayGain** (all tracks and albums): `ffmpeg` `ebur128=peak=true` integrated loudness,
  gain = -18 LUFS minus loudness, peak = true peak (linear). Album values come from the
  album's files played back to back; album peak is the largest track peak. ffmpeg prints
  loudness to 0.1 LU, so gains have that resolution.
- **Lyrics**: sidecar `.lrc` next to the audio (Navidrome 0.64.2 default `LyricsPriority`
  reads it and serves it through `getLyricsBySongId`). Timings come from `ffmpeg silencedetect`
  (-35 dB, 0.15 s) pauses between phrases (Daisy Bell: five pauses give the six line starts
  exactly; Twinkle: pauses mark stanza and phrase starts, the sung repeat of lines 1-2 in
  stanzas 1-4 is an assumption), checked for monotonic timestamps inside the duration.
  Not verified by ear. La Guerre (polyphonic, one 6-minute stretch without pauses) has none.
  Texts: Daisy Bell (Dacre, 1892), The Star (Jane Taylor, 1806).
- **Covers**: ImageMagick gradient plus title, 800x800 JPEG `cover.jpg` per album, also
  embedded. Original work, CC0 1.0; the sources' own artwork is not used.

Check a built library with `DEMO_TEST_MUSIC=<output-dir> ../selftest.sh`.
