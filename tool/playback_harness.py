#!/usr/bin/env python3
"""Playback runtime harness: one command builds a base and the working tree, runs the same
fixture scenarios on both and prints PASS/FAIL per threshold.

  tool/playback_harness.py list
  tool/playback_harness.py map [<rev-range>]
  tool/playback_harness.py ab <scenario...|--map|--all> --platform linux|android [--base <ref>] [--real]

The engine is tool/live_seek_stress.py (fixture server, throttling proxy, drivers, oracles); this file only
holds the scenarios, the base-build cache, the A/B runner and the thresholds. Exit codes: 0 pass,
1 a threshold failed, 2 infrastructure error (build, emulator, downloads changed, missing base).
Usage and the runner brief: docs/development/development-workflow.md, "Playback runtime harness".
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import shlex
import signal
import socket
import statistics
import subprocess
import sys
import time
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path

from heavy_lock import heavy_lock

PROJECT = Path(__file__).resolve().parents[1]
CACHE = Path(os.environ.get('NAVIS_HARNESS_CACHE', Path.home() / '.cache' / 'navis-harness'))
DATA = CACHE / 'run'                      # the engine's data root, outside any worktree so cached bundles run anywhere
SUFFIX = '.harness'
DOWNLOADS = Path.home() / 'Downloads' / 'Navis_Downloads'
SOURCE_AVD = os.environ.get('NAVIS_HARNESS_AVD', 'Pixel_9_Pro_XL')
ANDROID_HOME = Path(os.environ.get('ANDROID_HOME', Path.home() / 'Android' / 'Sdk'))
GUEST_MIB = 3072
DEFAULT_BASE = 'github/release/1.5'
MEMORY_MAX = '8G'


class InfraError(RuntimeError):
    """Build, environment or safety failure: never reported as a threshold FAIL."""


# Scenarios -------------------------------------------------------------------------------------------------
# cases/reps are the --full set (calibration, release checks); quick/qreps (default 1) the default one. Both go to the
# engine matrix. areas are the code paths that make `map` pick the scenario; budget is the measured wall-clock minutes
# of one variant's runs, (quick, full) -- an A/B run takes twice that plus builds.
# memory-soak calibration (same-code A/A, 3 reps, 2026-10-25, Pss+SwapPss): post-GC total base 436.8/471.0/527.4, fix 544.2/580.8/595.7 MiB
# (medians 471.0 vs 580.8; worst pairing 158.9), so the total gets base + 192; slope medians 4.867 vs 1.864 pass max(base, 0) * 1.25 + 1.5.
# Checks: (metric, '<=', limit) absolute on the fix | (metric, 'base+', add) fix <= base + add |
# (metric, 'base*', factor, add) | (metric, 'base-positive*', factor, add) clamps the base at zero | (metric, 'nonew') fix has no violation kind the base lacks |
# (metric, 'stall') fix max <= 50 or not worse than base (Linux: >50 ms count <= base + 3) | (metric, 'true') | (metric, 'nonempty').

HANDLER = ['lib/src/features/player/data/navis_audio_handler*.dart', 'lib/src/features/player/data/playback_source_resolver.dart',
           'lib/src/features/cache/data/rolling_cache_sidecar_downloader.dart', 'third_party/just_audio*/**']
CROSSFADE = ['lib/src/features/player/data/*crossfade*.dart', 'lib/src/features/player/data/navis_playback_lanes.dart']
QUEUE = ['lib/src/features/player/data/*queue*.dart', 'lib/src/features/player/data/navis_shuffle_order.dart',
         'lib/src/features/player/data/*_persistence.dart']
SCENARIOS = {
    'seek': dict(
        cases='seek_early,seek_pastdl,seek_far,seek_mid,seek_back,seek_burst,seek_paused,offset_quick,offset_far,offset_back',
        quick='seek_far,seek_back,seek_burst,offset_quick,offset_far',
        qualities='opus128', throttle='wan6000', reps=3, budget=(2, 11), args=['--verify-offset'],
        areas=HANDLER + ['lib/src/features/player/data/seek_preview_request.dart'],
        checks=[('kinds', 'nonew'), ('violations', 'base+', 1), ('latencyMedianS', 'base+', 0.25)]),
    'stress-drag': dict(
        cases='stress_drag,stress_flick', quick='stress_drag,stress_flick', qreps=3,
        qualities='opus128', throttle='wan6000', reps=5, budget=(2, 4), args=[],
        areas=['lib/src/features/player/presentation/*seek_bar*.dart', 'lib/src/features/player/data/seek_preview_request.dart',
               'lib/src/utils/diagnostics_presentation_controller.dart', 'lib/src/common_widgets/desktop_playback_progress.dart'],
        checks=[('previewSocketMax', '<=', 1), ('closedBeforeSuccessor', 'true'), ('previewGETsMax', '<=', 20),
                ('drags', '>=', 1), ('flickCells', '>=', 1), ('flickGETs', '<=', 0), ('frameGapP95Ms', 'base+', 5), ('eventLoopP95Ms', 'base+', 5),
                ('frameGapStall', 'stall'), ('eventLoopStall', 'stall'), ('releaseMedianS', 'base+', 0.5)]),
    'memory-soak': dict(
        cases='mem_soak', quick='mem_soak', qualities='opus128', throttle='wan6000', reps=3, qreps=1, budget=(7, 37), args=[],
        vm=True, quick_env={'NAVIS_LIVE_SEEK_SOAK_DRAGS': '10', 'NAVIS_LIVE_SEEK_SOAK_IDLE_S': '60'},
        areas=['lib/src/features/player/presentation/*seek_bar*.dart', 'lib/src/utils/diagnostics_presentation_controller.dart',
               'lib/src/features/player/data/seek_preview_request.dart'] + HANDLER,
        checks=[('slopeMiBPerDrag', 'base-positive*', 1.25, 1.5), ('postGcPssSwapMiB', 'base+', 192), ('postGcHeapMiB', 'base+', 8)]),
    'repeat': dict(
        cases='offset_repeat_one,base_repeat_one,repeat_one_fill,chain_end,chain_end_all,repeat_switch_off,hold_off,hold_all,'
              'q7_append_200',
        quick='offset_repeat_one,repeat_one_fill,chain_end,q7_append_200',
        # 30x transcodes let current + next complete within chain_end's 25 s window.
        qualities='opus128', throttle='wan6000', reps=3, budget=(8, 60), args=['--transcode-speed', '30'],
        areas=HANDLER + CROSSFADE + QUEUE + ['lib/src/features/player/data/navis_playback_rules.dart',
                                             '**/ProgressiveRepeat.java', '**/AudioPlayer.java',
                                             'lib/src/features/cache/data/**'],
        checks=[('kinds', 'nonew'), ('violations', 'base+', 3), ('frozenMedianS', 'base+', 0.1),
                # Linux cold: 0.02 s / <=540672 B / 0; warm: 14.62 s / 3454317 B / 1.
                # Keep margin below the warm result and well above a handover GET.
                ('nextRequestLeadMinS', '>=', 6.0), ('nextBytesAtHandoverMin', '>=', 1048576),
                ('nextSeekLocalRate', '>=', 0.75)]),
    'crossfade': dict(
        cases='crossfade_end,skip_next,skip_prev', quick='crossfade_end,skip_next,skip_prev',
        qualities='opus128', throttle='none', reps=3, budget=(1, 3),
        args=['--crossfade-s', '4'],
        areas=CROSSFADE,
        checks=[('violations', '<=', 0), ('frozenMedianS', 'base+', 0.1)]),
    'cut-recovery': dict(
        cases='cut40,cut40x2,i9_cut,i9_inject,dead_start,dead_source_hold,cold_seek_stall',
        quick='cut40,i9_inject,dead_start',
        qualities='opus128', throttle='slow1500', reps=3, budget=(3, 33), args=['--verify-offset'],
        areas=HANDLER + ['lib/src/features/player/data/navis_audio_handler_recovery.dart'],
        checks=[('kinds', 'nonew'), ('violations', 'base*', 1.25, 3), ('progressLoss', 'base+', 3), ('recoveryMedianS', 'base+', 0.5)]),
    'local-seek': dict(
        cases='local_seek,i87_cached,i87_download', quick='local_seek,i87_download',
        qualities='original', throttle='wan6000', reps=3, budget=(2, 11), args=[],
        areas=['lib/src/features/downloads/**', 'lib/src/features/player/data/playback_source_resolver.dart'],
        checks=[('violations', '<=', 0), ('landingErrorMaxMs', '<=', 500), ('latencyMedianS', 'base+', 0.1)]),
    'queue-edit': dict(
        cases='queue_playnext_add,queue_reorder,q7_append_after5', quick='queue_playnext_add,queue_reorder,q7_append_after5',
        qualities='opus128', throttle='wan6000', reps=3, budget=(1, 3),
        args=[],
        areas=QUEUE,
        checks=[('violations', '<=', 0)]),
}
# Checks that only the Android build can answer, added to a scenario's own. Item 14 (Ogg cut splice): after an origin cut the
# fix reloads nothing, shows no player error, sends exactly one continuation request per cut, and the final cache file decodes
# clean and joins within the rms bound (the base line shows its reloads for comparison; the base must be >= 1 to prove the cut bites).
ANDROID_CHECKS = {'cut-recovery': [('reloadsAfterCut', '<=', 0), ('playerErrorsAfterCut', '<=', 0), ('spliceFrozenMedianS', '<=', 1.0),
                                   ('spliceRequestsOk', 'true'), ('spliceFileOk', 'true'), ('joinRmsMax', '<=', 0.005)]}
ANDROID_SCENARIOS = ('stress-drag', 'memory-soak', 'repeat', 'queue-edit', 'cut-recovery')
PLAYER_FALLBACK = 'lib/src/features/player/**'


def match(path: str, pattern: str) -> bool:
    """fnmatch where `**` crosses directories and `*` does not."""
    regex = re.escape(pattern).replace(r'\*\*', '\0').replace(r'\*', '[^/]*').replace('\0', '.*').replace(r'\?', '[^/]')
    return re.fullmatch(regex, path) is not None


def map_files(paths: list[str]) -> tuple[list[str], str]:
    """Scenarios to run for changed [paths] and a one-line reason."""
    lib = [p for p in paths if p.startswith(('lib/', 'third_party/'))]
    if not lib:
        return [], 'no lib/ or third_party/ change: nothing to measure'
    picked, unmatched = set(), []
    for path in lib:
        hit = {name for name, spec in SCENARIOS.items() if any(match(path, glob) for glob in spec['areas'])}
        if hit:
            picked |= hit
        elif match(path, PLAYER_FALLBACK):
            picked |= set(SCENARIOS)
        else:
            unmatched.append(path)
    if not picked:
        return [], f'{len(lib)} lib/ file(s) outside the playback areas'
    return [name for name in SCENARIOS if name in picked], f'{len(lib)} lib/third_party file(s) changed'


# Metrics ---------------------------------------------------------------------------------------------------

def _med(values):
    values = [v for v in values if v is not None]
    return round(statistics.median(values), 3) if values else None


def _ols_slope(ys: list[float]) -> float | None:
    n = len(ys)
    if n < 2:
        return None
    mean_x, mean_y = (n + 1) / 2, sum(ys) / n
    return sum((i + 1 - mean_x) * (y - mean_y) for i, y in enumerate(ys)) / sum((i + 1 - mean_x) ** 2 for i in range(n))


def _stall(beats: list[dict], key: str) -> dict:
    return {'max': max([b[key]['maxMicros'] for b in beats] or [0]) / 1000,
            'over50': sum(b[key]['over50ms'] for b in beats)}


def metrics(scenario: str, rows: list[dict]) -> dict:
    """Comparable numbers of one variant's engine rows."""
    hard = [v['oracle'] for r in rows for v in r['violations']]
    out = {'cells': len(rows), 'violations': len(hard), 'kinds': sorted(set(hard)),
           'caseErrors': sum(hard.count(kind) for kind in ('caseError', 'oracleError', 'appExited')),
           'latencyMedianS': _med(r['latencyS'] for r in rows),
           'frozenMedianS': _med(r['metrics'].get('maxFrozenS') for r in rows)}
    if scenario == 'stress-drag':
        drags = [r['metrics']['drag'] for r in rows if 'drag' in r['metrics']]
        flicks = [r['metrics']['flick'] for r in rows if 'flick' in r['metrics']]
        beats = [d['heartbeat'] for d in drags]
        out.update(
            drags=len(drags), flickCells=len(flicks), previewSocketMax=max([d['previewSocketMax'] for d in drags] or [0]),
            closedBeforeSuccessor=all(d['closedBeforeSuccessor'] for d in drags) and bool(drags),
            previewGETsMax=max([d['previewGETs'] for d in drags] or [0]), flickGETs=sum(f['previewGETs'] for f in flicks),
            frameGapP95Ms=_med(b['frameGap']['p95Micros'] / 1000 for b in beats),
            eventLoopP95Ms=_med(b['eventLoopLag']['p95Micros'] / 1000 for b in beats),
            frameGapStall=_stall(beats, 'frameGap'), eventLoopStall=_stall(beats, 'eventLoopLag'),
            releaseMedianS=_med(d['releaseToTargetPlus1S'] for d in drags))
    elif scenario == 'memory-soak':
        soaks = [r['metrics']['soak'] for r in rows if 'soak' in r['metrics']]
        if soaks:
            mib = 1024
            # Missing kernel data in even one repetition must not disappear into a median.
            drags_valid = all(len(soak['drags']) >= 2 and all(d.get(k) is not None for d in soak['drags']
                              for k in ('pssKiB', 'swapPssKiB')) for soak in soaks)
            gc_valid = all(soak['afterGc'].get(k) is not None for soak in soaks for k in ('pssKiB', 'swapPssKiB'))
            out.update(slopeMiBPerDrag=_med(_ols_slope([(d['pssKiB'] + d['swapPssKiB']) / mib for d in soak['drags']])
                                           for soak in soaks) if drags_valid else None,
                       postGcPssSwapMiB=_med((soak['afterGc']['pssKiB'] + soak['afterGc']['swapPssKiB']) / mib
                                            for soak in soaks) if gc_valid else None,
                       postGcPssMiB=_med(soak['afterGc']['pssKiB'] / mib for soak in soaks),
                       postGcHeapMiB=_med(soak['afterGc']['heapB'] / mib / mib for soak in soaks))
    elif scenario == 'repeat':
        cells = [r['metrics'] for r in rows if 'nextRequestLeadS' in r['metrics']]
        # Worst boundary, not the median: a boundary whose next song was never fetched counts as cold (-1 s), and no
        # cell at all is missing data (None), never a pass.
        leads = [-1.0 if v is None else v for m in cells for v in m['nextRequestLeadS']]
        local = [v for m in cells for v in m['nextSeekLocal']]
        sizes = [v for m in cells for v in m['nextBytesAtHandover']]
        out.update(nextRequestLeadMinS=min(leads) if leads else None, nextBytesAtHandoverMin=min(sizes) if sizes else None,
                   nextSeekLocalRate=round(sum(local) / len(local), 2) if local else None)
    elif scenario == 'cut-recovery':
        out['recoveryMedianS'] = _med((r['metrics'].get('cutVerdict') or {}).get('resumedAfterS') or r['metrics'].get('maxFrozenS')
                                      for r in rows)
        out['progressLoss'] = hard.count('progressLoss')
        cut_rows = [r for r in rows if 'spliceCheck' in r['metrics']]
        checks = [r['metrics']['spliceCheck'] for r in cut_rows]
        if checks:  # Android only: the Ogg cut splice (1.5.1 item 14)
            out.update(spliceFrozenMedianS=_med(r['metrics'].get('maxFrozenS') for r in cut_rows),
                       reloadsAfterCut=sum(len(c['reloads']) for c in checks), playerErrorsAfterCut=sum(len(c['playerErrors']) for c in checks),
                       spliceRequestsOk=all(c['requestsOk'] for c in checks), spliceFileOk=all(c['file']['ok'] for c in checks),
                       joinRmsMax=max([c['file'].get('maxWindowRms') or 0 for c in checks]))
    elif scenario == 'local-seek':
        errors = [e for r in rows for e in (r['metrics'].get('localSeek') or {}).get('errorsMs', [])]
        out['landingErrorMaxMs'] = max(errors) if errors else None
    return out


