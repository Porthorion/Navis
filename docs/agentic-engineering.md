# Agentic engineering guide

This is Navis's canonical, tool-neutral engineering policy for human and AI
contributors. `AGENTS.md` and tool-specific instruction files are concise entry
points to this guide; they must not become competing copies.

## Working model

AI-generated work is held to the same or higher standard as human work. It is
not an excuse for guessed APIs, placeholder code, skipped tests, excessive
commentary, duplicated logic, swallowed errors, unsafe typing, disabled
validation, temporary hacks, or speculative abstractions. Comments explain a
constraint or *why*, not obvious control flow.

Use source truth in this order when they differ: current implementation;
automated tests; configuration and schema; build/release tooling; safe runtime
observation; active documentation; then historical documentation. Preserve an
uncertainty instead of inventing a behavior, date, reason, or result.

## Required workflow

### 1. Understand before editing

Read the root instructions, any more-specific instructions, this guide, and
the relevant documents from [README.md](README.md). Then inspect the relevant
implementation, types/interfaces, tests, callers, configuration, and existing
patterns. Search first (`rg` is preferred) and expand context progressively;
do not make a substantial change from a filename or a single source file.

For a cross-cutting change, make a short plan in the task discussion before
editing. Do not create a planning artifact for a trivial edit.

### 2. Assess impact and design to existing patterns

Consider user behavior, APIs, data/migrations, configuration, authentication,
integrations, accessibility, platform behavior, performance, observability,
security, backward compatibility, documentation, and release effects. Reuse
existing feature, provider, repository, model, widget, and error patterns
before creating a new abstraction. Keep the smallest coherent scope; document
an unrelated finding rather than silently expanding the task.

### 3. Implement and document together

Documentation is part of the change, not a postscript. Update the owning active
document whenever a feature, behavior, API, schema, configuration, integration,
deployment path, dependency, platform capability, operational procedure, or
architecture changes. Update diagrams when their represented architecture
changes materially. If no documentation update is needed, be prepared to state
why.

For user-facing behavior, also update
`lib/src/features/changelog/changelog_data.dart`; the release-notes tool
reads it, so there is no second copy to keep in sync. For a material removed,
replaced, or
deprecated capability, add or update a record in
[history/removed-features.md](history/removed-features.md). Normal edits do
not require copying documents into an archive: Git supplies line history.

### 4. Validate proportionately

Start with the narrowest relevant test, then broaden based on impact. Use the
actual repository commands, not invented ones:

```bash
./tool/bootstrap.sh
make gen                         # Freezed, JSON, Drift changes
flutter test test/path/to/test.dart
flutter analyze --no-fatal-infos
./tool/dart_format.sh --check
./tool/check.sh
```

`./tool/check.sh` is required for implementation work unless an external
limitation prevents it; it includes code generation and the full test suite.
For a runtime-affecting change, static checks and widget tests are insufficient:
follow the isolated-profile, authenticated diagnostics-API, log, persistence,
and clean-restart loop in [development-workflow.md](development-workflow.md).
For visible Flutter changes, request and inspect the relevant app-owned PNG via
`POST /v1/presentation/screenshot`. Platform-neutral behavior requires Linux
runtime validation; platform-specific work needs Linux startup smoke plus the
affected platform's authoritative service/API when available.

Documentation-only changes normally need link/path/command validation rather
than the Flutter suite. State plainly what was not run and why; never describe
unexecuted validation as passing.

### 5. Review before handoff

Review the complete diff as another engineer would: scope, behavior, edge and
error cases, docs, comments, migration completeness, generated output,
formatting noise, credentials, compatibility, and accidental files. Do not
modify unrelated dirty work. Report actual validation and any uncertainty.

## Navis-specific guardrails

- Use Riverpod-provided infrastructure; never instantiate `NavisDatabase`
  outside provider DI or mutate provider state during widget build.
- Preserve playback resolution: permanent download → rolling cache → direct
  stream. Read the playback architecture before changing cache or audio code.
- `app_providers.dart` is intentionally the composition root and may import
  feature modules; avoid circular feature imports.
- Router construction must retain its narrow auth-based refresh behavior.
- Drift changes need a stepwise migration, generated output, and migration-test
  updates. Generated `*.g.dart` / `*.freezed.dart` files are tracked source
  when generation changes them; do not hand-edit them.
- Retired Listen Together/Voyage has compatibility fields only. Do not revive
  its session, transport, settings, queue sync, or UI without an explicit
  product decision and a recorded decision/history update.
- Genres are not a Navis concept (product decision 2026-09-30). Do not add a
  genre page, route, Library section, Home shelf, search filter, Android Auto
  node, sync/scan input, catalog-change signal, recommendation input or
  diagnostics field without an explicit product decision.
