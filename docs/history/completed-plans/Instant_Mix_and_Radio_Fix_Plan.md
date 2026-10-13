# Repair Navis mixes and rebuild Instant Radio

## Scope and evidence

Keep Last.fm Same Vibes and server mix as separate song-based choices. Make Home and Android Auto Instant Radio one balanced personal radio that uses likes, recent listening, and server recommendations, with playable local fallback while offline or while AudioMuse is indexing.

The reported incident has not been reproduced. Read-only investigation on 2026-09-19 found Navidrome 0.64.0, AudioMuse AI v3.6.1, and its enabled Navidrome plugin 9.0.0, with roughly 15% of analysis complete. Sonic recommendations worked for one indexed track; two other tracks were absent from AudioMuse's index, and Navidrome returned generic similar songs for them. The release Last.fm key returned 20 recommendations for *Tame Impala — Loser*; seven normalized titles appeared in the local library, which does not establish what Navis's matcher accepts. The desktop selected server mix, but the user could not confirm which mode produced the error. Forty-nine focused tests passed before unrelated playback edits appeared in the shared checkout. Re-run them on the implementation checkout.

Confirmed app defects include incorrect extension parsing, a server-mix call to an endpoint returning 404 before fallback, discarded partial Last.fm matches, false positive queue insertion counts, requests outliving stopped mixes, Home Radio's random liked-song seed and ignored start failures, and a separate Android Auto radio path. Preserve the unrelated dirty playback work in the shared tree.

## Work plan

1. **Reproduce through Navis.** Add clone-only authenticated mix diagnostics to start, stop, retry, and inspect both mixes and radio through production controllers. Report mode, operation, seed, stage, source, candidates, inserted count, error category, and retry state without disclosing secrets. Allow an explicitly permission-checked Last.fm key file for isolated diagnostics, with no key by default. Test seeds known to be indexed and absent from the plugin index, plus a known Last.fm match, recording app build and effective mode.
2. **Repair recommendation sources.** Add a Riverpod-provided, queue-independent service with typed outcomes. Parse standard and legacy OpenSubsonic extension shapes, retain saved JSON compatibility, and refresh capabilities for the current authenticated session. Use Last.fm matches then server fill for Same Vibes; `getSimilarSongs2` then the original standard `getSimilarSongs` for server mix, with the existing Navidrome `getInstantMix` only when both standard endpoints are unsupported; server, Last.fm, local taste, and eligible shuffle for radio. Preserve partial results, classify unsupported, empty, invalid key, rate limit, and network outcomes, and verify Last.fm player metadata belongs to the seed. Match eligible recordings before choosing duplicate editions. Keep bounded search and request limits. Production AudioMuse requests stay behind the server's standard similarity response; generic results must not be called AudioMuse results. This endpoint policy supersedes the original sonic-endpoint proposal after the user's portability clarification: plugin v9 documents `getSimilarSongs2` / `getSimilarSongs` interception, while sonic similarity is an additional extension that Navis need not call.
3. **Make sessions and queue commits truthful.** Use one coordinator for automatic sessions; existing song-mix notifiers can remain UI adapters. Give activations generation IDs and cancellable requests. Invalidate on stop, replacement, regular queue replacement or clear, sign-out, server change, and internet radio. Check ownership after every async stage and inside serialized queue commit. Return actual inserted IDs/count; zero is failure and partial count is partial success. Prepare a usable initial batch before altering the queue, preserving it on failure and retaining current song/play state for successful song mixes. Allow one refill at a time when three generated tracks remain. Apply bounded backoff, at most five transient attempts per seed, with explicit Retry after exhaustion. Persist generated tracks as ordinary queue entries and do not silently restart recommendations after app restart.
4. **Build balanced personal radio.** Use liked tracks and 60 distinct recent plays as anchors. Weight likes twice as strongly, favor overlap, then eligible library songs if taste is empty. Target ten tracks per batch, roughly seven related and three familiar, interleaved. Fill shortages rather than discarding partial batches. Exclude current/upcoming songs and the last 200 generated or played recording identities. Avoid adjacent same-artist songs, prefer two per artist per batch, relaxing for small catalogs. Apply Home's Liked only and Downloaded only filters to every song; downloaded means permanent downloads. Offline may use valid rolling-cache files when Downloaded only is off. Capture Home filters at start and re-evaluate connectivity/file availability on refill. Android Auto uses the same policy without Home filters. Stop when eligible music is exhausted. An empty standard similarity result is a seed-level outcome that can be retried later; Navis cannot infer the plugin index state from that response. Show a brief fallback notice once per source change without implying knowledge of scan progress.
5. **Wire controls and copy.** Await Home's radio action with a typed result, enable it for any eligible music, show busy/active/empty/actionable failure states, prevent duplicate starts, and open Now Playing after success. Keep saved song-mix choices and bundled Last.fm key precedence; label them **Server mix** and **Last.fm · Same Vibes**. Register Android Auto radio callback during playback bootstrap, return failure when zero tracks were inserted, and preserve Instant Mix's selected source and cold-start behavior. Localize source, loading, fallback, retry, and empty-library messages in the existing visual style.