def invalid_cells(rows: list[dict]) -> list[str]:
    """Cells that died of a case/oracle error or an app exit: a base with one cannot be compared with."""
    return [f"{r['case']} rep {r['rep']}: {v['oracle']}" for r in rows for v in r['violations']
            if v['oracle'] in ('caseError', 'oracleError', 'appExited')]


def _fmt(value) -> str:
    if isinstance(value, float):
        return f'{value:.3f}'.rstrip('0').rstrip('.')
    return json.dumps(value) if isinstance(value, (list, dict)) else str(value)


# A software-rendered guest janks in bursts (A/A: >50 ms counts of 1 vs 46, maxima 149 vs 188 ms), so Android's stall rule is wide.
ANDROID_STALL = (3, 100)
# Linux: same-code A/As (2026-10-25) failed the old max-vs-base rule in 3 of 5 runs: fix max/over50 204.0/1 vs base 20.6/0,
# 353.8/2 vs 93.9/2, base 83.0/12 vs fix 50.9/2, and 50.2/1 vs 33.7/0 on the release comparison. Single-frame outliers
# swing the max by 100s of ms, so the max gets a wide absolute allowance (max(base max, 50) + 320 ms: 204 and 354 ms pass,
# multi-second freezes fail) and the >50 ms count is held to base + 1 (worst same-code gap +1); p95 stays gated.
LINUX_STALL_COUNT_SLACK = 1
LINUX_STALL_MAX_SLACK_MS = 320


