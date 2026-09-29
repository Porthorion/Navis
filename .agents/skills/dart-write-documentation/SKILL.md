---
name: dart-write-documentation
description: Write Effective Dart doc comments (`///`) for Navis code — tone, openers, linking, banned Javadoc tags. Use when documenting classes, methods, providers, DAOs, or public API clients, when asked for docs/docstrings/comments on Dart declarations, or when review flags doc-comment style.
---

# Writing Dart Doc Comments in Navis

Follow Effective Dart: Documentation. Comments exist to explain constraints
and *why* — repo policy (`docs/agentic-engineering.md`) bans narration of
obvious control flow and AI-noise commentary; these rules complement that.

## Scope

- Target public declarations (no leading underscore). `public_member_api_docs`
  is disabled in `analysis_options.yaml`, so docs are not lint-enforced here —
  write them anyway for public API surfaces: Subsonic/Last.fm/LRCLIB clients,
  DAOs, providers, shared widgets, feature interfaces.
- Never hand-write docs into generated `*.g.dart` / `*.freezed.dart` / Drift
  output; document the source that generates them.
- Private members: only when a non-obvious constraint needs recording.

## Format rules

- Always `///`, never `/** */`. Proper sentences: capitalized, end with a
  period.
- **First paragraph = one concise summary sentence**, then a blank `///` line,
  then detail. Never emit a bare newline without `///` inside the block.
- Openers: methods get third-person verbs (`/// Initializes the database.`);
  properties/getters get noun phrases (`/// The active server credentials.`);
  booleans start with `Whether` (`/// Whether playback is buffered.`).
- Do not restate the signature ("This method...") or the name.

## Banned

- Javadoc tags: `@param`, `@return`, `@throws`, `@see`, `@type`. Weave them
  into prose: "Throws a [SubsonicException] when the server rejects the
  request."
- Doc comment **after** annotations — it goes before `@override` /
  `@riverpod` / `@DriftAccessor`.
- Duplicate docs on an `@override` that behaves identically to the superclass;
  inherit instead.
- Documenting both getter and setter of a pair — document the getter only.

## Linking and markdown

- Link in-scope symbols with square brackets, no parentheses:
  `[NavisDatabase]`, `[SubsonicClient.fetch]` — not backticks, not `fetch()`.
- Backticks for keywords, literals, and expressions: `` `null` ``, `` `true` ``.
- Default constructor links use `.new`: `[NavisDatabase.new]`.
- Label every code fence: ```` ```dart ```` or ```` ```sh ````.
- For an out-of-scope symbol, use `@docImport` on the library directive rather
  than adding a real import:

  ```dart
  /// @docImport 'package:drift/drift.dart';
  library;
  ```

## Verify

1. `flutter analyze --no-fatal-infos` — unresolvable bracket references and
   doc-comment lints surface here.
2. Docs-only changes need link/path/command validation only, not the full
   Flutter suite — state what was and wasn't run.
