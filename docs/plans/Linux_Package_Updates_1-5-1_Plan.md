# Linux Package In-App Updates (1.5.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Navis installed from the `.deb` or `.rpm` updates itself in-app through the system package manager behind a polkit (`pkexec`) prompt; any other `/opt/navis` install (AUR, unknown) is told to use its package manager.

**Architecture:** Install-mode detection asks which package manager owns `/opt/navis/navis`. Package modes skip the directory-write check (the privileged installer does the writing, as with the Windows installer). Apply runs one `pkexec /bin/sh -c <script>` whose script lives in `update_scripts.dart`: it copies the verified artifact into a root-owned temp dir, re-checks its SHA-256 there, then installs with `apt-get` or `dnf`. Cancelling the prompt returns the dialog to its confirm step silently.

**Tech Stack:** Flutter/Dart desktop, `dart:io` `Process`, polkit `pkexec`, apt/dpkg, dnf/rpm, existing R2 signed-manifest updater.

**Spec:** this file (owner decision 2026-10-20: option 1 for 1.5.1; repositories for 1.6 in `Linux_Package_Repositories_1-6_Plan.md`).

**Branch / worktree:** `fix/linux-package-updates` from `release/1.5`, worktree `../Navis-pkg-updates`. PR targets `release/1.5`, merged forward to `dev` via a temp branch.

## Background (why it is broken today)

- `detectInstallMode()` (`lib/src/features/settings/data/update_install_mode.dart:43-49`) returns `linuxDeb` for anything under `/opt/navis`, including RPM and AUR installs.
- `UpdateDialog._startDownload` (`update_dialog.dart:107-111`) calls `canApplyUpdate`, which requires `/opt/navis` to be writable. It is root-owned 0755, so every package install lands on `noWriteAccess` ("Please download manually"). `_applyLinuxDeb` (`update_service.dart:324`) is unreachable.
- `linuxRpm-x86_64` is already published by `tool/r2_publish.sh:192` but never selected by the app.
- **Consequence for rollout:** 1.5.0 package users still get the manual screen for 1.5.1 (their old code decides). The new path first applies on the 1.5.1 → 1.5.2 update. The release notes must say so.

## Find and reuse first (existing infrastructure)

- Updater scripts: `lib/src/features/settings/data/update_scripts.dart` (+ `update_scripts_test.dart`): put the root install script here.
- Download, private 0700 temp dir, size + SHA-256 verify: `UpdateService.downloadArtifact` / `verifyArtifact` (`update_service.dart:52`, `:143`). Do not add a second verifier; the root script re-checks the hash it is handed.
- Asset selection: `UpdateRepository._updateFromEnvelope` (`update_repository.dart:271-283`), injectable `linuxDebArch` (`:66`), mirror it for RPM.
- Dialog phases and copy: `_DownloadPhase` (`update_dialog.dart:33-41`), `updateNoWriteAccess`, `updateApplyFailed` in `lib/l10n/app_en.arb` (the only ARB file).
- Runtime harness: diagnostics endpoints `POST /v1/diagnostics/update/check` and `.../download` with `{"apply":true}` (`sync_diagnostics_server.dart:3461-3508`); `tool/r2_update_diagnostics.sh` (portable flow, per-run patch versions); `tool/r2_publish.sh publish --channel=staging`.
- Package build and container checks: `tool/linux/build_in_container.sh`, `package_bundle.sh`, `verify_packages.sh`.

## Global Constraints

- Never weaken the signed-manifest + SHA-256 chain. The root step installs only a root-owned copy whose SHA-256 equals `UpdateInfo`'s expected hash.
- Paths and hashes reach the root script only as positional arguments, never interpolated into the script text.
- The elevation command is fixed to `pkexec` in shipped builds. A test-only override is allowed only via a compile-time define that `tool/release.sh` never sets (`NAVIS_TEST_UPDATE_ELEVATOR`, see Task 3).
- Silent self-healing policy: a cancelled prompt is not an error; no notice. Show UI only when the user must act.
- No new dependencies. `./tool/check.sh` green. Docs updated in the same PR.
- RPM support targets the dnf family (Fedora/RHEL). The spec's `Requires:` names do not resolve on openSUSE, so zypper is out of scope.

