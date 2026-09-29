---
name: dart-use-path-package
description: Safe cross-platform file-path handling with package:path in Navis (Windows backslash safety, joining, splitting, extensions, POSIX/URL conversion). Use when writing or reviewing code that joins, splits, compares, or transforms file or directory paths — downloads, artwork/cover cache, export paths, tool/ scripts — or replacing raw string path operations like '$dir/$file', .split('/'), .endsWith('.ext').
---

# Safe Path Manipulation in Navis

Navis ships on Windows, so backslash-naive string paths are real bugs here, not
theoretical ones. Path-heavy areas: the downloads feature (custom download
folders are user-owned — see `docs/architecture.md`), cover-art caching,
Drift database file locations via `path_provider`, and `tool/` scripts.

`package:path` is currently a **transitive** dependency. If `lib/` code imports
it directly, add `path` to `dependencies` in `pubspec.yaml` (importing a
transitive dep directly is fragile even though `depend_on_referenced_packages`
is disabled in this repo).

## Idioms vs anti-patterns

| Prefer | Avoid | Why |
|---|---|---|
| `p.join(dir, file)` | `'$dir/$file'` | Interpolation injects `/` on Windows and doubles separators |
| `p.split(path).contains('foo')` or `p.isWithin(a, b)` | `path.contains('foo/')` | Backslash paths silently fail; substring false positives |
| `p.extension(path) == '.flac'` | `path.endsWith('.flac')` | Suffix matching hits directories and partial names |
| `p.withoutExtension(path)`, `p.extension(path, 2)` | `lastIndexOf('.')` + slicing | Manual arithmetic breaks on dotfiles and `.tar.gz`-style compounds |
| `p.posix.joinAll(p.split(path))` | `path.replaceAll(r'\', '/')` | Ad-hoc replacement breaks root drives; POSIX context is explicit |
| `p.toUri(path)` / `p.fromUri(uri)` | `Uri.parse(path)` | Drive letters read as schemes; percent-encoding leaks |

Import as `import 'package:path/path.dart' as p;`.

## Rules that matter most here

- **Subpath boundaries:** pass each dynamic boundary as its own `p.join`
  argument (`p.join(downloadDir, 'Album', file)`), but keep static subpaths in
  one readable segment (`p.join(cacheRoot, 'covers/120', id)` is acceptable for
  greppability when the target is POSIX-only — never when Windows is a target).
- **`p.normalize` vs `p.canonicalize`:** normalize is lexical; use
  `canonicalize` when deduplicating or comparing real file identity
  (case-insensitive filesystems, symlinks).
- **Location specifiers:** strip `path:line:col` suffixes before treating a
  string as a path — `Uri.parse` mistakes `C:` for a scheme on Windows.
- **Git-facing paths:** `.gitignore` entries, archive manifests, and symlink
  targets always use forward slashes via `p.posix.joinAll(p.split(...))`;
  backslashes are escape characters in git patterns.
- **`package:file` in tests and tools:** `file` is a dev dependency used with
  mock file systems. Inside code that receives a `FileSystem`, use its attached
  context (`dir.fileSystem.path.basename(...)`) instead of global `p.*`, which
  binds to the host OS and breaks `MemoryFileSystem` with a Windows style.

## Audit checklist for path-touching changes

- [ ] No string interpolation joining path segments.
- [ ] Segment/prefix checks use `p.split` / `p.isWithin`.
- [ ] Extension checks use `p.extension` (with level 2 only for known compound extensions).
- [ ] POSIX/URL conversions go through `p.posix` / `p.url`, not `replaceAll`.
- [ ] `package:file`-based code uses `fileSystem.path`, not global `p`.
- [ ] New direct imports declared in `pubspec.yaml`.

Run the touched tests (`flutter test test/src/features/downloads/...`) plus
`./tool/check.sh` before handoff per repo policy.