def evaluate(scenario: str, base: dict, fix: dict, platform: str = 'linux') -> list[tuple[bool, str]]:
    """PASS/FAIL lines of one scenario from the metrics of its base and fix variants."""
    lines = []
    for check in [('caseErrors', 'clean')] + SCENARIOS[scenario]['checks'] + (ANDROID_CHECKS.get(scenario, []) if platform == 'android' else []):
        name, kind, *args = check
        f, b = fix.get(name), base.get(name)
        if kind == 'clean':  # a harness or app error in a cell is never a zero
            ok, limit = f == 0, 'no case/oracle error or app exit'
        elif kind == 'nonew':
            new = sorted(set(f or []) - set(b or []))
            ok, limit = not new, 'no kind the base lacks' + (f' (new: {new})' if new else '')
        elif f is None:
            ok, limit = False, 'metric missing in the fix run'
        elif kind == 'true':
            ok, limit = f is True, 'true'
        elif kind == '<=':
            ok, limit = f <= args[0], f'<= {_fmt(args[0])}'
        elif kind == '>=':
            ok, limit = f >= args[0], f'>= {_fmt(args[0])}'
        elif b is None:
            ok, limit = False, 'metric missing in the base run'
        elif kind == 'base+':
            ok, limit = f <= b + args[0], f'<= base + {_fmt(args[0])}'
        elif kind == 'base-positive*':
            ok, limit = f <= max(b, 0) * args[0] + args[1], f'<= max(base, 0) * {_fmt(args[0])} + {_fmt(args[1])}'
        elif kind == 'base*':
            ok, limit = f <= b * args[0] + args[1], f'<= base * {_fmt(args[0])} + {_fmt(args[1])}'
        elif kind == 'stall':
            if platform == 'android':
                factor, slack = ANDROID_STALL
                ok = f['max'] <= 50 or (f['max'] <= b['max'] * factor + slack and f['over50'] <= b['over50'] * factor + slack)
                limit = f'max <= 50 ms or (max and >50 ms count <= base * {_fmt(factor)} + {_fmt(slack)})'
            else:
                ok = f['max'] <= 50 or (f['over50'] <= b['over50'] + LINUX_STALL_COUNT_SLACK
                                        and f['max'] <= max(b['max'], 50) + LINUX_STALL_MAX_SLACK_MS)
                limit = (f'max <= 50 ms or (>50 ms count <= base + {LINUX_STALL_COUNT_SLACK} '
                         f'and max <= max(base max, 50) + {LINUX_STALL_MAX_SLACK_MS} ms)')
        else:
            raise ValueError(check)
        lines.append((ok, f"{'PASS' if ok else 'FAIL'} {scenario} {name}: fix={_fmt(f)} base={_fmt(b)} limit={limit}"))
    if scenario == 'cut-recovery' and platform == 'android':
        observed = base.get('reloadsAfterCut')
        ok = observed is not None and observed >= 1
        lines.append((ok, f"{'PASS' if ok else 'FAIL'} cut-recovery baseCutObserved: base={_fmt(observed)} "
                          'limit=base reloadsAfterCut >= 1 (otherwise comparison is vacuous)'))
    if scenario == 'memory-soak':
        lines.append((True, f"INFO {scenario} postGcPssMiB: fix={_fmt(fix.get('postGcPssMiB'))} "
                            f"base={_fmt(base.get('postGcPssMiB'))} (resident only; not gated)"))
    return lines


# Environment -----------------------------------------------------------------------------------------------

def run(cmd, **kwargs) -> subprocess.CompletedProcess:
    kwargs.setdefault('timeout', 120)
    return subprocess.run(cmd, text=True, capture_output=True, **kwargs)


def _owned_children(parent, parent_fd=None):
    """Open stable handles only while the parent is still the same owned process."""
    try:
        children = Path(f'/proc/{parent}/task/{parent}/children').read_text().split()
    except FileNotFoundError:
        return
    for child in children:
        pid = int(child)
        fd = None
        try:
            fd = os.pidfd_open(pid)
            # The child cannot be reused while it remains our unreaped child.
            stat = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            if parent_fd is not None:
                signal.pidfd_send_signal(parent_fd, 0)
            if int(stat[1]) != parent:
                os.close(fd)
                continue
        except ProcessLookupError:
            if fd is not None:
                os.close(fd)
            continue
        except FileNotFoundError:
            os.close(fd)
            continue
        yield pid, fd


def _command_owner(cmd, descriptors, grace):
    """Linux-only private subreaper: retain locks until every descendant is reaped."""
    import ctypes
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER, before spawning anything
        raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER')
    probe = os.pidfd_open(os.getpid())
    try:
        signal.pidfd_send_signal(probe, 0)
    finally:
        os.close(probe)
    cancelled = False

    def cancel(*_):
        nonlocal cancelled
        cancelled = True

    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    proc = subprocess.Popen(cmd, pass_fds=descriptors, start_new_session=True)
    while proc.poll() is None and not cancelled:
        time.sleep(0.02)
    deadline = time.monotonic() + grace
    termed = set()

    def terminate(parent, sig, parent_fd=None):
        for pid, fd in _owned_children(parent, parent_fd):
            try:
                # Traverse before signalling the parent; its pidfd must still be live.
                terminate(pid, sig, fd)
                signal.pidfd_send_signal(fd, 0)
                identity = (pid, os.fstat(fd).st_ino)
                if sig == signal.SIGKILL or identity not in termed:
                    signal.pidfd_send_signal(fd, sig)
                    termed.add(identity)
            except ProcessLookupError:
                pass
            finally:
                os.close(fd)

    while True:
        terminate(os.getpid(), signal.SIGTERM if time.monotonic() < deadline else signal.SIGKILL)
        # Reap adopted children too, including children in unrelated sessions.
        try:
            while True:
                pid, status = os.waitpid(-1, os.WNOHANG)
                if not pid:
                    break
                if pid == proc.pid:
                    proc.returncode = os.waitstatus_to_exitcode(status)
        except ChildProcessError:
            break
        time.sleep(0.02)
    code = proc.returncode
    if code < 0:
        signal.signal(-code, signal.SIG_DFL)
        os.kill(os.getpid(), -code)
    return code


def bounded_command(cmd, *, timeout, cleanup_grace=60, **kwargs):
    if not (sys.platform == 'linux' and hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal')):
        raise InfraError('bounded commands require Linux child-subreaper and pidfd support')
    descriptors = tuple(kwargs.get('pass_fds', ()))
    owner = [sys.executable, '-c',
             'import sys; sys.path.insert(0,sys.argv[1]); import playback_harness as h; '
             'sys.exit(h._command_owner(sys.argv[4:],tuple(map(int,filter(None,sys.argv[2].split(",")))),float(sys.argv[3])))',
             str(Path(__file__).resolve().parent), ','.join(map(str, descriptors)), str(cleanup_grace), *cmd]
    with subprocess.Popen(owner, start_new_session=True, **kwargs) as proc:
        proc.cleanup_owner = True
        try:
            return subprocess.CompletedProcess(cmd, proc.wait(timeout))
        except BaseException as error:
            # Repeated cancellation must not interrupt cleanup or release inherited locks.
            while True:
                try:
                    stop_group(proc)
                    break
                except (KeyboardInterrupt, SystemExit):
                    continue
            if isinstance(error, subprocess.TimeoutExpired):
                error.command_exit = proc.returncode
            raise


def git(*args, cwd=PROJECT) -> str:
    done = run(['git', *args], cwd=cwd)
    if done.returncode:
        raise InfraError(f'git {" ".join(args)}: {done.stderr.strip()}')
    return done.stdout.strip()


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def candidate_identity(root: Path = PROJECT) -> dict:
    """Hash source bytes and modes, never retain file contents (including secrets)."""
    done = run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root)
    if done.returncode:
        raise InfraError('cannot inventory candidate')
    files = {}
    for name in sorted(set(done.stdout.split('\0')) - {''}):
        path = root / name
        if path.is_symlink():
            digest = hashlib.sha256(os.fsencode(os.readlink(path))).hexdigest()
        elif path.is_file():
            digest = sha256(path)
        elif not path.exists():
            digest = None
        else:
            raise InfraError(f'unsupported source entry: {name}')
        files[name] = [digest, path.lstat().st_mode if path.exists() or path.is_symlink() else None]
    payload = {'head': git('rev-parse', 'HEAD', cwd=root), 'files': files,
               'index': git('ls-files', '--stage', cwd=root)}
    return {'head': payload['head'], 'sha256': hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest(),
            'fileCount': len(files)}


