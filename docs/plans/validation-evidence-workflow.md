# Validation evidence workflow

Status: investigation and implementation open, 2026-10-26.

## Objective and constraints

Preserve the complete applicable playback regression matrix while reducing
manual command orchestration and repeated evidence reconstruction. No scenario,
assertion, threshold, platform check or manual certification is removed. Focused
tests support iteration; they never replace the final full playback gate.
Do not change application behavior, global agent/model policy, or other projects.
No publication, pull request, merge or deployment is authorized by this plan.

## Verified starting point

The initial local dev checkout was older than the consolidated harness. This
topic starts from available origin/dev at 3e5bf9e06, with unreleased 1.5.1.
Other playback fixes occupy separate worktrees; do not edit them.

Existing infrastructure to extend:

- `tool/playback_harness.py`: SCENARIOS, ANDROID_SCENARIOS, plan, run_scenario,
  cmd_ab, base_build, metrics and evaluate; uses live_seek_stress.py as its engine.
- Existing full matrix: eight Linux scenario groups; five Android groups,
  including Android-only cut-recovery additions. Preserve all full cases and
  repetitions. The map and quick modes are iteration aids, not final coverage.
- `tool/playback_harness_test.py`: threshold, invalid-base, mapping, cache and
  environment self-checks; reuse proven failure probes.
- `tool/check.sh`, `tool/lib/check_test_log.sh`, and CI: full test suite and
  failure/warning guards. Preserve their checks and assertions.
- Runtime docs already specify clone isolation, authenticated diagnostics,
  clean restart, screenshots and platform-specific/manual evidence.

Observed gaps: cmd_ab writes comparison/summary only at completion, records
dirty state as a boolean, and checks engine cell counts without exact identity.
Its cache lock is separate from the established /tmp/navis-heavy.lock convention.
check.sh streams full logs and deletes captured logs on exit; run_step_capture
checks the producer status but not tee's status. These need failure-path tests.
Existing review briefs already prohibit duplicate heavy execution and reuse
earlier probes: preserve this policy rather than inventing a replacement.

Local session records establish a specific ownership failure: the two r2
reviewers were active from approximately 15:10 to 15:40/15:41 UTC. At 15:41:55
the orchestrator recorded that the rate-limited predecessor resumed by itself
after a replacement started, and both used the same review scratch directory.
The replacement was then cancelled. This demonstrates overlapping ownership,
not that every probe or finding was redundant. Retain cancellation confirmation
and unique run directories in the replacement handoff. Raw workload figures
from the incoming brief are not independently certified quota/cost estimates.

Task A delivered 2026-10-26: current full matrix is 118 Linux and 73 Android
cells per variant, 382 A/B cells total. Sixty focused Python self-checks passed
according to the implementation run. Astra inspected the diff and engine cell
schema; integration review remains open. See
[coverage map](../development/playback-validation-coverage.md). Before task B,
remaining concerns include stable cross-command environment identity, useful
human summaries on failure, preserving original errors during finalization,
and distinguishing the fixture matrix from broader platform acceptance.

Task B delivered the serial fixture gate, shared ownership, retained capture
logs, bounded commands, CI self-checks and canonical handoff guidance. Its
implementation run passed 60 harness and 20 gate self-checks (62 and 34 after the r1 review fixes). Independent
review found a reproduced nested-timeout cleanup race, inconsistent cell/exit
verdict validation, and missing NumPy setup guidance. The verdict and setup
issues are repaired; ten focused evidence tests passed. Nested-session cleanup
must be repaired and tested before launching the full validation owner.

Nested-timeout repair delivered: private Linux subreaper ownership retains
locks while adopting and reaping orphaned descendants, using pidfds for safe
signalling across separate sessions. The implementation run passed 21 gate
self-checks and three focused cleanup tests (including timeout, cancellation,
exited parent, TERM resistance and an unrelated live control). Astra reviewed
the ownership code. Linux-only support and forced outer-owner death remain
explicit limits. Task C is now the sole full-gate owner; freeze source during
its run. Keep source identity and raw evidence in ignored build artifacts.

## Bounded tasks and ownership

Astra owns investigation, acceptance decisions, integration and final review.
All implementation delegates use explicit gpt-6.1-sol, serviceTier priority,
verified against the live catalog. Run tasks serially across shared hot files;
one active validation owner per candidate. No delegate starts another delegate.

1. **Coverage and evidence contract** (Sol task A). Own a durable coverage map
   under docs/development and harness evidence changes/tests only. Inventory
   requirements, engine cells, standalone diagnostics, CI/native/platform and
   manual-only gaps. Extend current harness records to capture candidate
   content identity (including relevant untracked files), base, environment,
   config, expected/observed cells, per-scenario status, exit codes, timings and
   artifact paths. Persist incomplete/error outcomes and reject duplicate or
   missing cells. Never label a partial run passing. Add small deterministic
   tests for failure, timeout, missing/corrupt artifacts, stale identity and
   interrupted execution. Do not launch heavy validation in this task.
2. **Bounded full gate and ownership** (Sol task B, depends on A). Extend existing
   harness/check entry points rather than create a second framework. Provide
   one documented final invocation retaining full Linux and applicable Android
   matrices and check.sh; other platform/manual requirements stay explicit.
   Reuse the established heavy-job lock, prevent duplicate candidate execution,
   bound commands and retain logs. Ensure check.sh propagates capture failures.
   Test contention, incomplete runs and exact-state evidence checks. Update
   workflow, CI documentation and canonical agent policy; add concise builder,
   runner and independent-review handoffs with rerun reasons and cancellation
   before replacing an owner. Do not alter global instructions.
3. **Validation and independent review** (Sol task C, depends on A/B). One owner
   executes tooling self-checks, check.sh and the full applicable playback gate,
   with disk logs and bounded returned output. Reuse existing probes/mutants
   where practical to show regression detection. Astra independently reviews
   implementation and coverage, requests focused probes or reruns for concrete
   gaps, and records limitations. Never infer passing hardware coverage from
   mocked orchestration tests. Update progress with real evidence.

Tasks may be split further after the coverage inventory, keeping one named
owner per hot file and no concurrent harness edits. Existing pending harness
calibration/lifecycle work in the playback follow-up ledger must be identified
before overlapping implementation; no threshold widening is in scope.

## Acceptance and measurement

- Coverage map traces every retained requirement to executable evidence or an
  explicit manual/unsupported/blocked gap, without inventing coverage.
- Full gate cannot succeed on command failure, timeout, missing cells/artifacts,
  changed candidate or incomplete platform execution. Distinguish test failure
  from infrastructure failure; retain unfinished cases as not-run/blocked.
- Evidence reuse verifies exact tested source and configuration/environment;
  playback-affecting edits invalidate previous full-gate evidence.
- Independent reviewers can challenge missing coverage without rerunning the
  same complete gate merely to possess a second copy of its output.
- Compare retained scenario/cell counts, required invocations/interventions,
  log versus summary volume, elapsed time and reproducibility. Record observed
  duplicate launches separately from hypothetical savings. Do not claim token,
  quota or monetary savings without measurement.
- Record before/after commands and remaining platform/manual limitations.
- Complete diff review, required validation and progress evidence precede
  completion. Keep this plan active if required acceptance remains blocked.
