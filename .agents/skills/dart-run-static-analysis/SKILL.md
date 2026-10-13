---
name: dart-run-static-analysis
description: Run the Dart/Flutter analyzer and apply automated fixes in Navis (very_good_analysis, fatal infos, dart fix, format). Use after editing Dart code, when fixing lint or analyzer findings, or before handoff — any mention of analyze errors, lint warnings, or "make the analyzer happy".
---

# Static Analysis in Navis

## Repo configuration

`analysis_options.yaml` includes `package:very_good_analysis` — a strict,
opinionated ruleset. Two deviations matter:

- Infractions are fatal: run `flutter analyze --no-fatal-infos` (the repo
  command). Info-level findings block handoff just like errors.
- A short explicit list of rules is disabled at the bottom of
  `analysis_options.yaml` (e.g. `public_member_api_docs`,
  `cascade_invocations`). Do not re-enable them casually and do not disable
  additional rules to make a finding disappear — an intentional, scoped
  `// ignore: <code>` with a stated reason is the escape hatch of last resort.
  Blanket `// ignore_for_file: type=lint` is off-limits.

## Workflow

1. Run the analyzer on the affected scope:

   ```bash
   flutter analyze --no-fatal-infos
   ```

2. Fix reported findings in source. Treat warnings as real signals: a
   suppressed warning is a weakened test by repo policy
   (`docs/development/agentic-engineering.md` — never bypass checks to get green).
3. Findings inside generated `*.g.dart` / `*.freezed.dart` / Drift output are
   fixed by regenerating, never by hand-editing or ignoring: run `make gen`
   after Freezed, JSON, or Drift changes and commit the generated source.
4. Apply mechanical fixes only after reviewing them:

   ```bash
   dart fix --dry-run           # preview proposed mechanical fixes
   dart fix --apply             # apply after review
   dart format --set-exit-if-changed .
   flutter analyze --no-fatal-infos
   ```

5. Re-run the focused tests you touched before declaring the fix done.

## Before handoff

Implementation work requires `./tool/check.sh`, which runs formatting,
generation, analysis, migration and reliability tests, then the full suite.
Analysis alone is not the gate.

## Suppression syntax (rare, scoped)

```dart
// One line:
final x = legacy(); // ignore: deprecated_member_use
// Whole file (only for vendored or generated-adjacent code):
// ignore_for_file: invalid_annotation_target
```

Note that `invalid_annotation_target: ignore` is already configured globally
in `analysis_options.yaml` for freezed/json models — no per-file ignore needed.
