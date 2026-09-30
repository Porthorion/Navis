# Performance audit — 2026-09-30

Scope: loading, sync, playback, caching, downloads, search, rendering and
memory on desktop (Linux) and mobile (Android), against the live Navidrome
0.64 server with a 56,300-track library (5,653 albums, 1,780 artists).

Measurement uses `tool/perf_diagnostics.py` (see `docs/development-workflow.md`):
an isolated profile build, bounded scenarios driven through the authenticated
diagnostics API, and one summary per run. "Before" is `63116df7` plus only the
diagnostics additions; "after" is the audit branch. Android numbers come from
an x86_64 emulator (Pixel 9 Pro XL profile, API 37), not a physical phone, so
they compare builds rather than predict device timings.

## Server and network baseline

- Round trip ≈100 ms; a new TCP+TLS connection costs ≈330 ms, so connection
  reuse matters. A typical API call takes 450–550 ms to first byte.
- `search3` with 500 songs: ≈650 KB, 1.3–1.8 s. `getArtists`: 700 KB, 1.2 s.
  `getAlbum`: ≈1.5 s. Responses are gzipped without `Content-Length`.
- `getCoverArt`: 70 KB full size, 6 KB at 150 px, 17 KB at 300 px.
- FLAC tracks are 25–50 MB; stream first byte ≈0.5 s at ≈7 MB/s.

## Findings and changes

| Area | Finding (before) | Change |
|---|---|---|
| Queue fill | Each native insert re-sent the whole shuffle order; just_audio's shuffle/loop streams re-emitted on every insert and each queued a full queue-state write (8,926 writes for one 2,000-song fill). | Batched inserts (8, then 64), concurrent source resolution, `distinct()` shuffle/loop subscriptions, after-start songs first. |
| Desktop backend | Vendored `just_audio_media_kit` reversed multi-source inserts before the end and emitted two playback events per child. | Ordered inserts; one event per insert. |
| Lyrics | Replacing a queue prefetched lyrics for every song (2,000 live providers and requests). | Prefetch the selected song and the next two; narrow the media-item dependency. |
| Cold start | A saved queue resolved every song before readiness; a 10 s timeout deleted the saved queue. | Restore current item first, fill in the queue lane; keep the queue on timeout. |
| Reorders | Each reorder rewrote the whole queue (192 rewrites during one artist shuffle). | Coalesce full-queue writes after a reorder burst. |
| Artist playback | Snapshot re-read and publish after every hydrated release. | Publish at most once per second (first release immediately). |
| Local search | Loaded all 56k songs into Dart per query; non-Latin text was stripped, so Arabic/CJK queries returned an unrelated top 20. | `song_search_text` derived index with SQL subsequence prefilter; Unicode-aware normalization (schema 86). |
| Providers | Per-song/per-page families never disposed; one database watch per Downloads row. | Auto-dispose families, `select` per row, one joined Downloads query. |
| Progress | Sync progress published per artist/album; download progress written per network chunk; one usage row per HTTP request. | 250 ms sync throttle, 1 % download steps, 5 s usage aggregation. |
| Rendering | Mini players and the desktop mini player rebuilt entirely on every position tick; collapsed Now Playing kept ticking; lyrics rebuilt every line per tick. | Position-watching leaves in `RepaintBoundary`, disabled `TickerMode` when collapsed, line-quantized lyrics position. |
| Database | Default `synchronous`, 2 MiB cache; no reverse indexes for queue/playlist/artist lookups; album lists re-ran on every song write; responses were JSON-re-encoded on the UI isolate to count bytes. | PRAGMAs, reverse indexes, narrowed `readsFrom`, received-byte accounting. |
| Misc | Whole-table loads to pick a few songs; per-track TLS for Android notification art; O(n log n) string fingerprint of the library on each Discover refresh. | Bounded queries, shared keep-alive client, O(n) hash fingerprint. |

## Results

Paired final runs in one session (same machine, server and catalog). Lower is
better unless noted. Queue scenarios use random catalog songs; the artist
scenario shuffles the largest artist (3,590 songs across 310 releases).

Linux profile build:

| Scenario | Before | After |
|---|---|---|
| 2,000-song queue: first audio | 2.1 s | 0.35 s |
| 2,000-song queue: fill complete | 16.6 s (43 s in the first baseline run) | 4.5 s |
| 10,000-song queue: fill complete | 207.5 s | 31.2 s |
| Artist shuffle to completion | did not finish within 240 s | 10.1 s |
| Saved queue: handler ready after restart | 12.1 s | 2.6 s |
| Local song search p50 / worst | 1,056 / 1,100 ms | 37 / 168 ms |
| DB read p95 during library deep scroll | 1,702 ms | 10 ms |
| Live lyrics providers after a 2,000-song queue | 2,000 | 2–3 |
| Idle while playing, CPU (Home / Now Playing) | 25.9 % / 20.7 % | 11.2 % / 9.6 % |
| RSS after search | 1,045 MB | 821 MB |

Android emulator (three paired 2,000-song runs, then one full run each):

| Scenario | Before | After |
|---|---|---|
| 2,000-song queue: first audio | 0.43–0.53 s | 0.35–0.63 s (unchanged) |
| 2,000-song queue: fill complete | 12.6–18.2 s | 1.5–2.0 s |
| DB read p95 during that fill | 481–876 ms | 0.7–7 ms |
| Idle while playing, CPU (Home) | 19.7 % | 8.3 % |
| Local song search p50 / worst | 1,161 / 1,322 ms | 46 / 175 ms |
| Library scroll frames over 16 ms | 43 | 34 |
| Saved queue: handler ready after restart | 3.6 s | 2.4 s |

Library deep-scroll frame p99 did not improve on Linux (20 ms before, 41 ms
after). The after profile's cover cache was warm from earlier runs, so covers
decoded in bursts instead of arriving over the network; grid decode sizes are
in the pending batch. Idle and paused, both builds settle at 0 fps.

Artist shuffle still hydrates stale releases one at a time; before the
reorder and publish changes, one Android probe showed 192 full-queue rewrites
(22 s of database writer time) for 16 releases.

## Pending (overlaps uncommitted UX work)

These changes touch files with uncommitted edits from the concurrent UX
session and wait for that work to land: `albumProvider` auto-dispose with an
aggregated album download summary (2,322 live instances after one deep grid
scroll), the desktop player bar position leaf, `ref.listen` for sync state in
the shell and narrower Home/Library sync watches, Home's radio catalog
(`getAllSongs` on every song write, the main source of DB contention during
artist hydration), grid cover decode size, and the changelog/release notes.

## Known limits

- Desktop queues above ~5,000 songs keep playing immediately but fill slowly:
  media_kit/libmpv cost grows per inserted child (2,000 songs ≈4.5 s,
  10,000 ≈31 s). The largest artist in this library has 3,590 songs.
- Stale artist releases hydrate one at a time under the coordinator's single
  execution lease (≈2.5 s per release on this server).
- Desktop fetches each uncached track twice (stream plus rolling-cache
  sidecar); documented in `docs/architecture.md` Cache Flow.
