# macOS/iOS coordinator hand-off, 2026-11-25b

Previous: [macOS_iOS_Handoff_2026-11-25.md](macOS_iOS_Handoff_2026-11-25.md) (its Lessons, and those of 2026-11-24c and
2026-11-24b, still apply). Tablet ledger and spec: [tablet-ux-plan.md](tablet-ux-plan.md).

**Why the rollover:** three item PRs merged this round (#818, #819, #820).

## State

- Merged to `release/1.5`, each with a fresh Sonnet review, findings fixed, a fresh re-check, and green CI:
  - #818 P3.1: secondary-click menus and hover Play follow the input policy on every non-phone size. Review fixes
    added Downloads, Radio and the Playlists tab, and hid "Open folder" in the iOS popup.
  - #819 P3.2: hardware keyboard shortcuts on non-phone sizes; Cmd on iPadOS.
  - #820 P3.3: Interface > "Sidebar on medium screens" (tablets only, default off), schema 117
    (`app_settings.tablet_medium_sidebar`). Also got a fresh Opus migration review (nothing blocking). Changelog
    lines for P3.1-P3.3 are in 1.5.2.
- The whole tablet plan (P0-P3) is merged. Remaining: the P3 runtime pass (ledger, after "Batched runtime pass").
- Owner answer (2026-11-25): keep the current App Store screenshot sets (ledger section 8, item 4).
- No worker threads, delegates or PR watches are live. No PR is linked to the coordinator thread.
- Forwarding to `dev`: #812-#820 are not on `dev` yet (last forward was #792). The Linux coordinator usually does it;
  check for an open `merge/*-dev` PR first. #820 bumps the schema to 117: check `dev` has not used 117 meanwhile.

## Next steps

1. P3 runtime pass, one batch (ledger lists the checks). Flash runs it from an Opus-written script, only when no
   builder or reviewer can be running flutter tests (8 GB Mac). The new setting is not on the diagnostics API.
2. macOS 1440x900 checks for Downloads, Playlists, lyrics and the queue from a dev build after the forwards.
3. Deferred, not planned: the Keyboard Shortcuts settings screen is desktop-only and keys its labels on macOS
   (`desktop_shortcuts_settings_screen.dart:98,180,297,306`); it would need `usesAppleShortcutKeys` if it ever shows
   on tablets. No test pins radio long-press vs secondary click.

## Lessons

- **zsh quirks in shell calls.** `git show $R:lib/...` applies zsh's `:l` modifier; write `"${R}:lib/..."`. An
  unquoted `$T` holding a file list is not word-split in zsh; use `xargs` or `${=T}`.
- **Two push URLs on `origin`.** A rebased branch's `--force-with-lease` reaches GitHub but is rejected by the
  git.porthorion.com mirror as stale. Push the mirror with an explicit lease:
  `git push --force-with-lease=<branch>:<old sha> https://git.porthorion.com/khalifa/Navis-dev <branch>`.
- **delegate_task worktrees start at the parent's commit** (`dev` in the main checkout). Briefs must say
  `git fetch origin && git checkout -b <branch> origin/release/1.5`. One child hit a `.git/config` lock doing so
  and repaired it.
- **Long focused runs exceed 600 s.** The Bash call moves them to the background; call `t3_background_wait` on the
  task id instead of starting a second copy.
- **Small review findings: fix them yourself** in the builder's finished worktree, run the focused tests under
  lockf, then a fresh Sonnet re-check of the findings and fix diff only.

## Worktrees

- Deleted: the P3.1/P3.2/P3.3 builder worktrees and branches, six reviewer worktrees, and the stray
  `Navis/Navis-p3.1` (removed at once).
- `Navis-handoff`: this docs PR; delete it and its branch after merge.
- Untouched, belonging to others: the older `.t3/worktrees` checkouts, `Navis-glow`, `Navis-mac152`.

## Simulators and other owner actions

Unchanged from [2026-11-25](macOS_iOS_Handoff_2026-11-25.md#simulators) and
[2026-11-24b](macOS_iOS_Handoff_2026-11-24b.md#owner-actions-unchanged): I41b PR #564, the demo account, the privacy
policy, ASC 1.5.2, the password rotation, the Keychain prompt report, and no tag or release without the owner.