## Review Focus

1. **Prompt cancelled or no polkit agent** (pkexec exit 126 / 127, e.g. SSH or minimal WM): the dialog must return to confirm (126) or show the package-manager screen (127). It must never show "update failed" or exit the app. Tests in Task 3 and Task 4.
2. **apt lock held by unattended-upgrades:** the install waits up to 120 s (`-o DPkg::Lock::Timeout=120`), then reports the apply error while the app keeps running. Script test in Task 2, runtime check R6.
3. **Artifact swapped after verification** (same-user attacker): the root script's hash re-check on its own copy must refuse to install. Script test in Task 2, runtime check R5.
4. **Relaunch after the package replaced the running binary:** the new process starts from `/opt/navis/navis`, the old one exits, and nothing is left with a mixed version. Runtime checks R2 and R3.
5. **Arch/AUR or a hand-copied `/opt/navis`:** the user is never offered a `.deb` install. They see the package-manager message. Test in Task 1.

---

### Task 1: Detect the owning package manager

**Files:**
- Modify: `lib/src/features/settings/data/update_install_mode.dart`
- Test: `test/src/features/settings/data/update_install_mode_test.dart` (create)

**Interfaces:**
- Produces: enum values `linuxDeb`, `linuxRpm`, `linuxPackageManaged` (new: owned by something else or unknown) alongside the existing ones. `UpdateInstallMode detectInstallMode({ProcessRunSync? runSync})`, where `typedef ProcessRunSync = ProcessResult Function(String exe, List<String> args)` defaults to `Process.runSync`. `bool isLinuxSystemPackageMode(UpdateInstallMode m)` is true for the three package modes.

- [ ] **Step 1: Write failing tests** for `detectLinuxPackageMode(String exePath, ProcessRunSync run)` (a pure helper that `detectInstallMode` calls on Linux):
  - exe not under `/opt/navis` → `linuxPortable`, and `run` is never called.
  - `dpkg-query -S /opt/navis/navis` exits 0 → `linuxDeb`.
  - dpkg-query fails or is missing (throws `ProcessException`), and `rpm -qf /opt/navis/navis` exits 0 → `linuxRpm`.
  - both fail (the Arch case) → `linuxPackageManaged`.
- [ ] **Step 2:** Run `flutter test test/src/features/settings/data/update_install_mode_test.dart`. Expected: FAIL (helper undefined).
- [ ] **Step 3: Implement.** Query the resolved `/opt/navis/navis`, not `Platform.resolvedExecutable` symlinks. Catch `ProcessException` as "not this manager". Cache the result in a top-level `late final` so the dialog and the repository don't fork processes twice.
- [ ] **Step 4:** Fix the two exhaustive switches in `update_service.dart` (`:236`, `:440`) so the code compiles. Real behaviour comes in Task 3. Run the test again. Expected: PASS.
- [ ] **Step 5:** Commit `feat(update): detect which package manager owns /opt/navis`.

### Task 2: Root install script

**Files:**
- Modify: `lib/src/features/settings/data/update_scripts.dart`
- Test: `test/src/features/settings/data/update_scripts_test.dart`

**Interfaces:**
- Produces: `const String linuxPackageInstallScript` (POSIX sh). Its positional args are `$1` = source artifact path, `$2` = expected lowercase SHA-256, `$3` = `deb|rpm`. Exit codes: 0 installed; 10 hash mismatch; 11 unsupported or missing installer; otherwise the installer's own code.

Behaviour, in order:
1. `set -eu`.
2. `d=$(mktemp -d /var/tmp/navis-update.XXXXXX)`, with an EXIT trap that removes it.
3. `cp -- "$1" "$d/pkg"`, then `chmod 0644`.
4. `sha256sum` check against `$2`, else exit 10.
5. For `deb`: `apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends "$d/pkg.deb"` (rename with the suffix apt needs). If `apt-get` is absent, exit 11.
6. For `rpm`: `dnf install -y "$d/pkg.rpm"`. If `dnf` is absent, exit 11.