def environment_identity() -> dict:
    # Hash relevant configuration, not shell/orchestrator/session bookkeeping.
    prefixes = ('NAVIS_', 'FLUTTER_', 'DART_', 'PUB_', 'GRADLE_', 'JAVA_', 'ANDROID_',
                'LD_', 'DYLD_', 'CMAKE_', 'CCACHE_', 'PKG_CONFIG_', 'JDK_', 'CARGO_', 'RUSTUP_', 'LC_', 'QT_', 'KWIN_', 'GDK_',
                'GST_', 'PIPEWIRE_', 'PULSE_', 'ALSA_', 'MESA_', 'LIBGL_', 'VK_')
    keys = {'PATH', 'HOME', 'USER', 'SHELL', 'LANG', 'TZ', 'TMPDIR', 'CC', 'CXX',
            'CFLAGS', 'CXXFLAGS', 'LDFLAGS', 'RUSTFLAGS', '_JAVA_OPTIONS', 'LANGUAGE', 'TMP', 'TEMP', 'DISPLAY', 'WAYLAND_DISPLAY', 'XDG_RUNTIME_DIR',
            'XDG_DATA_DIRS', 'XDG_CONFIG_HOME', 'DBUS_SESSION_BUS_ADDRESS', 'CI',
            'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy',
            'all_proxy', 'no_proxy', 'SSL_CERT_FILE', 'SSL_CERT_DIR', 'SHUFFLE_SHOT_LABEL'}
    relevant = {k: v for k, v in os.environ.items()
                if (k in keys or k.startswith(prefixes)) and k != 'NAVIS_HARNESS_CAPPED'}
    return {'system': [os.uname().sysname, os.uname().release, os.uname().machine], 'python': sys.version,
            'environmentSha256': hashlib.sha256(json.dumps(relevant, sort_keys=True).encode()).hexdigest(),
            'dataRoot': str(DATA), 'suffix': SUFFIX, 'avd': SOURCE_AVD, 'guestMiB': GUEST_MIB}


def expected_cells(name: str, full: bool, reps: int | None, platform: str) -> list[list]:
    if reps is not None and reps < 1:
        raise InfraError('repetitions must be positive')
    cases, repetitions, _ = plan(name, full, reps, platform)
    if repetitions < 1:
        raise InfraError('repetitions must be positive')
    spec = SCENARIOS[name]
    return [[case, quality, throttle, rep] for case in cases.split(',')
            for quality in spec['qualities'].split(',') for throttle in spec['throttle'].split(',')
            for rep in range(repetitions)]


def observed_cells(rows: list[dict], exit_code: int | None = None) -> list[list]:
    try:
        cells = [[r[k] for k in ('case', 'quality', 'throttle', 'rep')] for r in rows]
        for row in rows:
            if not isinstance(row['metrics'], dict) or not isinstance(row['violations'], list):
                raise ValueError('invalid metrics/violations')
            if type(row['passed']) is not bool or type(row['rep']) is not int:
                raise ValueError('invalid status/repetition')
            if row['passed'] != (not row['violations']):
                raise ValueError('verdict contradicts violations')
            if any(not isinstance(v, dict) or not isinstance(v.get('oracle'), str) for v in row['violations']):
                raise ValueError('invalid violation')
            row['latencyS']
        if exit_code is not None and exit_code != (0 if all(r['passed'] for r in rows) else 1):
            raise ValueError('exit contradicts report verdicts')
        return cells
    except (KeyError, TypeError, ValueError) as error:
        raise InfraError('malformed engine rows') from error


def validate_cells(expected: list[list], observed: list[list]):
    try:
        actual = [tuple(cell) for cell in observed]
        if len(set(actual)) != len(actual) or set(actual) != {tuple(cell) for cell in expected}:
            raise InfraError('missing, duplicate or wrong engine cells')
    except TypeError as error:
        raise InfraError('malformed cell identity') from error


def write_evidence(out: Path, evidence: dict):
    target = out / 'evidence.json'
    temporary = target.with_suffix('.tmp')
    temporary.write_text(json.dumps(evidence, indent=1, allow_nan=False))
    temporary.replace(target)


def verify_evidence(out: Path, candidate: dict, environment: dict, config: dict) -> dict:
    """Fail closed when reusing evidence; callers supply the required exact configuration."""
    try:
        record = json.loads((out / 'evidence.json').read_text())
        if (record['schema'] != 1 or record['status'] != 'passed' or record['exitCode'] != 0
                or record['candidate'] != candidate or record['candidateAfter'] != candidate
                or record['environment'] != environment or record['config'] != config):
            raise InfraError('stale or unsuccessful evidence')
        if record['base'] != config['baseSha'] or record['flutter'] != config['flutter']:
            raise InfraError('wrong base or Flutter identity')
        if config.get('all') and config['full'] and config['reps'] is None and record.get('coverage') != 'full-platform':
            raise InfraError('not full-platform evidence')
        base_artifact = record['baseArtifact']
        if sha256(Path(base_artifact['path'])) != base_artifact['sha256']:
            raise InfraError('changed base artifact')
        required = {(v, n) for v in ('base', 'fix') for n in config['names']}
        if set(record['variants']) != {v + '/' + n for v, n in required}:
            raise InfraError('incomplete variant evidence')
        for key, variant in record['variants'].items():
            expected = expected_cells(key.split('/')[1], config['full'], config['reps'], config['platform'])
            if variant['expected'] != expected:
                raise InfraError('wrong expected cells')
            if variant['status'] != 'complete' or variant['exitCode'] not in (0, 1):
                raise InfraError('incomplete engine evidence')
            validate_cells(variant['expected'], variant['observed'])
            rows = json.loads(Path(variant['report']).read_text())['results']
            if observed_cells(rows, variant['exitCode']) != variant['observed']:
                raise InfraError('report differs from observed cells')
            if key.startswith('base/') and invalid_cells(rows):
                raise InfraError('invalid base cells')
        required_artifacts = [out / 'comparison.json', out / 'summary.md']
        required_artifacts += [Path(v[k]) for v in record['variants'].values() for k in ('report', 'log')]
        if any(str(p) not in record['artifacts'] for p in required_artifacts):
            raise InfraError('missing required artifact pointers')
        if not record['artifacts']:
            raise InfraError('missing artifacts')
        for name, digest in record['artifacts'].items():
            path = Path(name)
            if not path.is_file() or sha256(path) != digest:
                raise InfraError('missing or changed artifact')
        comparison = json.loads((out / 'comparison.json').read_text())
        if (comparison['base'] != record['base'] or comparison['fix'] != candidate['head']
                or comparison['platform'] != config['platform'] or set(comparison['scenarios']) != set(config['names'])):
            raise InfraError('wrong comparison identity')
        for name in config['names']:
            measured = {}
            for variant in ('base', 'fix'):
                rows = json.loads(Path(record['variants'][variant + '/' + name]['report']).read_text())['results']
                measured[variant] = metrics(name, rows)
            if not all(ok for ok, _ in evaluate(name, measured['base'], measured['fix'], config['platform'])):
                raise InfraError('comparison thresholds failed')
        return record
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError) as error:
        raise InfraError('malformed or missing evidence/artifact') from error


def downloads_snapshot() -> dict:
    if not DOWNLOADS.exists():
        return {}
    return {str(p.relative_to(DOWNLOADS)): [p.stat().st_size, sha256(p)] for p in sorted(DOWNLOADS.rglob('*')) if p.is_file()}


def flutter_version() -> str:
    done = run(['flutter', '--version', '--machine'])
    if done.returncode:
        raise InfraError(f'flutter --version failed: {done.stderr.strip()}')
    try:
        version = json.loads(done.stdout)
        if not isinstance(version, dict) or not all(version.get(k) for k in ('frameworkRevision', 'engineRevision', 'dartSdkVersion')):
            raise ValueError('missing Flutter framework/engine/Dart revision')
        return json.dumps(version, sort_keys=True)
    except (ValueError, TypeError) as error:
        raise InfraError('malformed flutter --version --machine identity') from error


def cache_key(sha: str, platform: str, flutter: str) -> str:
    """Base build identity: commit + platform + Flutter + the defines the engine bakes in + the libmpv tree."""
    libmpv = git('rev-parse', f'{sha}:tool/libmpv')
    digest = hashlib.sha256(f'{flutter}|{SUFFIX}|{DATA}|{libmpv}'.encode()).hexdigest()[:10]
    return f'{sha[:12]}-{platform}-{digest}'


def artifact_of(platform: str, folder: Path) -> Path:
    return folder / ('app.apk' if platform == 'android' else 'bundle/lib/libapp.so')


def engine_env(extra: dict | None = None) -> dict:
    env = {**os.environ, 'NAVIS_LIVE_SEEK_BASE': str(DATA), 'NAVIS_LIVE_SEEK_SUFFIX': SUFFIX,
           'GRADLE_OPTS': '-Dorg.gradle.daemon=false -Dorg.gradle.workers.max=2 -Dorg.gradle.jvmargs=-Xmx4G'}
    env.update(extra or {})
    return env


