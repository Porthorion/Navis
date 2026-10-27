# Playback validation coverage and evidence

Task A inventory, 2026-10-26, based on `origin/dev` `3e5bf9e06`.
This is a coverage map, not an execution certificate. No builds, runtime
matrix, Flutter gate, emulator or hardware validation was executed for this
inventory. Current implementation and the owning
[workflow](development-workflow.md#playback-runtime-harness) and
[CI guide](ci-cd.md) remain authoritative.

## Retained fixture matrix

`tool/playback_harness.py` extends `tool/live_seek_stress.py`; there is no second
engine. Identity is `(case, quality, throttle, rep)`, with zero-based repetition.
All current qualities/throttles are singleton dimensions. Counts below are
**per variant**; base and fix must each provide every cell exactly once.

| Scenario | Full cases | Reps | Linux cells | Android cells | Configuration / requirement |
|---|---:|---:|---:|---:|---|
| seek | 10 | 3 | 30 | unsupported | opus128, wan6000, offset verification |
| stress-drag | 2 | 5 | 10 | 10 | opus128, wan6000; sockets, GETs, heartbeat, release latency |
| memory-soak | 1 | 3 | 3 | 3 | opus128, wan6000, VM; Pss + SwapPss slope/total, Dart heap |
| repeat | 9 | 3 | 27 | 27 | opus128, wan6000, 30× transcodes; wraps, fill, readiness/local seeks |
| crossfade | 3 | 3 | 9 | unsupported | opus128, unthrottled, 4-second crossfade |
| cut-recovery | 7 / 8 | 3 | 21 | 24 | opus128, slow1500, offset verification; Android adds cut5 |
| local-seek | 3 | 3 | 9 | unsupported | original, wan6000; download/cache landing and latency |
| queue-edit | 3 | 3 | 9 | 9 | opus128, wan6000; edits during fill |
| **Total** | **38 / 23** | | **118** | **73** | **236 Linux + 146 Android A/B cells** |

Exact retained case lists, assertions and tolerances live in `SCENARIOS`,
`ANDROID_CHECKS`, `plan`, `evaluate`, and engine case/oracle functions. No case,
repetition, assertion, threshold or platform gate is removed by this change.
The Android splice gate still requires a cut observed on the base, no fix
reload/player errors, one continuation per cut, RMS <= 0.005 and decoded length
within 20 ms. Existing base-relative violations remain base-relative; a green
comparison does not mean every underlying cell is violation-free.

Before this change, `run_scenario` trusted the number of rows. It now compares
the complete cell identities and rejects duplicate, missing, foreign or malformed
cells, including an equal-sized wrong report. Engine exit 1 remains supported
because baseline-relative comparisons deliberately allow some failed cells;
Exit codes and cell verdicts must agree in both directions, and each cell's
verdict must agree with its hard violations. Collection and evidence reuse both
reject contradictions.

`--map`, quick mode, explicit subsets and `--reps` overrides support iteration.
Their successful evidence never establishes final playback coverage. Only
`--all --full` without overrides is labelled `full-platform`, and even that
covers only its named platform. The final `gate` requires both Linux and Android platforms
and the normal quality gate; the separate requirements below remain outstanding.

## Requirements beyond the matrix

| Requirement | Existing executable / owning reference | Coverage gap to retain |
|---|---|---|
| App correctness and warning guards | `./tool/check.sh`; [CI](ci-cd.md); `.github/workflows/ci.yml` | Formatting, generation, analysis, dead code, migrations, critical reliability and full Flutter tests stay required. CI has separate app-level jobs/shards; it does not execute this runtime matrix or every local tooling check. |
| Harness self-check | `python3 tool/playback_harness_test.py` | Deterministic orchestration/oracle tests; cannot certify audible/native playback. Called by check.sh and the focused CI tooling job; orchestration tests remain separate from runtime acceptance. |
| Early/overlapping/paused seeks, codecs and Range faults | `tool/seek_reliability_diagnostics.py --platform linux` and Android variant; [CI guide](ci-cd.md) | WAV/MP3/FLAC/Opus and supported versus unsupported Range outcomes remain separate runtime evidence. |
| Live remote seeks/recovery | `tool/live_seek_stress.py`; [live-server workflow](development-workflow.md#live-server-seek-stress) | Disposable live account, throttled/unthrottled Linux and Android; manual credentials gate, fixture success cannot replace it. |
| Rapid navigation and large queues | `tool/rapid_playback_diagnostics.py` | Overlapping Next/Previous, Pause during selection, 500-song option, screenshot and clean restart. |
| Artist queue fill | `tool/artist_playback_diagnostics.py` | Production artist shuffle/fill, eventual growth without modal and restart; separate from repeat fixture coverage. |
| Settings and indicators | `tool/playback_settings_diagnostics.sh`, `tool/playback_indicator_diagnostics.sh` | Persistence, preference/visible player behavior, API and screenshot assessment remain separate. |
| Speed, pitch and equalizer | `tool/playback_adjustment_diagnostics.sh`, `tool/equalizer_diagnostics.sh`, `tool/android_equalizer_diagnostics.py`, `tool/equalizer_native_test.sh` | Native PCM, presets/linked controls, restart and Android bridge/lifecycle; Linux measurements do not certify other hosts or physical listening. |
| Android media-service and recovery position | Gradle `NavisAudioServiceRecoveryTest`, `JustAudioRecoveryPositionTest`; [CI guide](ci-cd.md#android-media-service-upgrade-contract) | Native reflection/unit checks plus profile-clone runtime recovery fixtures; neither replaces the other. |
| Android Auto / MediaSession | [emulator tests](../platforms/android-auto-testing.md), [real-car checklist](../platforms/android-auto-real-car-testing.md) | MediaBrowser cold start/playback/artwork and service-first behavior; DHU projection, real car and real phone remain distinct certification. |
| Desktop media controls | Linux app-owned MPRIS; `tool/windows_smtc_diagnostics.ps1`; [architecture](../architecture.md) | Linux runtime service evidence, native Windows host evidence; the Linux fixture matrix does not establish Windows SMTC behavior. |
| Apple / physical lifecycle | [macOS playbook](../platforms/macos-testing-playbook.md), platform guides | Apple native runtime deferred while development unavailable; macOS controls incomplete. iOS, audio focus, Bluetooth, background/lock-screen, route changes and audible listening need applicable device evidence. |
| Runtime isolation and visual acceptance | [development workflow](development-workflow.md) | Authenticated diagnostics, owned isolated profile/downloads, clean logs, persistence and clean restart; inspect app-owned PNGs. No automated file existence check establishes visual acceptance. |

All rows are requirements/inventory only, **not claimed execution**. Apply the
owning docs' change-specific gates; do not infer coverage from a similarly named
fixture case or from a mocked orchestration test.

## Durable evidence contract

Each A/B invocation writes `build/harness/<UTC-microsecond-stamp>/evidence.json`
before build/preflight work. Atomic replacement leaves an incomplete record on
abrupt termination; graceful failure/interrupt records its type and exit 2.
Selected variants start as `not-run`. Repetitions run interleaved, not variant by
variant: base r1, fix r1, fix r2, base r2, base r3, fix r3, ... (the first variant
swaps on every other pair, so host drift and run order hit both equally; an A/A
uses the same schedule). Each repetition is its own engine invocation numbered at
its own index and keeps its attempts' evidence/logs under
`<base|fix>/<scenario>/rep-R/attempt-N/` (a repeated emulator boot or dead guest
is a new attempt; a retry cannot borrow a prior report). After the last
repetition, or when the run stops part way, they merge into the one record the
verifier and gate read, `<base|fix>/<scenario>/attempt-1/` (all cells in matrix
order, one `report.json`, one concatenated log; `incomplete` unless every
repetition completed). Cell inventory, repetition counts and thresholds are
unchanged by the interleaving.
Reports from failed/timed-out attempts are retained, with observed partial cells
when readable. Timeout never becomes a passing comparison.

Schema 1 contains:

- candidate HEAD and a SHA-256 identity over all tracked source bytes/modes,
  index entries, deletions, symlink targets and all nonignored untracked files;
  only hashes/counts are persisted, never source or credential contents;
- exact resolved base, normalized `flutter --version --machine` identity (including
  framework/engine revisions and Dart SDK), configuration/selected scenarios,
  platform scope, kernel/architecture/Python, stable relevant-environment hash,
  data root/suffix and emulator configuration;
- expected/observed cell identities, per-cell pass/fail, variant completion,
  engine exit codes, build/scenario/overall elapsed time, attempt log/report
  pointers, base artifact hash and retained artifact hashes;
- candidate identity after execution and terminal status/exit code.

Ignored files are excluded from candidate identity, and so is exactly one tracked
path, `docs/project/progress.md` (both its content and its index entry): evidence
is recorded there after the run, which must not invalidate the run. Any other
docs/tooling edit, and a commit that changes HEAD, still invalidates the evidence. Existing build outputs and
local secrets must remain ignored; do not put an evidence output directory into
tracked source. Environment values are hashed rather than exposed. Evidence and
logs remain local diagnostic artifacts, not suitable for public upload without
review. External SDK contents, cached AVD image contents, host load/temperature,
physical devices and an edit reverted between identity snapshots are not fully
attested by this record. No claim of reproducible hardware timing is made.

`comparison.json` and `summary.md` retain their existing successful-completion
contracts; a completed FAIL comparison keeps its detailed per-check `summary.md`
(only incomplete or blocked runs get the short status summary). A passing
comparison writes `RESULT UNVERIFIED` and an `incomplete`/exit 2 `evidence.json`;
both are promoted to `RESULT PASS` / `passed` only after `verify_evidence` succeeded
on the in-memory record (evidence first, then an atomic summary rename), so a run
killed during finalization never reads as a pass. `RESULT PASS|FAIL` is printed
only after finalization. `ab --map` with no playback change records status `none`.
Standalone `ab` stores the resolved base SHA in its configuration, so its evidence
can match the gate's required configuration for `--reuse-*`. Failures before comparison completion still have `evidence.json`;
absence of comparison is never a pass. `verify_evidence(out, candidate,
environment, config)` is the Python integration seam for task B: provide the
current candidate/environment and the exact required config (including resolved
scenario names). It rejects stale/unsuccessful records, wrong/missing variants
or cells, invalid base rows, failed recomputed thresholds, missing/malformed
reports and missing/changed artifacts. It does not confer a full-gate certificate
or run another validation job. The gate supplies the currently required resolved `baseSha` and `flutter` in
config, and enforces the required `full-platform` scope before reusing evidence.
Android scenario order follows dispatch, including cut-recovery; no subset or real-server
invocation can substitute for the configured full fixture matrix.

## Follow-ups and integration boundaries

The existing playback-151 triage rows 24–27 and 29 / P4 already own paired
base/fix repetition order, emulator partial-acquisition cleanup, repeat-fill
zero/short-duration behavior, Linux cut-failure cause proof, and Android order
calibration. This task preserves that schedule and all tolerances; it neither
claims those issues fixed nor duplicates their probes. Coordinate future hot-file
edits with P4/P5. Existing r2/r3 review briefs already prohibit duplicate heavy
validation and reuse earlier probes; this inventory does not replace that policy.

Task B extends this harness with `gate`, the paired heavy-job locks, bounded
builds/commands, verified inherited ownership, check.sh retained capture and the
[owner/reviewer protocol](development-workflow.md#final-fixture-gate-and-ownership).
One owner holds both locks for the full gate, preventing a duplicate active gate
for the same candidate (and serializing other heavy candidates on this host).
Task C owns actual full gate/runtime execution, independent review and progress
evidence. No Flutter/runtime acceptance is claimed by tooling self-checks.

## Task A focused verification

`python3 tool/playback_harness_test.py`: 72 tests passed (and `python3 tool/validation_gate_test.py`: 42), including
retained threshold/oracle probes and new deterministic failure, partial-report,
timeout, interruption, build-exit, exact-cell, stale-source/environment/config,
artifact and successful-finalization checks. Python byte-compilation,
`git diff --check`, and local link-target checks passed. These results are
self-check evidence only; task C still owns full Flutter and runtime execution.

## Task B stable identity and final-gate boundary

The before/after commands, explicit `--reuse-linux`/`--reuse-android` invocation,
unique run directories, bounded deadlines, fail-fast ownership and cancellation
protocol are in the [workflow](development-workflow.md#final-fixture-gate-and-ownership).
The gate runs check.sh and all Linux and Android scenarios serially. It verifies
fresh matrices too: exit 0 alone is insufficient. Missing/corrupt artifacts,
malformed finalization, changed candidates, stale configuration, incomplete
platforms or timeout cannot produce a passing gate. A failure summary is retained
alongside evidence; finalization errors do not replace the original command error.

Environment identity hashes selected relevant names/values, not all inherited
shell/systemd/orchestrator state. It includes all `NAVIS_` (except the scope
recursion marker), `FLUTTER_`, `DART_`, `PUB_`, `GRADLE_`, `JAVA_`, `ANDROID_`,
`LD_`, `DYLD_`, `CMAKE_`, `CCACHE_`, `PKG_CONFIG_`, `JDK_`, `CARGO_`,
`RUSTUP_`, `LC_`, `QT_`, `KWIN_`, `GDK_`, `GST_`,
`PIPEWIRE_`, `PULSE_`, `ALSA_`, `MESA_`, `LIBGL_` and `VK_` variables. It also
includes PATH, HOME/USER/SHELL, locale/timezone/temp root, CC/CXX/compiler/linker
flags (including RUSTFLAGS and `_JAVA_OPTIONS`), display/Wayland/XDG runtime/data/config and D-Bus locations, CI, proxy and
certificate configuration, and the shuffle-shot label. Exact names live in
`environment_identity`. Changed relevant values conservatively invalidate reuse,
including hashed secrets; values are never printed. Process counters, task IDs,
PWD, SHLVL, `_`, terminal styling and systemd invocation IDs do not affect reuse.
Use the same relevant runtime session configuration in command/reviewer processes.

This identifies declared source/configuration, not the contents of external SDKs,
AVD images, ignored files or physical devices. Changed external SDK/image/local
configuration contents require new evidence even when their paths stay equal;
record that reason. New environment-controlled playback/build inputs must be added
to this selection with a regression test. Source identity has no broad path ignore
for reuse; tooling/docs changes also invalidate prior exact-state evidence.

A matrix that dies by signal or exits other than 0/1 (137/143 included) is `blocked`
(exit 2), as is `check.sh` dying by signal; only a plain non-zero check.sh exit or
an ab exit 1 is `failed`. A step is marked passed only after its evidence verified.
The self-checks are hermetic: they redirect the heavy locks, harness cache and
evidence output to a temporary directory and never touch the real lock files.

A `check.sh` that did not pass (failed, timed out or blocked) stops the gate: the
Linux and Android steps are recorded as `not-run` ("skipped: check <status>") and
the gate keeps check's status (`failed`/exit 1, `blocked`/exit 2), never passed. A command that dies of a signal (for example an OOM SIGKILL) is reported
with its exact negative exit and "command killed by signal N", without an owner
traceback. Direct `ab` holds the heavy-lock descriptors across its build, engine
and bootstrap commands and the headless KWin and emulator children, so a killed
holder keeps the lock while any of them runs.

`gate.json` / `gate-summary.md` retain command vectors, actual command exits,
step exits/statuses and log/evidence pointers. A reused platform has no new command
exit and points to verified prior evidence. `acceptance` and each beyond-matrix
requirement remain explicitly outstanding, with applicability. There is no
self-certifying boolean or automatic promotion of external acceptance. Reviewers
must assess applicable external/native/device/manual evidence against the owning
reference, with candidate/configuration, commands, real exit results and inspectable
artifacts; absent evidence stays outstanding. The gate does not ingest an external
"complete playback passed" declaration. The 118 Linux / 73 Android per-variant
cells, all repetitions, thresholds and assertions remain unchanged.

### Nested timeout ownership self-check

`python3 tool/validation_gate_test.py ProcessCleanup` runs small real Python
process trees, including nested bounded owners, separate-session children and
grandchildren, ignored TERM, and a parent that exits before cleanup. It checks
that timeout/cancellation retains the original error, no recorded descendant
survives, inherited ownership stays locked during cleanup and becomes available
afterward, and an unrelated control survives. Linux subreaper adoption and pidfds
support this contract; other hosts fail closed. This does not certify real
app/emulator/display teardown, external service-launched processes, host failure,
or forced death of the outermost cleanup owner. Kernel tasks that cannot exit
keep the lock held rather than permit another platform to overlap. Full gate
and platform runtime evidence remain outstanding.