- [ ] **Step 1: Write failing tests.** Run the script with `sh` against a fake installer: a `PATH` dir holding stub `apt-get`/`dnf` that record their args, and `TMPDIR`-independent paths.
  - A correct hash calls the stub once with a path inside a fresh directory (not `$1`). Exit 0, and the temp dir is gone afterwards.
  - A wrong hash → exit 10, and the stub is not called.
  - The file is modified after the caller hashed it → exit 10.
  - A missing installer → exit 11.
  - A path containing spaces and `$(…)` is passed through literally.

  Skip on non-Linux (`skip: !Platform.isLinux`). `/var/tmp` must be overridable for tests: use `${NAVIS_UPDATE_TMP:-/var/tmp}`, which is harmless because it is root-only at runtime.
- [ ] **Step 2:** Run `flutter test test/src/features/settings/data/update_scripts_test.dart`. Expected: the new tests FAIL.
- [ ] **Step 3: Implement** the constant.
- [ ] **Step 4:** The same command → PASS.
- [ ] **Step 5:** Commit `feat(update): root-side verify-and-install script for deb/rpm`.

### Task 3: Apply through pkexec, select the right asset

**Files:**
- Modify: `lib/src/features/settings/data/update_service.dart` (`canApplyUpdate` :207, `applyDesktopUpdate` :230, replace `_applyLinuxDeb` :324, `_resolveTargetDir` :440)
- Modify: `lib/src/features/settings/data/update_repository.dart:271-283`, `:350-361`
- Test: `update_service_test.dart`, `update_repository_test.dart`

**Interfaces:**
- Consumes: Task 1 modes and `isLinuxSystemPackageMode`; Task 2 `linuxPackageInstallScript`.
- Produces:
  - `UpdateService({…, ProcessRunner? processRunner})`, where `typedef ProcessRunner = Future<ProcessResult> Function(String exe, List<String> args)` defaults to `Process.run`.
  - `class UpdateCancelledException implements Exception`, thrown when the user dismisses the polkit prompt (exit 126).
  - `class UpdateElevationUnavailableException implements Exception`, thrown when pkexec is missing or there is no agent (exit 127, or `ProcessException`).
  - `applyDesktopUpdate(String path, UpdateInstallMode mode, {String? expectedSha256})`: callers pass `UpdateInfo.sha256` (`String?`, `update_info.dart:46`). For a package mode, a null or empty value throws `UpdateIntegrityException` before pkexec runs, and gets a test.
  - Asset keys: `linuxRpm-${rpmArch}`, where `rpmArch` maps `uname -m` raw (`x86_64`, `aarch64`) and is injectable as `linuxRpmArch`.

- [ ] **Step 1: Write failing tests.**
  - `canApplyUpdate(linuxDeb)` and `canApplyUpdate(linuxRpm)` are true when `pkexec` resolves on `PATH`, and false when it does not. `canApplyUpdate(linuxPackageManaged)` is always false.
  - Apply for `linuxDeb` calls the runner with `('pkexec', ['/bin/sh', '-c', linuxPackageInstallScript, 'navis-update', path, sha, 'deb'])`. For `linuxRpm`, the last argument is `rpm`.
  - Runner exit 126 → `UpdateCancelledException`. Exit 127 → `UpdateElevationUnavailableException`. Exit 10 → `UpdateIntegrityException`. Any other non-zero code → `ProcessException` (the existing apply-error path).
  - Exit 0 → the relaunch hook is called. Make relaunch-and-exit injectable (`void Function()? relaunchAndExit`) so the test does not call `exit(0)`.
  - Repository: manifest with `linuxRpm-x86_64` + mode `linuxRpm` + arch `x86_64` → that asset. Arch `aarch64` with no such key → `missing_asset`, with no fallback to the deb.
  - Repository: `linuxPackageManaged` still produces an offer, using the `linuxPortable` key so the notes and version show. Download is never attempted for it (Task 4).
- [ ] **Step 2:** Run both test files. Expected: FAIL.
- [ ] **Step 3: Implement.**
  - Elevator: `const String.fromEnvironment('NAVIS_TEST_UPDATE_ELEVATOR', defaultValue: 'pkexec')`. Add a check in `tool/release.sh` (or the existing artifact scan) that fails if that define is set for a release build.
  - Relaunch: keep the existing detached `Process.start(Platform.resolvedExecutable)` + `exit(0)`. The repo has no single-instance guard (verified 2026-10-20).