- Production code used only by tests must be deleted or marked
  `@visibleForTesting` as a deliberate test seam. The dead-code gate excludes
  annotated declarations and accepts other exceptions only with factual
  baseline reasons; release/dev tooling callers count as real use.
- Runtime control comes from the authenticated Navis diagnostics API. Do not
  use AT-SPI, OCR, xdotool, window scraping, or desktop accessibility traversal
  as a substitute; see `development-workflow.md` for the narrow exception.

## Safety and hygiene

Never commit secrets, print credential values, replace placeholders with real
credentials, discard unrelated work, blindly remove data or migrations, bypass
tests to make a gate green, weaken security/validation, or silently ship a
breaking API/schema/behavior change. Preserve license and copyright notices.
Use `tool/release.env` only as the ignored local secret source and
`tool/release.env.example` for non-secret examples. Treat custom download
folders as user-owned as documented in the architecture.

## Versioning

The app version is `version: <major>.<minor>.<patch>+<build>` in
`pubspec.yaml`. `tool/release.sh` derives the build number as
major × 10000 + minor × 100 + patch, so minor and patch stay below 100.

**Start the next version before new work.** When the version in
`pubspec.yaml` on `dev` has already been released (its `v<version>` tag
exists, and it is on `main`), the first change of new work starts the next
version:

1. Set `version:` in `pubspec.yaml` to the next version and build number.
2. Add its `ChangelogVersion` at the top of `changelogs` in
   `lib/src/features/changelog/changelog_data.dart`, with `released` left
   null.
3. Land that change on `dev` on its own (for example `chore: start 1.4.1`)
   before the work itself, so every later change, including work in other
   branches and sessions, adds its changelog entry under that version.

While that version is unreleased, later changes add to it; they do not bump
the version again.

**Choose the increment by the scope of the work:**

- **Patch, +0.0.1** (1.4.0 → 1.4.1): fixes, hotfixes and small improvements.
- **Minor, +0.1.0** (1.4.1 → 1.5.0): overhauls, reworks, restructuring or a
  substantial new capability. The changelog treats every `x.y.0` as a major
  release: give it 3–5 highlights and, optionally, a codename and cover.
- **Major, +1.0.0** (1.x → 2.0.0): reserved for a milestone, such as the app
  being complete and self-sufficient with only small patches expected after
  it. Never for ordinary feature work.

If the work grows while its version is unreleased, for example a patch
turns into a rework, raise the pending version (1.4.1 → 1.5.0) and move its
changelog entry instead of releasing a number that understates the change.

Versions up to 1.4.0 were numbered before this policy (1.0.0 came early, for
instance). They stay as released; this policy applies from 1.4.1 on.

Release the pending version with `./tool/release.sh v<version>`. The script
refuses only a version whose release tag already exists, so a version set
early on `dev` releases without extra flags (see [ci-cd.md](ci-cd.md)).

## Documentation lifecycle

Active documents describe supported current behavior. Plans, audits, and
progress records preserve intent and evidence but are not implementation
authority. Historical records preserve meaningful removal/replacement context:
name, previous purpose and behavior, date when known, reason when evidenced,
replacement/migration, architectural impact, and references. Use `YYYY-MM-DD`;
mark unknown details as unknown rather than guessing.

Create a lightweight decision record under `docs/decisions/` only for a new
decision with enduring, cross-cutting consequences. Do not reconstruct old
ADRs without reliable evidence. Use the template and status rules in
[decisions/README.md](decisions/README.md).

## Definition of done

- [ ] Relevant docs and applicable scoped instructions were read first.
- [ ] If the current version was already released, the next version was
  started first (see Versioning).
- [ ] Existing patterns, callers, configuration, and tests were inspected.
- [ ] The change is complete, focused, and handles relevant failure/edge cases.
- [ ] Relevant tests were added or updated and validation was run proportionately.
- [ ] Runtime loop, screenshot inspection, and clean restart were completed when required.
- [ ] Security and backward compatibility were considered where applicable.
- [ ] Active documentation and release notes were updated where applicable.
- [ ] Removed/deprecated behavior was historically recorded where applicable.
- [ ] Generated source was regenerated when required.
- [ ] The complete diff was reviewed; no unrelated changes or secrets remain.
- [ ] Final validation results, gaps, and uncertainties are reported accurately.

## Tool interoperability

Codex reads `AGENTS.md`; Cursor reads `.cursor/rules/navis-agents.mdc`; Claude
reads `CLAUDE.md`; Gemini reads `GEMINI.md`; GitHub Copilot reads
`.github/copilot-instructions.md`. Each is intentionally concise and points
here. On-demand project skills for recurring workflows live under
`.agents/skills/<name>/SKILL.md`; they complement this guide and must not
contradict or duplicate it. When changing policy, update this guide first,
then update only the entry-point wording necessary to keep it accurate. Add
a scoped instruction only where a directory has rules that are materially
different from the root.
