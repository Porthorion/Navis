# Sync admission audit — 2026-10-08

A5-fix compares `02a86d3e` with the gate introduced by `c88f648a` and the
restorations in this change. This is historical audit evidence; the current
contract remains [Sync Flow](../architecture.md#sync-flow).

## Coverage and interpretation

[The complete decision ledger](sync-admission-2026-10-08.csv) lists **all 286
original cases**, including unchanged cases, plus 19 queued-manual-discovery
cases. Each row includes every input axis, the six old guards, the c88 gate,
the final gate, and every differing boundary with its allow/deny direction.
There are **127 original combinations** where at least one old guard differs
from the c88 gate. Boundary counts overlap:

| Old boundary compared with c88 gate | Changed cases |
| --- | ---: |
| Planner admission | 32 |
| `_firstAllowedWork` selection | 55 |
| `_planFromWork` resume planning | 45 |
| `_workAllowed` admission | 65 |
| `canRequest` scope | 51 |
| `_ensureBackgroundWorkAllowed` network checkpoint | 64 |

The old predicates were transcribed from `git show 02a86d3e:<file>` for
`adaptive_library_sync_coordinator.dart`, `library_sync_planner.dart`, and
`library_sync_engine.dart`, then evaluated against the original policy matrix
(15 work tuples × 19 contexts, plus the background-sync-enabled cellular case).
`allow` describes admission of the candidate work, rather than freshness,
endpoint budgets, lease availability, or which kind the planner chooses.
The planner comparison follows the admission checks inside the branch for the
candidate (not whether earlier branches select a different plan): `_broadPlan`,
manual discovery, exact/auxiliary target, or pending catalog hydration.
Queued non-repair-intent repairs have no corresponding fresh planner branch
and are `n/a`. Probes and exact/auxiliary targets do not reach the engine's
background-work checkpoint and are also `n/a` there. Selection assumes the
candidate reaches the loop (catalog-only filtering is orthogonal).

These are **boundary-predicate differences, not 127 changed user behaviors**.
For example, the old pending-hydration planner branch had no offline
admission check, but earlier plan selection and the admission/scope still
prevented offline requests. The engine formerly checked network permission
only; comparing it with a gate that also checks visibility/playback exposes
redundant restrictions, not evidence that the engine used to bypass its scope.
The final engine again checks network permission and calls the current scope's
`check()` for the shared live admission; it no longer reconstructs scheduler
state from song identity. The ledger's `final_gate` is the shared gate result,
not a claim that every isolated engine network predicate equals that result.

For the 19 extra queued rows, the caller is automatic and the checkpoint has
manual intent. Old selection/admission use the caller; old resume/scope use
restored manual intent. The old reconstruction supplied a default bounded
metered grant. C88 selection still used the automatic caller. Final selection
uses restored intent **and the current caller's grant**. No stored grant is
restored. The original regression test block matches `02a86d3e` exactly.

## Every original combination changed at c88

The names below are the exact matrix tuple names. For every listed combination,
the CSV gives all differing guards and directions; no other original
combination changed any compared predicate.

| Context | Work tuples with at least one changed decision |
| --- | --- |
| idle | `dormantAutomaticRepair`, `dormantManualRepair` |
| playing | `automaticDelta`, `snapshot`, `audit`, `dormantAutomaticRepair`, `dormantManualRepair`, `auxiliary`, `backlog`, `artist`, `album`, `playlist` |
| hidden | `automaticDelta`, `manualDelta`, `snapshot`, `audit`, `repair`, `dormantAutomaticRepair`, `dormantManualRepair`, `auxiliary`, `explicitAuxiliary`, `backlog`, `artist`, `album`, `playlist` |
| hidden while playing | `automaticDelta`, `manualDelta`, `snapshot`, `audit`, `repair`, `dormantAutomaticRepair`, `dormantManualRepair`, `auxiliary`, `explicitAuxiliary`, `backlog`, `artist`, `album`, `playlist` |
| worker | `dormantAutomaticRepair`, `dormantManualRepair` |
| playing worker | `automaticDelta`, `snapshot`, `audit`, `dormantAutomaticRepair`, `dormantManualRepair`, `auxiliary`, `backlog`, `artist`, `album`, `playlist` |
| metered | `backlog` |
| bounded metered | `automaticDelta`, `manualDelta`, `backlog` |
| bounded metered playing | `automaticDelta`, `manualDelta`, `backlog`, `artist`, `album`, `playlist` |
| bounded metered hidden | `automaticDelta`, `manualDelta`, `backlog`, `artist`, `album`, `playlist` |
| broad metered | `automaticDelta`, `manualDelta`, `snapshot`, `audit`, `repair`, `dormantAutomaticRepair`, `dormantManualRepair`, `auxiliary`, `explicitAuxiliary`, `backlog` |
| broad metered playing | `automaticDelta`, `manualDelta`, `snapshot`, `audit`, `repair`, `dormantAutomaticRepair`, `dormantManualRepair`, `auxiliary`, `explicitAuxiliary`, `backlog`, `artist`, `album`, `playlist` |
| broad metered hidden | `automaticDelta`, `manualDelta`, `snapshot`, `audit`, `repair`, `dormantAutomaticRepair`, `dormantManualRepair`, `auxiliary`, `explicitAuxiliary`, `backlog`, `artist`, `album`, `playlist` |
| metered worker | `backlog` |
| bounded metered worker | `automaticDelta`, `manualDelta`, `backlog` |
| broad metered worker | `automaticDelta`, `manualDelta`, `snapshot`, `audit`, `repair`, `dormantAutomaticRepair`, `dormantManualRepair`, `auxiliary`, `explicitAuxiliary`, `backlog` |
| offline none | `backlog` |
| offline boundedMeteredDiscovery | `backlog` |
| offline broadMeteredOnce | `automaticDelta`, `manualDelta`, `snapshot`, `audit`, `repair`, `dormantAutomaticRepair`, `dormantManualRepair`, `backlog` |
| metered background enabled | `automaticDelta` |

## Disposition of all differences

The following rules apply to every changed boundary in the ledger. Changes to
an earlier guard that leave the old execution outcome intact are identified
separately from product changes.

| Difference | Disposition and evidence |
| --- | --- |
| Queued manual delta, automatic foreground pass during playback | **Restore.** `7d2bb0ce` introduced offline manual discovery; `02a86d3e`'s pre-existing coordinator test requires playback resume. Sync Flow: “If that explicit request is made offline, its durable work remains delta reconciliation and resumes when an eligible connection returns”. Decode persisted intent before selection; retain current ephemeral grants. |
| Exact entity interaction, hidden foreground execution | **Restore old scope denial by default.** The old scope required visibility for automatic non-probe work. There is no documented exception authorizing a hidden interaction. This covers artist/album/playlist in `hidden`, `hidden while playing`, `bounded metered hidden`, and `broad metered hidden`. |
| Hidden worker during playback | **Preserve old automatic scope denial; keep the constrained worker idle.** This also denies explicit broad work in `playing worker`, which the old isolated explicit scope could admit. The run brief and current gate contract constrain hidden workers to idle; the actual headless playback observation has the limitation noted below. The run brief requires background/worker limits; Sync Flow: “The constrained Android background executor may run while hidden when playback is idle”. This covers every non-probe tuple in `playing worker`; entity scope denial is restored, and explicit manual delta/repair/auxiliary admission is constrained. |
| Foreground entity interaction during playback | **Keep new allowance; old blanket automatic scope denial was a bug.** Sync Flow describes interactive priority and says “active playback caps it at two”. A zero-request playback veto contradicts that bounded interactive execution. Applies to artist/album/playlist in `playing`, `bounded metered playing`, and `broad metered playing`. |
| Queued full repair under automatic or Check for updates intent | **Keep denial; old manual selection was a bug.** Sync Flow: “it remains resumable but dormant until an explicit Repair Library action”. The old automatic selector already enforced this; manual Check for updates could select the repair. Keep the repair-only changelog fix. All `dormantAutomaticRepair`/`dormantManualRepair` differences fall here. |
| Explicit broad or auxiliary work while hidden, even with grants | **Keep denial; old visibility bypass was a bug.** Sync Flow permits an explicit refresh to “resume queued broad work in the foreground, including during playback”. A mobile-data grant supplies network permission, not foreground permission. All hidden explicit manual delta/repair/auxiliary differences fall here. |
| Automatic broad work during playback or hidden execution | **Keep denial.** Sync Flow: “Automatic broad work defers while Navis is backgrounded or playing”. Old planning/resume/scope already denied it; most admission/engine differences merely move the same restriction earlier. Automatic auxiliary refresh also has its documented “separate playback, foreground, offline, metered-network, retry, and backoff policy”. |
| Automatic delta with only a bounded metered grant, or background sync enabled on cellular | **Keep denial; broad metered automation was a bug.** Sync Flow: “Metered automation is a true hard probe: one conditional getIndexes request with retries disabled”. Bounded permission is for explicit discovery. With background sync enabled, the old planner chose broad delta; the current planner chooses the hard probe. |
| Manual discovery with fresh bounded permission; broad work with fresh broad permission on metered network | **Keep granted admission where visibility/playback/repair intent permit it.** Sync Flow allows ordinary manual discovery to inspect “one bounded 50-album newest page” and defers broader work “unless the user grants an ephemeral one-time mobile-data override”. The old selector and resume planner ignored grants even when old admission allowed them. They should not veto the current grant. This covers metered grant-driven deny→allow selection/resume decisions. |
| Offline work, including grant-bearing engine checkpoints and ungated planner backlog | **Keep denial.** Sync Flow says policy gates remain deferred and enumerates the auxiliary “offline” policy. The old engine's broad grant could bypass an offline network guard in isolation; the old scope still denied it. Ungated backlog planning likewise never supplied offline request permission. The final engine explicitly checks offline before grants. |
| Remaining planner/admission/resume/engine differences where old scope already denied | **Keep the same final denial at every boundary.** These are earlier enforcement of the preceding offline, metered, visibility, playback, or repair rules, not removed user behavior. The CSV retains each individual discrepancy rather than concealing it behind the final result. |

The audit additionally found a defect **outside the matrix's playback boolean**:
c88's engine inferred active playback from `readActiveSongId != null`. Production
supplies `snapshot.currentSongId`, which also exists while paused, whereas the
coordinator reads `snapshot.hasActivePlayback`. Restore the old ability to run
an admitted automatic pass with a paused current song. Engine checkpoints now
ask the existing request scope and separately preserve live network safety;
no extra callback or state mirror is added. An integrated coordinator/engine
regression covers paused automatic, playing automatic, and playing manual runs.

## Limits

No app, emulator, build, or `tool/check.sh` was run, as required by the run brief.
The headless Android entrypoint supplies `readHasActivePlayback: () => false`
(both at `02a86d3e` and now). Thus the idle-worker rule is enforceable by the gate
when its input reports playback, but the real headless entrypoint does not
observe playback. This pre-existing observability gap contradicts any claim
that this audit proves worker deferral during actual audio playback. No
platform bootstrap change was made in this admission-gate task.

The matrix is finite: it does not exhaust all combinations of target kinds,
triggers, custom network-policy booleans, freshness, due state, or grant values.
The historical guard comparison is a source audit, not execution of the old
Flutter checkout. Current behavior is validated by the policy matrix and the
coordinator/engine regression suites.