def build(tree: Path, platform: str, dest: Path, log: Path):
    """Builds [tree] with its own engine copy (same dart-defines for every variant) and moves the artifact to [dest]."""
    DATA.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    android = ['--android', 'build'] if platform == 'android' else []
    env = engine_env({'NAVIS_LIVE_SEEK_APK': str(dest / 'app.apk')})
    root_bundle = DATA / 'root' / 'bundle'
    if root_bundle.is_symlink():
        root_bundle.unlink()
    started = time.monotonic()
    record = {'status': 'running', 'exitCode': None, 'log': str(log)}
    record_path = log.with_suffix('.result.json')
    record_path.write_text(json.dumps(record))
    try:
        with log.open('w') as out:
            done = bounded_command([sys.executable, str(tree / 'tool' / 'live_seek_stress.py'), '--profile', 'full', '--server', 'fixture',
                                   '--build-only', *android], cwd=tree, env=env, stdout=out, stderr=subprocess.STDOUT, timeout=3600)
        record.update(status='complete' if done.returncode == 0 else 'failed', exitCode=done.returncode)
    except BaseException as error:
        record.update(status='timeout' if isinstance(error, subprocess.TimeoutExpired) else 'incomplete',
                      exitCode=getattr(error, 'command_exit', None), errorType=type(error).__name__)
        raise
    finally:
        record['seconds'] = round(time.monotonic() - started, 1)
        record_path.write_text(json.dumps(record))
    built = (dest / 'app.apk').exists() if platform == 'android' else root_bundle.exists()
    if done.returncode or not built:
        raise InfraError(f'{platform} build of {tree} failed (logs: {log}, {DATA / ("build-android.log" if platform == "android" else "build.log")})')
    if platform == 'linux':
        shutil.move(str(root_bundle), str(dest / 'bundle'))
    return round(time.monotonic() - started, 1)


def provenance(sha: str, platform: str, folder: Path, key: str, seconds: float) -> dict:
    return {'commit': sha, 'platform': platform, 'key': key, 'artifactSha256': sha256(artifact_of(platform, folder)),
            'buildSeconds': seconds, 'builtAt': datetime.now(timezone.utc).isoformat(timespec='seconds')}


def base_build(sha: str, platform: str, flutter: str, out: Path) -> tuple[Path, str]:
    """Cached build of a base commit; a detached temporary worktree builds it on a miss."""
    key = cache_key(sha, platform, flutter)
    folder = CACHE / 'base' / key
    record = folder / 'provenance.json'
    if record.exists():
        known = json.loads(record.read_text())
        if artifact_of(platform, folder).exists() and sha256(artifact_of(platform, folder)) == known['artifactSha256']:
            return folder, f"cache hit {key} (built {known['builtAt']}, {known['buildSeconds']} s)"
        shutil.rmtree(folder)
    tree = CACHE / 'worktrees' / key
    shutil.rmtree(tree, ignore_errors=True)
    tree.parent.mkdir(parents=True, exist_ok=True)
    git('worktree', 'add', '--detach', str(tree), sha)
    try:
        with (out / 'base-bootstrap.log').open('w') as log:
            done = bounded_command(['tool/bootstrap.sh'], timeout=1200, cwd=tree, stdout=log, stderr=subprocess.STDOUT)
        if done.returncode:
            raise InfraError(f'bootstrap of the base worktree failed: exit {done.returncode}; see {out / "base-bootstrap.log"}')
        seconds = build(tree, platform, folder, out / f'base-build-{platform}.log')
    except BaseException:
        shutil.rmtree(folder, ignore_errors=True)  # never leave a half-built entry that could pass for a cache hit
        raise
    finally:
        run(['git', 'worktree', 'remove', '--force', str(tree)], cwd=PROJECT)
    record.write_text(json.dumps(provenance(sha, platform, folder, key, seconds), indent=1))
    return folder, f'cache miss {key}: built in {seconds} s'


def fix_build(platform: str, out: Path) -> Path:
    folder = out / 'fix-build'
    build(PROJECT, platform, folder, out / f'fix-build-{platform}.log')
    return folder


class Display:
    """A headless KWin Wayland session for the Linux app, started and killed by this tool."""

    def __init__(self, out: Path):
        self.out, self.proc = out, None
        self.socket = f'navisharness{os.getpid()}'  # unique: never adopt a session this run did not start

    def __enter__(self):
        try:
            return self._acquire()
        except BaseException:
            self.__exit__()
            raise

    def _acquire(self):
        runtime = os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')
        if (Path(runtime) / self.socket).exists():
            raise InfraError(f'Wayland socket {self.socket} already exists (stale session?)')
        env = {k: v for k, v in os.environ.items() if k != 'DISPLAY'}
        env.update(KWIN_COMPOSE='QPainter', QT_QPA_PLATFORM='offscreen', XDG_RUNTIME_DIR=runtime)
        self.proc = subprocess.Popen(
            ['dbus-run-session', '--', 'kwin_wayland', '--virtual', '--socket', self.socket, '--width', '1280', '--height', '800',
             '--no-lockscreen', '--no-global-shortcuts', '--no-kactivities', '--inputmethod', '/bin/true'],
            env=env, stdout=(self.out / 'kwin.log').open('w'), stderr=subprocess.STDOUT, start_new_session=True)
        socket_path = Path(runtime) / self.socket
        for _ in range(100):
            if socket_path.exists():
                break
            time.sleep(0.1)
        else:
            raise InfraError('headless kwin_wayland did not create its socket')
        return {'WAYLAND_DISPLAY': self.socket, 'GDK_BACKEND': 'wayland', 'XDG_RUNTIME_DIR': runtime}

    def __exit__(self, *_):
        stop_group(self.proc)


def stop_group(proc, grace=10):
    if proc is None:
        return
    if getattr(proc, 'cleanup_owner', False):
        if proc.poll() is None:
            proc.send_signal(signal.SIGTERM)
        proc.wait()  # The subreaper owns the cleanup deadline, not its caller.
        return
    # A reaped leader's numeric process group may already belong to somebody else.
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(grace)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
    except ProcessLookupError:
        proc.wait()


class Emulator:
    """A disposable Android guest (3072 MiB, 2 cores, swiftshader), cloned from an installed AVD and removed on exit."""

    def __init__(self, out: Path):
        self.out, self.proc = out, None
        self.name = f'Navis_Harness_{os.getpid()}'
        self.home = Path.home() / '.android' / 'avd'
        self.created = False

    def check(self):
        source = self.home / f'{SOURCE_AVD}.avd' / 'config.ini'
        if not source.exists():
            raise InfraError(f'AVD {SOURCE_AVD!r} not found under {self.home} (set NAVIS_HARNESS_AVD)')
        for tool in (ANDROID_HOME / 'emulator' / 'emulator', ANDROID_HOME / 'platform-tools' / 'adb'):
            if not tool.exists():
                raise InfraError(f'{tool} not found (set ANDROID_HOME)')

    def __enter__(self) -> str:
        try:
            return self._acquire()
        except BaseException:
            self.__exit__()
            raise

    def _acquire(self) -> str:
        self.check()
        values = dict(line.split('=', 1) for line in (self.home / f'{SOURCE_AVD}.avd' / 'config.ini').read_text().splitlines() if '=' in line)
        values.update({'AvdId': self.name, 'avd.ini.displayname': self.name, 'disk.dataPartition.size': '4G',
                       'hw.ramSize': str(GUEST_MIB), 'hw.cpu.ncore': '2', 'PlayStore.enabled': 'false', 'hw.keyboard': 'yes'})
        folder = self.home / f'{self.name}.avd'
        if (self.home / f'{self.name}.ini').exists():
            raise InfraError(f'refusing existing AVD registration: {self.name}')
        folder.mkdir()
        self.created = True
        (folder / 'config.ini').write_text(''.join(f'{k}={v}\n' for k, v in values.items()))
        (self.home / f'{self.name}.ini').write_text(f'avd.ini.encoding=UTF-8\npath={folder}\n')
        port = next((p for p in range(5620, 5682, 2) if self._free(p) and self._free(p + 1)), None)
        if port is None:
            raise InfraError('no free emulator port')
        self.serial = f'emulator-{port}'
        self.adb = [str(ANDROID_HOME / 'platform-tools' / 'adb'), '-s', self.serial]
        self.proc = subprocess.Popen(
            [str(ANDROID_HOME / 'emulator' / 'emulator'), '-avd', self.name, '-port', str(port), '-no-snapshot', '-no-boot-anim',
             '-wipe-data', '-no-window', '-no-audio', '-gpu', 'swiftshader_indirect', '-memory', str(GUEST_MIB), '-cores', '2',
             '-partition-size', '4096'],
            stdout=(self.out / 'emulator.log').open('w'), stderr=subprocess.STDOUT, start_new_session=True)
        deadline = time.monotonic() + 240
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise InfraError(f'emulator exited with {self.proc.returncode} (see {self.out / "emulator.log"})')
            if run(self.adb + ['shell', 'getprop', 'sys.boot_completed'], timeout=15).stdout.strip() == '1':
                break
            time.sleep(2)
        else:
            raise InfraError('emulator boot timed out')
        for setting in (['settings', 'put', 'system', 'screen_off_timeout', '2147483647'], ['svc', 'power', 'stayon', 'true']):
            run(self.adb + ['shell', *setting], timeout=30)
        time.sleep(40)  # a fresh image keeps doing first-boot work after boot_completed
        return self.serial

    @staticmethod
    def _free(port: int) -> bool:
        with socket.socket() as sock:
            try:
                sock.bind(('127.0.0.1', port))
                return True
            except OSError:
                return False

    def __exit__(self, *_):
        try:
            if self.proc is not None:
                try:
                    run(self.adb + ['emu', 'kill'], timeout=30)
                except (OSError, subprocess.TimeoutExpired):
                    pass  # a hung/missing adb must not keep this task's guest alive
                finally:
                    stop_group(self.proc)
        finally:
            if self.created:
                shutil.rmtree(self.home / f'{self.name}.avd', ignore_errors=True)
                (self.home / f'{self.name}.ini').unlink(missing_ok=True)