- [ ] **Step 4:** Run both test files → PASS.
- [ ] **Step 5:** Commit `feat(update): install deb/rpm updates through pkexec`.

### Task 4: Dialog states and copy

**Files:**
- Modify: `lib/src/features/settings/presentation/update_dialog.dart` (`_startDownload` :100-111, apply catch :367-376)
- Modify: `lib/l10n/app_en.arb` (+ regenerate l10n)
- Test: `test/src/features/settings/presentation/update_dialog_test.dart`

**Interfaces:**
- Consumes: Task 3 exceptions and `canApplyUpdate`.
- Produces: new `_DownloadPhase.packageManager` and the ARB key `updateUsePackageManager`, with the text: "Navis was installed by your system's package manager. Update it from there, for example with your software updater or AUR helper."

- [ ] **Step 1: Write failing widget tests.**
  - Mode `linuxPackageManaged` → the package-manager text, plus Dismiss and Download manually. No download is started.
  - Mode `linuxDeb` with a service whose apply throws `UpdateCancelledException` → back to the `confirm` phase, with no error text.
  - `UpdateElevationUnavailableException` → the `packageManager` phase.
  - Mode `linuxDeb`, apply succeeds (fake) → `applying` shows, and no `noWriteAccess`.
- [ ] **Step 2:** Run `flutter test test/src/features/settings/presentation/update_dialog_test.dart` → FAIL.
- [ ] **Step 3: Implement.** Route `linuxPackageManaged` (or `!canApplyUpdate` for a package mode) to `packageManager` instead of `noWriteAccess`. In the `linuxDeb` case, change the "Applying" copy only if it promises a restart that may not happen; otherwise leave it.
- [ ] **Step 4:** Tests PASS. Then run `./tool/check.sh` (alone; host memory limits).
- [ ] **Step 5:** Commit `feat(update): package-manager dialog states`.

### Task 5: Docs, verify script, diagnostics recipe

**Files:**
- Modify: `docs/architecture.md:3674-3680, 3736, 3760`, `docs/release/release-linux.md:105-117`, `docs/release/release-r2.md:59-62` (`linuxRpm-x86_64` is now an app key), `CHANGELOG`/1.5.1 notes (the "takes effect from the next update after 1.5.1" sentence).
- Create: `tool/linux/package_update_diagnostics.sh`. This is the runtime harness for R1–R9 below, built on `r2_update_diagnostics.sh` (copy its handshake and publish helpers by sourcing, not duplicating, where they are functions).
- Modify: `tool/linux/verify_packages.sh`: replace the "manual update fallback" assertion with root-run ownership checks (`dpkg-query -S /opt/navis/navis` on Debian-family images, `rpm -qf /opt/navis/navis` on Fedora).

- [x] Task 5 implementation: docs/changelog, ownership verification and the
  source-sharing package diagnostics harness. Profile-mode/version forwarding
  is included because release-mode builds reject the diagnostics API.
- Static/focused validation only in this handoff; R1–R9 remain required before
  PR acceptance. No builds, publishes, SSH, containers or app launches were run.
- Commit subject: `docs: document and prepare Linux package update checks`.

### Task 6: Reuse the verified download after Cancel

- Remember the last verified digest/path for this app session; re-check size and SHA-256 before reuse after Cancel or reopening the dialog, with completed progress and no network usage.
- Re-download missing or tampered files; remove a superseded desktop work directory (only the file on Android). Keep the existing startup cleanup and root-side hash check.
- Cover reuse/request counts, case-insensitive digests, progress/network accounting, tampering, deletion and a changed digest in `update_service_test.dart`; retain private-directory checks.

---

## Runtime test plan (must pass before the PR is ready)

Unit and widget tests prove the wiring; they cannot prove polkit, apt, dnf or relaunch. The 1.5.1 batch rule applies: no "fixed" claim without these runs.

