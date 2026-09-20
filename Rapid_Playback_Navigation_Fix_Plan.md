# Rapid playback navigation reliability plan

## Goal and evidence

Rapid Next/Previous presses and queue-row selections must remain responsive on
every supported client. Every relative press counts toward the intended queue
position, while only the latest target needs to load. A later Pause or Stop
must never be undone by an older selection or recovery.

The September 2026 code inspection found several plausible causes. Next and
Previous enter an unbounded FIFO lane and await backend seeks without a
deadline. Queue supersession replaces a lane while its old asynchronous
operation can still touch the same player. Phase-one source preparation can
publish queue state before rechecking ownership. A later Pause can be followed
by an older autoplay. `just_audio` may return from `seek` without seeking while
the backend is loading. On desktop, sidecar cache cancellation changes a
generation number but does not stop the old HTTP request, and old cleanup can
remove a newer attempt's partial file. Existing helper tests pass, but they do
not exercise overlapping commands against the production handler. These are
code risks to reproduce and verify, not proof of a single root cause.

## Command and state contracts

1. Keep an authoritative logical queue and a desired entry separate from the
   backend's confirmed entry. Resolve each relative press from the desired
   entry while a transition is pending. An explicit row selection replaces the
   desired target; a subsequent relative press starts there. Preserve the
   existing three-second Previous restart rule, shuffle order, repeat behavior,
   duplicate queue entries, and queue boundaries.
2. Admit selection intent before asynchronous database reads, Match Flow
   expansion, source resolution, or player readiness. Carry the original
   request identity through all continuations. A late request must not obtain
   a new identity, replace a newer queue, or publish metadata.
3. Track intended Play/Pause state independently. Next/Previous preserve it;
   explicit selection follows its autoplay request. Later Pause, Stop, Clear,
   sign-out, radio transitions, or disposal override older work.
4. Retain the existing public playback method names and Future return types.
   Add a typed context for early queue-selection admission, and an optional
   pending logical index to playback snapshots. Update callers, wrappers, and
   test doubles together. Cancelled requests settle without user-facing errors.

## Playback implementation

1. Replace navigation FIFO and replaceable queue-lane behavior with one owner
   of structural player mutations. Keep one executing transition and one
   replaceable pending target. Source preparation may happen outside that
   mutation section, but must recheck ownership before backend use and before
   every state publication. Avoid nested lane waits. Play/Pause must remain
   responsive; never await the playback-duration Future from `play()` in a
   mutation section.
2. Scope operations to queue revision, selection revision, and player epoch.
   Capture the exact player instance. Check ownership at every asynchronous
   boundary, before retry/fallback/autoplay, before cache or persistence writes,
   and before emitting errors. Treat cancellation separately from failure.
3. A timeout does not cancel native work. Abort a superseded or timed-out
   backend operation through the supported stop/dispose lifecycle. Quarantine
   uncertain players, detach their listeners, and prevent retired players
   from remaining audible before replacing them. Keep initial four-second
   control and twelve-second load limits; add a 30-second overall deadline for
   the latest selection, including recovery. Bound player retirement and
   attach error handlers to late Futures.
4. Confirm that the backend reached the requested entry and usable state;
   returning from `seek()` during `loading` is not confirmation. Preserve the
   desired target and reconcile it after abort or readiness.
5. Maintain the complete logical queue during both loading phases and map
   logical entries to prepared backend entries. Prioritize the desired entry,
   then resume bounded background fill. Recheck between every preparation and
   insert. A timed-out insert has an unknown outcome and must be reconciled.
   Keep the active song and logical queue after background fill failures.
6. Make remote recovery and crossfade handoff subordinate to current intent.
   Preserve one remote retry and the existing fallback to the next playable
   song, but never let stale recovery skip or resume a newer selection. Remove
   the queue controller's unconditional post-replacement autoplay; the handler
   owns the accepted request's play state.
7. Inspect the vendored media-kit adapter's load completer. Make each load
   settle exactly once on success, interruption, error, or disposal if the
   regression harness demonstrates a stranded call.

## Secondary work and diagnostics

1. Abort cancelled sidecar HTTP operations. Assign each attempt a unique
   temporary file and ownership token. Only its owner can publish/register the
   final file or delete its temporary file. Test rapid A-B-A navigation.
   Preserve permanent downloads and source priority: permanent download,
   rolling cache, then direct stream.
2. Coalesce current-index and transport persistence through an ordered writer
   of immutable snapshots. Prevent a stale write from replacing a newer queue
   revision. Flush valid state on lifecycle boundaries.
3. Add bounded, redacted diagnostics for admitted/completed command sequence,
   queue revision, desired/confirmed index, active operation and age, pending
   count, superseded commands, timeouts, recoveries, and retired players. Keep
   titles, URLs, credentials, and raw backend errors out of this trace.
4. Add guarded Next and Previous diagnostics endpoints calling the production
   handler. A rapid-playback diagnostics runner must send overlapping requests,
   record admission order, and calculate the expected final entry from it.

## Tests and acceptance

Build a deterministic fake `just_audio` platform under the real audio handler
with controllable load, seek, insert, stop, disposal, and event completion.
Cover repeated and alternating skips; row selection followed by skips; delayed
database/source work; backend seek ignored while loading; Pause/Stop during
load and recovery; Clear/sign-out/radio switch; late timeout completion;
navigation during background fill; crossfade; shuffle/repeat; duplicate queue
entries; source kinds; slow persistence; and clean-restart restoration. Add
seeded command sequences that assert bounded pending work, single structural
mutation per player epoch, no stale publication, and eventual settlement.

Use an isolated Linux profile and a controlled HTTP audio fixture with valid
Range responses, delayed headers, stalled bodies, and failures. Exercise queue
sizes 1, 20, and 500 and bursts of 100 commands at 20-50 ms intervals. Include
playing and paused starts, phase-one and phase-two loading, crossfade on/off,
cached and remote sources, and active library sync. Verify desired-target
acknowledgment within 100 ms in the controlled test environment, healthy
fixture playback of the final target within two seconds after the last input,
one executing plus one pending transition at most, bounded failure recovery,
no stale autoplay or queue truncation, and no resource accumulation. Repeat
after a clean restart. Inspect app-owned screenshots and relevant logs. Run
Android, iOS, Windows, and macOS smoke checks when those hosts/devices are
available; record unavailable platforms accurately.

Before handoff, update architecture and development workflow documentation,
the 1.4.0 changelog and release-note generator, and any generated source
required by changed models. Run focused tests, analysis, `./tool/check.sh`,
review the complete diff, and repeat runtime acceptance after a clean restart.
The handoff must identify an original reproduction, failing-then-passing
regressions, latency/resource evidence, platform results, and limitations.