# A/B runner ------------------------------------------------------------------------------------------------

def seed_android(base_sha: str, flutter: str, display_env: dict, out: Path):
    """Android is seeded with a synced Linux catalog; made once per base from the base's cached Linux bundle."""
    linux, note = base_build(base_sha, 'linux', flutter, out)
    print(f'android seed: linux base {note}')
    seed = linux.parent / f'{linux.name}-seed.sqlite'
    if not seed.exists():
        activate(linux, 'linux')
        done = engine(['--seed-only'], display_env, out / 'seed', {}, timeout=1200, label='seed')
        if done.returncode or not (DATA / 'root' / 'navis.sqlite').exists():
            raise InfraError('could not seed the Android catalog from a Linux run')
        shutil.copyfile(DATA / 'root' / 'navis.sqlite', seed)
    return seed


def activate(folder: Path, platform: str, seed: Path | None = None):
    """Wipes the data root and points it at [folder]'s build (Linux symlinks the bundle)."""
    shutil.rmtree(DATA / 'root', ignore_errors=True)
    (DATA / 'root').mkdir(parents=True)
    if platform == 'linux':
        (DATA / 'root' / 'bundle').symlink_to(folder / 'bundle')
    if seed is not None:
        shutil.copyfile(seed, DATA / 'root' / 'navis.sqlite')
        (DATA / 'root' / 'profile-server').write_text('fixture')


def engine(args: list[str], env: dict, out: Path, extra_env: dict, timeout: int, label: str):
    out.mkdir(parents=True, exist_ok=True)
    full = {**engine_env(extra_env), **env, 'NAVIS_LIVE_SEEK_RUNS': str(out / 'runs')}
    with (out / f'{label}.log').open('w') as log:
        return bounded_command([sys.executable, '-c',
                               'import os,runpy,signal,sys; signal.signal(signal.SIGTERM,lambda *_:sys.exit(143)); '
                               'sys.argv=sys.argv[1:]; sys.path.insert(0,os.path.dirname(sys.argv[0])); runpy.run_path(sys.argv[0],run_name="__main__")',
                               str(PROJECT / 'tool' / 'live_seek_stress.py'), '--profile', 'full', '--server', 'fixture',
                               '--skip-build', '--proxy-chunked', '--transcode-speed', '3', '--label', label, *args],
                              cwd=PROJECT, env=full, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)


def plan(name: str, full: bool, reps: int | None, platform: str = 'linux') -> tuple[str, int, int]:
    """(cases, reps, budget minutes) of a scenario in the quick or full set."""
    spec = SCENARIOS[name]
    cases, repetitions, budget = ((spec['cases'], reps or spec['reps'], spec['budget'][1]) if full
                                  else (spec['quick'], reps or spec.get('qreps', 1), spec['budget'][0]))
    if name == 'cut-recovery' and full and platform == 'android':
        cases += ',cut5'
        budget = 37
    return cases, repetitions, budget


def run_scenario(name: str, platform: str, variant_dir: Path, display_env: dict, serial: str | None, apk: Path | None,
                 full: bool, reps: int | None, real: bool) -> tuple[list[dict], float]:
    spec = SCENARIOS[name]
    cases, reps, budget = plan(name, full, reps, platform)
    args = ['--cases', cases, '--qualities', spec['qualities'], '--throttles', spec['throttle'], '--reps', str(reps), *spec['args']]
    extra, env = ({} if full else dict(spec.get('quick_env', {}))), dict(display_env)
    if serial:
        args += ['--android', serial]
        extra['NAVIS_LIVE_SEEK_APK'] = str(apk)
    if spec.get('vm'):
        extra['NAVIS_LIVE_SEEK_VM'] = '1'
        if not serial:
            extra.update(FLUTTER_ENGINE_SWITCHES='2', FLUTTER_ENGINE_SWITCH_1='enable-dart-profiling',
                         FLUTTER_ENGINE_SWITCH_2='vm-service-port=0')
    if real:
        credentials = Path.home() / '.config' / 'navis' / 'perf-credentials.json'
        if not credentials.exists() or credentials.stat().st_mode & 0o077:
            raise InfraError(f'--real needs {credentials} with mode 600')
        args += ['--credentials', str(credentials)]
    started = time.monotonic()
    record = {'status': 'running', 'expected': expected_cells(name, full, reps, platform),
              'observed': [], 'exitCode': None, 'log': str(variant_dir / (name + '.log'))}
    variant_dir.mkdir(parents=True, exist_ok=True)
    write_evidence(variant_dir, record)
    try:
        done = engine(args, env, variant_dir, extra, timeout=budget * 60 * 4 + 600, label=name)
        record['exitCode'] = done.returncode
        reports = sorted((variant_dir / 'runs').glob(f'*-{name}/report.json'))
        if done.returncode not in (0, 1) or len(reports) != 1:
            raise InfraError(f'engine {name}: exit {done.returncode}, {len(reports)} reports')
        if not Path(record['log']).is_file():
            raise InfraError('engine log missing')
        record['report'] = str(reports[0])
        rows = json.loads(reports[0].read_text())['results']
        record['observed'] = observed_cells(rows, done.returncode)
        validate_cells(record['expected'], record['observed'])
        record['cellStatuses'] = ['passed' if r['passed'] else 'failed' for r in rows]
        record['status'] = 'complete'
        return rows, round(time.monotonic() - started, 1)
    except BaseException as error:
        record['status'] = 'timeout' if isinstance(error, subprocess.TimeoutExpired) else 'incomplete'
        if isinstance(error, subprocess.TimeoutExpired):
            record['exitCode'] = getattr(error, 'command_exit', None)
        record['errorType'] = type(error).__name__
        if isinstance(error, (KeyboardInterrupt, SystemExit, InfraError)):
            raise
        raise InfraError(f'engine {name}: {record["status"]} ({type(error).__name__}); see {variant_dir}') from error
    finally:
        if record['status'] != 'complete':
            partial = sorted((variant_dir / 'runs').glob(f'*-{name}/report.json'))
            record['reports'] = [str(p) for p in partial]
            if len(partial) == 1:
                try:
                    record['observed'] = observed_cells(json.loads(partial[0].read_text())['results'])
                except (InfraError, OSError, ValueError, KeyError, TypeError):
                    record['reportMalformed'] = True
        record['seconds'] = round(time.monotonic() - started, 1)
        write_evidence(variant_dir, record)


def pick_scenarios(args) -> list[str]:
    if not (args.all or args.map or args.scenarios):
        raise InfraError('usage: name scenarios, or pass --map or --all (see `list`)')
    if args.all:
        return list(SCENARIOS)
    if args.map:
        names, why = map_files(git('diff', '--name-only', args.base_range).splitlines())
        print(f'map: {why}: {", ".join(names) or "none"}')
        return names
    unknown = [s for s in args.scenarios if s not in SCENARIOS]
    if unknown:
        raise InfraError(f'unknown scenario(s) {unknown}; see `list`')
    return args.scenarios