**Build under test.** Build the `.deb` and `.rpm` with `tool/linux/build_in_container.sh` from the branch, with these defines:
- `--dart-define=NAVIS_UPDATE_CHANNEL=staging`
- the diagnostics defines that `r2_update_diagnostics.sh` uses

Use version `1.4.<N>` (a per-run patch number, following the edge-cache rule in memory). Publish `1.4.<N+1>` (and `<N+2>` for the corrupt case) to the **staging** channel with `tool/r2_publish.sh publish --channel=staging`. Delete the staging objects afterwards.

| # | Where | Scenario | Pass criteria |
|---|-------|----------|---------------|
| R1 | Debian-family host 192.168.1.156 (Ubuntu 24.04, real GNOME/KDE session) | Install `1.4.N` .deb via `apt install ./…deb`. App launched in the user's graphical session. Check + download + apply via the diagnostics API. **Owner types the password at the real polkit prompt once.** | Prompt appears with the user's agent. `dpkg-query -W navis` = `1.4.N+1`. New pid, old pid gone. `/opt/navis` files are the new build. App window back. |
| R2 | same host | The same flow automated, with a temporary polkit rule letting `khalifa` run `org.freedesktop.policykit.exec` without auth. The owner installs the rule with sudo and it is removed after. Repeat 3×. | 3/3 as in R1, with no leftover `/var/tmp/navis-update.*`. |
| R3 | same host | Cancel the polkit prompt (owner clicks Cancel once). | Dialog back to confirm, no error, app still running, package version unchanged. |
| R4 | same host, over SSH without a session agent (no `DISPLAY` agent) | Apply. | pkexec 127 → package-manager screen. App still running. |
| R5 | same host | Corrupt `1.4.N+2` asset on staging (never-requested filename). Separately, the harness swaps the downloaded file between verify and apply (diagnostics hook or a manual `cp` with the app paused at confirm). | `integrity_mismatch` before any prompt. Swap → script exit 10 → integrity error UI. Nothing installed. |
| R6 | same host | Hold the dpkg lock (`sudo flock /var/lib/dpkg/lock-frontend sleep 150`) during apply. | Waits up to 120 s, then the apply-error UI. The app keeps running and the package stays consistent (`dpkg --audit` clean). |
| R7 | Fedora (see "Fedora" below) | Install `1.4.N` .rpm, check + download + apply. | `rpm -q navis` = `1.4.N+1`, relaunched, `dnf` accepted the unsigned local rpm with no prompt. |
| R8 | container `archlinux` or a hand-copied `/opt/navis` | Mode detection. | `linuxPackageManaged`, package-manager screen, no download. |
| R9 | `verify_packages.sh` images (ubuntu:22.04, debian:12, fedora:latest) | Run `dpkg-query -S` / `rpm -qf` detection and the root script with the real installer as root (no polkit). | Detection is right in every image. Script installs `N+1` over `N`. |

**Fedora.** No Fedora machine is available. The preferred option is R9 in containers plus R7 in a short-lived Fedora Workstation VM under libvirt on this host. The VM runs alone (heavy job), with 4 GB RAM. The alternative is R7 in a Fedora container with Xvfb and `NAVIS_TEST_UPDATE_ELEVATOR` set to a single executable wrapper script on PATH containing `exec sudo -n "$@"`. That proves dnf and relaunch but not polkit.

**Host notes (192.168.1.156).** The host is Ubuntu 24.04.5 x86_64, has an active graphical session for `khalifa`, and has pkexec, apt, docker and podman. `sudo` needs a password. The disk is 95 % full (24 GB free), so keep builds on this machine and copy only the packages. Afterwards, uninstall the test `navis` package if the host did not have one before. Record the pre-existing state first.

## Execution

- Tasks 1–4: backend implementation by Codex (`gpt-6.1-sol`, high), one hand-off in this worktree, test-first. Task 4 widget tests can be built by Sonnet if Codex is out.
- First review: GLM-5.3. Second opinion: Codex (small review), because the change touches privileged execution.
- Runtime plan R1–R9: one delegate run per host (Debian host via SSH; containers and the VM here, one heavy job at a time). Owner present for R1 and R3.
- Ledger: a new issue in the 1.5.1 milestone linked from #86, updated at each state change.