## Validation and handoff

Add focused tests for capability and standard similarity parsing, fallbacks and partial matches, actual queue counts, cancellation/replacement/timeout races, radio composition and offline/download eligibility, Home states, and Android Auto cold start. Use deterministic fixtures, time, and random inputs. Run focused tests, generation when models or DAOs change, analysis, and `./tool/check.sh`.

Use an isolated Linux profile and the authenticated diagnostics API for both mix selections, seeds at different server-analysis stages, radio, refills, cancellation, and clean restart. Inspect app-owned screenshots for visible states. Validate Android sidecar and Android Auto via the prescribed emulator/DHU workflow where available. Update architecture, development workflow, troubleshooting, README, localization, changelog data, release-notes generator, and removal history for the replaced random-liked-song Radio behavior.

Final handoff must separate any reproduced cause of the incident from independently confirmed defects, state actual test and runtime evidence, and name any Android or full-index validation still outstanding. No database migration or server reconfiguration is planned.

## Reference contracts

- [OpenSubsonic endpoint reference](https://opensubsonic.netlify.app/docs/endpoints/getsimilarsongs2/)
- [Last.fm track.getSimilar](https://www.last.fm/api/show/track.getSimilar)
- [AudioMuse Navidrome plugin](https://github.com/NeptuneHub/AudioMuse-AI-NV-plugin)

## Implementation evidence (2026-09-19)

The app version was already set to `1.4.0+10400` in the shared checkout.
Implementation uses standard Subsonic similarity first and keeps the existing
Navidrome-specific fallback only after both standard endpoints report
unsupported. No direct AudioMuse endpoint was added. The unrelated playback
changes already present in the shared worktree remain in place.

On an isolated Linux clone using the configured server, the authenticated
diagnostics API reported app version 1.4.0 and selected Server mix. Three
server-mix seeds each inserted 50 tracks from the server source. With the
configured release Last.fm key supplied through an owned mode-600 file,
*Tame Impala — Loser* started Same Vibes with five matched Last.fm tracks.
Without that key, Same Vibes inserted five server fallback tracks. Personal
radio inserted ten tracks, then two further ten-track refills as the player
advanced to queue positions 7, 17, and 27. Downloaded-only radio inserted
two eligible files. When all three liked permanent downloads were already in
the queue, filtered radio returned zero insertion and preserved that queue.
Stopping during preparation also returned zero insertion and left a 30-track
queue unchanged. A clean restart reported an idle recommendation session while
the previous generated queue persisted as ordinary queue items. Home's ready
and active states were inspected through app-owned screenshots in the isolated
diagnostics artifact directory.

The original intermittent user symptom remains unreproduced; these runs
confirm the repaired paths but do not prove which mix mode caused the original
report. Standard similarity responses also cannot prove whether a seed is
absent from AudioMuse's index or simply has no server recommendations. The
Android Auto manifest verifier and phone-emulator service-first cold-start
gate passed. Physical-phone DHU projection and validation after
AudioMuse finishes indexing remain outstanding.

The focused mix, radio, Home, and settings suites passed. `./tool/check.sh`
passed with 1,421 tests and one pre-existing skip; release-note generation and
`git diff --check` also passed.