def _cmd_ab(args, out: Path, evidence: dict) -> int:
    names = pick_scenarios(args)
    platform = args.platform
    if args.map and not names:
        print('RESULT NONE: no playback code changed')
        return 0
    if platform == 'android':
        skipped = [n for n in names if n not in ANDROID_SCENARIOS]
        if skipped and not (args.map or args.all):
            raise InfraError(f'not available on Android: {skipped} (Android runs {list(ANDROID_SCENARIOS)})')
        for name in skipped:
            print(f'SKIP {name}: linux-only', flush=True)
        names = [n for n in names if n in ANDROID_SCENARIOS]
        if not names:
            raise InfraError('every selected scenario is Linux-only: run with --platform linux')
    if len(set(names)) != len(names):
        raise InfraError('duplicate scenarios')
    evidence['config']['names'] = names
    evidence['coverage'] = 'full-platform' if (args.all and args.full and args.reps is None and not args.map) else 'iteration'
    evidence['variants'] = {v + '/' + n: {'status': 'not-run', 'expected': expected_cells(n, args.full, args.reps, platform),
                                        'observed': [], 'exitCode': None} for v in ('base', 'fix') for n in names}
    write_evidence(out, evidence)
    base_ref = args.base
    base_sha = git('rev-parse', '--verify', f'{base_ref}^{{commit}}')
    if run(['git', 'cat-file', '-e', f'{base_sha}:tool/playback_harness.py'], cwd=PROJECT).returncode:
        raise InfraError(f'base {base_ref} ({base_sha[:12]}) predates this harness: use a commit at or after its merge')
    if platform == 'android':
        Emulator(Path('.')).check()
    dirty = bool(git('status', '--porcelain', '--untracked-files=no'))
    fix_sha = git('rev-parse', 'HEAD')
    stamp = out.name
    evidence.update(base=base_sha, fix=fix_sha)
    evidence['config']['baseSha'] = base_sha
    flutter = flutter_version()
    evidence['flutter'] = flutter
    evidence['config']['flutter'] = flutter
    write_evidence(out, evidence)
    before = downloads_snapshot()
    (out / 'downloads-before.json').write_text(json.dumps(before))
    t0 = time.monotonic()
    base_dir, cache_note = base_build(base_sha, platform, flutter, out)
    evidence['baseBuildSeconds'] = round(time.monotonic() - t0, 1)
    evidence['baseArtifact'] = {'path': str(artifact_of(platform, base_dir)),
                                'sha256': sha256(artifact_of(platform, base_dir))}
    print(f'base {base_ref} {base_sha[:12]}: {cache_note} ({round(time.monotonic() - t0, 1)} s)')
    t1 = time.monotonic()
    fix_dir = fix_build(platform, out)
    evidence['fixBuildSeconds'] = round(time.monotonic() - t1, 1)
    write_evidence(out, evidence)
    if candidate_identity() != evidence['candidate']:
        raise InfraError('candidate changed during builds')
    print(f'fix {fix_sha[:12]}{" (dirty tree)" if dirty else ""}: built in {round(time.monotonic() - t1, 1)} s')
    results, timings = {}, {}
    with ExitStack() as stack:
        display_env = stack.enter_context(Display(out))
        seed = seed_android(base_sha, flutter, display_env, out) if platform == 'android' else None
        for variant, folder in (('base', base_dir), ('fix', fix_dir)):
            for name in names:
                for attempt in (1, 2):
                    # A fresh guest per scenario: the emulator's GPU translator has crashed (qemu core dump) minutes into
                    # a session, and a wiped guest starts both variants from the same state. A run that lost its guest
                    # is repeated once.
                    retry = False
                    with ExitStack() as guest:
                        emulator = Emulator(out) if platform == 'android' else None
                        serial = guest.enter_context(emulator) if emulator else None
                        apk = artifact_of('android', folder) if serial else None
                        if candidate_identity() != evidence['candidate']:
                            raise InfraError('candidate changed before scenario')
                        activate(folder, platform, seed)
                        try:
                            rows, seconds = run_scenario(name, platform, out / variant / name / f'attempt-{attempt}', display_env, serial, apk,
                                                         args.full, args.reps, args.real)
                        except InfraError:
                            retry = emulator is not None and attempt == 1 and emulator.proc.poll() is not None
                            if not retry:
                                raise
                    if retry:
                        print(f'{variant} {name}: the emulator died, repeating once', flush=True)
                        continue
                    break
                if variant == 'base' and invalid_cells(rows):
                    raise InfraError(f'base {name} is not a valid comparison: {invalid_cells(rows)} (logs: {out / variant / name})')
                results[(variant, name)] = metrics(name, rows)
                timings[(variant, name)] = seconds
                print(f'{variant} {name}: {len(rows)} cells in {seconds} s', flush=True)
    after = downloads_snapshot()
    if after != before:
        raise InfraError(f'{DOWNLOADS} changed during the run (before/after in {out})')
    lines, comparison, ok = [], {}, True
    for name in names:
        checked = evaluate(name, results[('base', name)], results[('fix', name)], platform)
        ok &= all(good for good, _ in checked)
        lines += [line for _, line in checked]
        comparison[name] = {'base': results[('base', name)], 'fix': results[('fix', name)], 'checks': [line for _, line in checked],
                            'seconds': {v: timings[(v, name)] for v in ('base', 'fix')}}
    if candidate_identity() != evidence['candidate']:
        raise InfraError('candidate changed during run')
    result = f"RESULT {'PASS' if ok else 'FAIL'}"
    (out / 'comparison.json').write_text(json.dumps({'base': base_sha, 'fix': fix_sha, 'platform': platform, 'scenarios': comparison}, indent=1))
    (out / 'summary.md').write_text('\n'.join([f'# Playback harness {stamp} ({platform})', '', f'base {base_ref} {base_sha}', f'fix {fix_sha}', '',
                                               *[f'    {line}' for line in lines], '', result, '']))
    print('\n'.join(lines + [result, f'summary: {out / "summary.md"}']))
    return 0 if ok else 1


def cmd_ab(args) -> int:
    out = Path(args.output) if getattr(args, 'output', None) else PROJECT / 'build' / 'harness' / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    out.mkdir(parents=True)
    started = time.monotonic()
    evidence = {'schema': 1, 'status': 'incomplete', 'exitCode': None, 'variants': {}, 'artifacts': {},
                'startedAt': datetime.now(timezone.utc).isoformat(), 'candidate': candidate_identity(),
                'environment': environment_identity(), 'config': vars(args).copy()}
    evidence['config'].pop('fn')
    evidence['config'].pop('output', None)
    evidence['config']['names'] = []
    write_evidence(out, evidence)
    try:
        with heavy_lock(out, CACHE):
            code = _cmd_ab(args, out, evidence)
        evidence['exitCode'] = code
        evidence['status'] = 'passed' if code == 0 and (out / 'comparison.json').exists() else 'failed'
        return code
    except BaseException as error:
        evidence['exitCode'] = 2
        evidence['errorType'] = type(error).__name__
        evidence['error'] = str(error)
        raise
    finally:
        original_error = sys.exc_info()[1]
        try:
            evidence['candidateAfter'] = candidate_identity()
            if evidence['candidateAfter'] != evidence['candidate']:
                evidence['status'], evidence['exitCode'] = 'incomplete', 2
            for path in sorted(out.glob('*/*/attempt-*/evidence.json')):
                key = str(path.parent.parent.relative_to(out))
                attempt = json.loads(path.read_text())
                previous = evidence['variants'][key]
                attempt['attempts'] = previous.get('attempts', []) + [str(path)]
                evidence['variants'][key] = attempt
            evidence['artifacts'] = {str(p): sha256(p) for p in out.rglob('*')
                                     if p.is_file() and p != out / 'evidence.json' and p.name != 'evidence.tmp'}
            evidence['seconds'] = round(time.monotonic() - started, 1)
            write_evidence(out, evidence)
            if evidence['status'] == 'passed':
                try:
                    verify_evidence(out, evidence['candidateAfter'], evidence['environment'], evidence['config'])
                except InfraError:
                    evidence['status'], evidence['exitCode'] = 'incomplete', 2
                    write_evidence(out, evidence)
                    raise
            if evidence['candidateAfter'] != evidence['candidate']:
                raise InfraError('candidate changed during run')
        except BaseException as final_error:
            evidence.update(status='incomplete', exitCode=2, finalizationError=str(final_error))
            try:
                write_evidence(out, evidence)
            except OSError as write_error:
                print(f'Cannot finalize {out}: {write_error}', file=sys.stderr)
            if original_error is None:
                raise InfraError(f'cannot finalize evidence: {out}: {final_error}') from final_error
        finally:
            try:
                if evidence['status'] != 'passed':
                    (out / 'summary.md').write_text(
                        f"Playback fixture matrix: {evidence['status']}; exit {evidence['exitCode']}\n"
                        f"{evidence.get('error', evidence.get('finalizationError', 'comparison failed'))}\n"
                        f"Evidence: {out / 'evidence.json'}\n")
            except OSError as summary_error:
                print(f'Cannot write summary {out}: {summary_error}', file=sys.stderr)
                if original_error is None:
                    raise
            print(f'evidence: {out / "evidence.json"}', flush=True)


EXTERNAL_REQUIREMENTS = {
    'standalone-diagnostics': 'Linux and Android; seek/codecs/Range, navigation, artist fill, settings, indicators, adjustments/EQ',
    'live-server': 'Linux and Android; disposable account and real server',
    'native-service': 'Android media-service/recovery unit and runtime contracts',
    'os-controls': 'Linux MPRIS, Android Auto/MediaSession; Windows SMTC on Windows host',
    'device-manual': 'Applicable physical lifecycle, audible listening, focus/Bluetooth/routes, real car/phone',
    'apple': 'Apple host/device when applicable; macOS controls remain incomplete',
    'runtime-visual': 'Isolated profile, logs, persistence, clean restart and inspected app-owned screenshots',
}


def full_config(platform, base, flutter):
    return dict(command='ab', scenarios=[], map=False, all=True, platform=platform,
                base=base, base_range=f'{DEFAULT_BASE}...HEAD', full=True, reps=None, real=False,
                names=[n for n in SCENARIOS if platform == 'linux' or n in ANDROID_SCENARIOS],
                baseSha=base, flutter=flutter)


def gate_summary(out, record):
    lines = [f"Fixture gate: {record['status']}; exit {record['exitCode']}",
             'Whole playback acceptance: outstanding (see coverage map; fixture success is insufficient).', '']
    for name, step in record['steps'].items():
        lines.append(f"{name}: {step['status']}; exact command exit={step.get('commandExit')}; "
                     f"gate step exit={step.get('exitCode')}; log={step['log']}")
        lines.append('  command: ' + shlex.join(step['command']))
        if step.get('reused'):
            lines.append('  reused evidence: ' + step['reused'])
        if step.get('error'):
            lines.append('  ' + step['error'])
    if record.get('error'):
        lines.append(record['error'])
    lines += ['', *[f"{name}: outstanding; applicability: {scope}" for name, scope in EXTERNAL_REQUIREMENTS.items()]]
    for name, content in [('gate-summary.md', '\n'.join(lines) + '\n'),
                          ('gate.json', json.dumps(record, indent=1, allow_nan=False))]:
        temporary = out / (name + '.tmp')
        temporary.write_text(content)
        temporary.replace(out / name)


def cmd_gate(args):
    out = PROJECT / 'build' / 'harness' / ('gate-' + datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ'))
    out.mkdir(parents=True)
    record = dict(schema=1, status='blocked', exitCode=2, steps={},
                  external={k: dict(status='outstanding', applicability=v) for k, v in EXTERNAL_REQUIREMENTS.items()},
                  acceptance='outstanding', candidate=candidate_identity(), environment=environment_identity())
    commands = [('check', ['./tool/check.sh'], 7200)]
    for platform in ('linux', 'android'):
        commands.append((platform, [sys.executable, str(PROJECT / 'tool/playback_harness.py'),
            'ab', '--all', '--full', '--platform', platform, '--base', args.base,
            '--output', str(out / platform)], 64800 if platform == 'linux' else 43200))
    for name, command, deadline in commands:
        record['steps'][name] = dict(status='not-run', command=command, commandExit=None,
                                    exitCode=None, log=str(out / (name + '.log')))
    try:
        with heavy_lock(out, CACHE) as descriptors:
            base = git('rev-parse', '--verify', f'{args.base}^{{commit}}')
            flutter = flutter_version()
            record.update(base=base, flutter=flutter)
            for name, command, _ in commands[1:]:
                command[command.index('--base') + 1] = base
            gate_summary(out, record)
            for name, command, deadline in commands:
                if candidate_identity() != record['candidate'] or environment_identity() != record['environment']:
                    raise InfraError('candidate/environment changed; remaining steps not run')
                step = record['steps'][name]
                started = time.monotonic()
                try:
                    reuse = getattr(args, 'reuse_' + name, None) if name != 'check' else None
                    if reuse:
                        verify_evidence(Path(reuse), record['candidate'], record['environment'], full_config(name, base, flutter))
                        step.update(status='passed', exitCode=0, reused=str(reuse))
                        Path(step['log']).write_text(f'Verified exact-state evidence: {reuse}\nNo command executed.\n')
                    else:
                        step['status'] = 'running'
                        gate_summary(out, record)
                        with Path(step['log']).open('w') as log:
                            done = bounded_command(command, timeout=deadline, cwd=PROJECT, stdout=log,
                                                   stderr=subprocess.STDOUT, pass_fds=descriptors)
                        step.update(commandExit=done.returncode, exitCode=done.returncode,
                                    status='passed' if done.returncode == 0 else 'failed')
                        if done.returncode == 0 and name != 'check':
                            verify_evidence(out / name, record['candidate'], record['environment'], full_config(name, base, flutter))
                        if name != 'check' and done.returncode == 2:
                            step['status'] = 'blocked'
                    if step['status'] == 'passed':
                        step['logSha256'] = sha256(Path(step['log']))
                except subprocess.TimeoutExpired as error:
                    step.update(status='blocked', exitCode=124, commandExit=getattr(error, 'command_exit', None), error=str(error))
                except (InfraError, OSError, ValueError) as error:
                    step.update(status='blocked', exitCode=2, error=str(error))
                finally:
                    step['seconds'] = round(time.monotonic() - started, 1)
                    gate_summary(out, record)
            if candidate_identity() != record['candidate']:
                raise InfraError('candidate changed during gate')
            statuses = [s['status'] for s in record['steps'].values()]
            record['status'] = 'passed' if statuses == ['passed'] * 3 else ('failed' if 'failed' in statuses else 'blocked')
            record['exitCode'] = 0 if record['status'] == 'passed' else (1 if record['status'] == 'failed' else 2)
    except (RuntimeError, OSError, subprocess.SubprocessError, KeyboardInterrupt, SystemExit) as error:
        record.update(status='blocked', exitCode=2, error=str(error))
        for step in record['steps'].values():
            if step['status'] == 'running':
                step.update(status='blocked', exitCode=2, error=type(error).__name__)
    finally:
        gate_summary(out, record)
        print(f"Fixture gate: {record['status']}; exit {record['exitCode']}; {out / 'gate-summary.md'}")
        print('Whole playback acceptance: outstanding; see docs/development/playback-validation-coverage.md')
    return record['exitCode']


def cmd_list(_) -> int:
    for name, spec in SCENARIOS.items():
        print(f"{name}: ~{spec['budget'][0]} min quick / ~{spec['budget'][1]} min --full per variant "
              f"({'linux+android' if name in ANDROID_SCENARIOS else 'linux'})\n"
              f"  quick: {spec['quick']} x{spec.get('qreps', 1)}\n  full: {spec['cases']} x{spec['reps']}\n  areas: {', '.join(spec['areas'])}")
    return 0


def cmd_map(args) -> int:
    names, why = map_files(git('diff', '--name-only', args.range).splitlines())
    print(f'{why}: {" ".join(names) or "none"}')
    return 0


def main(argv=None) -> int:
    getattr(sys.stdout, 'reconfigure', lambda **_: None)(line_buffering=True)
    parser = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('list').set_defaults(fn=cmd_list)
    mapper = sub.add_parser('map')
    mapper.add_argument('range', nargs='?', default=f'{DEFAULT_BASE}...HEAD')
    mapper.set_defaults(fn=cmd_map)
    gate = sub.add_parser('gate')
    gate.add_argument('--base', default=DEFAULT_BASE)
    gate.add_argument('--reuse-linux', help='explicit evidence directory; verified before reuse')
    gate.add_argument('--reuse-android', help='explicit evidence directory; verified before reuse')
    gate.set_defaults(fn=cmd_gate)
    ab = sub.add_parser('ab')
    ab.add_argument('--output', help=argparse.SUPPRESS)
    ab.add_argument('scenarios', nargs='*')
    ab.add_argument('--map', action='store_true', help='run the scenarios `map` selects')
    ab.add_argument('--all', action='store_true')
    ab.add_argument('--platform', choices=['linux', 'android'], required=True)
    ab.add_argument('--base', default=DEFAULT_BASE)
    ab.add_argument('--base-range', default=f'{DEFAULT_BASE}...HEAD', help='revision range for --map')
    ab.add_argument('--full', action='store_true', help='every case, 3 reps (calibration, release checks); default is the quick set, 1 rep')
    ab.add_argument('--reps', type=int, help='override the repetitions')
    ab.add_argument('--real', action='store_true', help='drive the real server (mode-600 ~/.config/navis/perf-credentials.json)')
    ab.set_defaults(fn=cmd_ab)
    args = parser.parse_args(argv)
    if args.command in ('ab', 'gate') and 'NAVIS_HARNESS_CAPPED' not in os.environ and shutil.which('systemd-run'):
        # One memory-capped scope for every child (builds, emulator, app): a runaway job dies inside it, not the host.
        os.execvp('systemd-run', ['systemd-run', '--user', '--scope', '-q', '-p', f'MemoryMax={MEMORY_MAX}', '-p', 'MemorySwapMax=3G',
                                  '--setenv=NAVIS_HARNESS_CAPPED=1', sys.executable, *sys.argv])
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))  # unwind: stop the emulator, KWin and the temporary worktree
    try:
        return args.fn(args)
    except (InfraError, RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f'ERROR (infrastructure, not a FAIL): {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
