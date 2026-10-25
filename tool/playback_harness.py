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
import fcntl
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time
from contextlib import ExitStack
from datetime import datetime, timezone
from pathlib import Path

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
# Checks: (metric, '<=', limit) absolute on the fix | (metric, 'base+', add) fix <= base + add |
# (metric, 'base*', factor, add) | (metric, 'nonew') fix has no violation kind the base lacks |
# (metric, 'stall') fix max <= 50 or not worse than base | (metric, 'true') | (metric, 'nonempty').

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
        checks=[('slopeMiBPerDrag', 'base*', 1.25, 1.5), ('postGcPssMiB', 'base+', 32), ('postGcHeapMiB', 'base+', 8)]),
    'repeat': dict(
        cases='offset_repeat_one,base_repeat_one,repeat_one_fill,chain_end,chain_end_all,repeat_switch_off,hold_off,hold_all,'
              'q7_append_200',
        quick='offset_repeat_one,repeat_one_fill,chain_end,q7_append_200',
        qualities='opus128', throttle='wan6000', reps=3, budget=(8, 60), args=[],
        areas=HANDLER + CROSSFADE + QUEUE + ['lib/src/features/player/data/navis_playback_rules.dart',
                                             '**/ProgressiveRepeat.java', '**/AudioPlayer.java'],
        checks=[('kinds', 'nonew'), ('violations', 'base+', 3), ('frozenMedianS', 'base+', 0.1)]),
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
ANDROID_SCENARIOS = ('stress-drag', 'memory-soak', 'repeat', 'queue-edit')
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
            out.update(slopeMiBPerDrag=_med(_ols_slope([d['pssKiB'] / mib for d in soak['drags']]) for soak in soaks),
                       postGcPssMiB=_med(soak['afterGc']['pssKiB'] / mib for soak in soaks),
                       postGcHeapMiB=_med(soak['afterGc']['heapB'] / mib / mib for soak in soaks))
    elif scenario == 'cut-recovery':
        out['recoveryMedianS'] = _med((r['metrics'].get('cutVerdict') or {}).get('resumedAfterS') or r['metrics'].get('maxFrozenS')
                                      for r in rows)
        out['progressLoss'] = hard.count('progressLoss')
    elif scenario == 'local-seek':
        errors = [e for r in rows for e in (r['metrics'].get('localSeek') or {}).get('errorsMs', [])]
        out['landingErrorMaxMs'] = max(errors) if errors else None
    return out


def _fmt(value) -> str:
    if isinstance(value, float):
        return f'{value:.3f}'.rstrip('0').rstrip('.')
    return json.dumps(value) if isinstance(value, (list, dict)) else str(value)


# A software-rendered guest janks in bursts (A/A: >50 ms counts of 1 vs 46, maxima 149 vs 188 ms), so Android's stall rule is wide.
ANDROID_STALL = (3, 100)


def evaluate(scenario: str, base: dict, fix: dict, platform: str = 'linux') -> list[tuple[bool, str]]:
    """PASS/FAIL lines of one scenario from the metrics of its base and fix variants."""
    lines = []
    for check in [('caseErrors', 'clean')] + SCENARIOS[scenario]['checks']:
        name, kind, *args = check
        f, b = fix.get(name), base.get(name)
        if kind == 'clean':  # a harness or app error in a cell is never a zero
            ok, limit = f == 0 and b == 0, 'no case/oracle error or app exit in either run'
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
        elif kind == 'base*':
            ok, limit = f <= b * args[0] + args[1], f'<= base * {_fmt(args[0])} + {_fmt(args[1])}'
        elif kind == 'stall':
            factor, slack = ANDROID_STALL if platform == 'android' else (1, 0)
            ok = f['max'] <= 50 or (f['max'] <= b['max'] * factor + slack and f['over50'] <= b['over50'] * factor + slack)
            limit = f'max <= 50 ms or (max and >50 ms count <= base * {_fmt(factor)} + {_fmt(slack)})'
        else:
            raise ValueError(check)
        lines.append((ok, f"{'PASS' if ok else 'FAIL'} {scenario} {name}: fix={_fmt(f)} base={_fmt(b)} limit={limit}"))
    return lines


# Environment -----------------------------------------------------------------------------------------------

def run(cmd, **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, text=True, capture_output=True, **kwargs)


def git(*args, cwd=PROJECT) -> str:
    done = run(['git', *args], cwd=cwd)
    if done.returncode:
        raise InfraError(f'git {" ".join(args)}: {done.stderr.strip()}')
    return done.stdout.strip()


def sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def downloads_snapshot() -> dict:
    if not DOWNLOADS.exists():
        return {}
    return {str(p.relative_to(DOWNLOADS)): [p.stat().st_size, sha256(p)] for p in sorted(DOWNLOADS.rglob('*')) if p.is_file()}


def flutter_version() -> str:
    done = run(['flutter', '--version'])
    if done.returncode:
        raise InfraError(f'flutter --version failed: {done.stderr.strip()}')
    return done.stdout.splitlines()[0]


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
    with log.open('w') as out:
        done = subprocess.run([sys.executable, str(tree / 'tool' / 'live_seek_stress.py'), '--profile', 'full', '--server', 'fixture',
                               '--build-only', *android], cwd=tree, env=env, stdout=out, stderr=subprocess.STDOUT)
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
        done = run(['tool/bootstrap.sh'], cwd=tree)
        if done.returncode:
            raise InfraError(f'bootstrap of the base worktree failed: {done.stderr.strip()[-400:]}')
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


def stop_group(proc):
    if proc is None or proc.poll() is not None:
        return
    for sig, wait in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
        try:
            os.killpg(proc.pid, sig)
            proc.wait(wait)
            return
        except (ProcessLookupError, subprocess.TimeoutExpired):
            continue


class Emulator:
    """A disposable Android guest (3072 MiB, 2 cores, swiftshader), cloned from an installed AVD and removed on exit."""

    def __init__(self, out: Path):
        self.out, self.proc = out, None
        self.name = f'Navis_Harness_{os.getpid()}'
        self.home = Path.home() / '.android' / 'avd'

    def check(self):
        source = self.home / f'{SOURCE_AVD}.avd' / 'config.ini'
        if not source.exists():
            raise InfraError(f'AVD {SOURCE_AVD!r} not found under {self.home} (set NAVIS_HARNESS_AVD)')
        for tool in (ANDROID_HOME / 'emulator' / 'emulator', ANDROID_HOME / 'platform-tools' / 'adb'):
            if not tool.exists():
                raise InfraError(f'{tool} not found (set ANDROID_HOME)')

    def __enter__(self) -> str:
        self.check()
        values = dict(line.split('=', 1) for line in (self.home / f'{SOURCE_AVD}.avd' / 'config.ini').read_text().splitlines() if '=' in line)
        values.update({'AvdId': self.name, 'avd.ini.displayname': self.name, 'disk.dataPartition.size': '4G',
                       'hw.ramSize': str(GUEST_MIB), 'hw.cpu.ncore': '2', 'PlayStore.enabled': 'false', 'hw.keyboard': 'yes'})
        folder = self.home / f'{self.name}.avd'
        folder.mkdir()
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
            if run(self.adb + ['shell', 'getprop', 'sys.boot_completed']).stdout.strip() == '1':
                break
            time.sleep(2)
        else:
            raise InfraError('emulator boot timed out')
        for setting in (['settings', 'put', 'system', 'screen_off_timeout', '2147483647'], ['svc', 'power', 'stayon', 'true']):
            run(self.adb + ['shell', *setting])
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
                except subprocess.TimeoutExpired:
                    pass  # a hung adb must not keep the guest or its AVD alive
                stop_group(self.proc)
        finally:
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
        return subprocess.run([sys.executable, str(PROJECT / 'tool' / 'live_seek_stress.py'), '--profile', 'full', '--server', 'fixture',
                               '--skip-build', '--proxy-chunked', '--transcode-speed', '3', '--label', label, *args],
                              cwd=PROJECT, env=full, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)


def plan(name: str, full: bool, reps: int | None) -> tuple[str, int, int]:
    """(cases, reps, budget minutes) of a scenario in the quick or full set."""
    spec = SCENARIOS[name]
    return (spec['cases'], reps or spec['reps'], spec['budget'][1]) if full else (spec['quick'], reps or spec.get('qreps', 1), spec['budget'][0])


def run_scenario(name: str, platform: str, variant_dir: Path, display_env: dict, serial: str | None, apk: Path | None,
                 full: bool, reps: int | None, real: bool) -> tuple[list[dict], float]:
    spec = SCENARIOS[name]
    cases, reps, budget = plan(name, full, reps)
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
    try:
        done = engine(args, env, variant_dir, extra, timeout=budget * 60 * 4 + 600, label=name)
    except subprocess.TimeoutExpired:
        raise InfraError(f'engine for {name} exceeded four times its {budget} min budget')
    seconds = round(time.monotonic() - started, 1)
    reports = sorted((variant_dir / 'runs').glob(f'*-{name}/report.json'))
    if done.returncode not in (0, 1) or not reports:
        raise InfraError(f'engine for {name} failed with exit {done.returncode} (log: {variant_dir / (name + ".log")})')
    rows = json.loads(reports[-1].read_text())['results']
    expected = len(cases.split(',')) * reps
    if len(rows) != expected:
        raise InfraError(f'{name}: {len(rows)} of {expected} cells finished (log: {variant_dir / (name + ".log")})')
    return rows, seconds


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


def cmd_ab(args) -> int:
    names = pick_scenarios(args)
    platform = args.platform
    if args.map and not names:
        print('RESULT NONE: no playback code changed')
        return 0
    if platform == 'android':
        skipped = [n for n in names if n not in ANDROID_SCENARIOS]
        if skipped and not (args.map or args.all):
            raise InfraError(f'not available on Android: {skipped} (Android runs {list(ANDROID_SCENARIOS)})')
        kept = [n for n in names if n in ANDROID_SCENARIOS]
        if not kept and args.map:
            # Only Linux-only scenarios were mapped: player code changed, so run every Android scenario.
            print(f'map: {names} are Linux-only; running all Android scenarios')
            kept = list(ANDROID_SCENARIOS)
        names = kept
    if not names:
        raise InfraError('no scenario left to run on this platform')
    CACHE.mkdir(parents=True, exist_ok=True)
    lock = (CACHE / 'lock').open('w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise InfraError('another heavy job holds ~/.cache/navis-harness/lock')
    base_ref = args.base
    base_sha = git('rev-parse', '--verify', f'{base_ref}^{{commit}}')
    if run(['git', 'cat-file', '-e', f'{base_sha}:tool/playback_harness.py'], cwd=PROJECT).returncode:
        raise InfraError(f'base {base_ref} ({base_sha[:12]}) predates this harness: use a commit at or after its merge')
    if platform == 'android':
        Emulator(Path('.')).check()
    dirty = bool(git('status', '--porcelain', '--untracked-files=no'))
    fix_sha = git('rev-parse', 'HEAD')
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    out = PROJECT / 'build' / 'harness' / stamp
    out.mkdir(parents=True)
    flutter = flutter_version()
    before = downloads_snapshot()
    (out / 'downloads-before.json').write_text(json.dumps(before))
    t0 = time.monotonic()
    base_dir, cache_note = base_build(base_sha, platform, flutter, out)
    print(f'base {base_ref} {base_sha[:12]}: {cache_note} ({round(time.monotonic() - t0, 1)} s)')
    t1 = time.monotonic()
    fix_dir = fix_build(platform, out)
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
                        activate(folder, platform, seed)
                        try:
                            rows, seconds = run_scenario(name, platform, out / variant / name, display_env, serial, apk,
                                                         args.full, args.reps, args.real)
                        except InfraError:
                            retry = emulator is not None and attempt == 1 and emulator.proc.poll() is not None
                            if not retry:
                                raise
                    if retry:
                        print(f'{variant} {name}: the emulator died, repeating once', flush=True)
                        continue
                    break
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
    result = f"RESULT {'PASS' if ok else 'FAIL'}"
    (out / 'comparison.json').write_text(json.dumps({'base': base_sha, 'fix': fix_sha, 'platform': platform, 'scenarios': comparison}, indent=1))
    (out / 'summary.md').write_text('\n'.join([f'# Playback harness {stamp} ({platform})', '', f'base {base_ref} {base_sha}', f'fix {fix_sha}', '',
                                               *[f'    {line}' for line in lines], '', result, '']))
    print('\n'.join(lines + [result, f'summary: {out / "summary.md"}']))
    return 0 if ok else 1


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
    ab = sub.add_parser('ab')
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
    if args.command == 'ab' and 'NAVIS_HARNESS_CAPPED' not in os.environ and shutil.which('systemd-run'):
        # One memory-capped scope for every child (builds, emulator, app): a runaway job dies inside it, not the host.
        os.execvp('systemd-run', ['systemd-run', '--user', '--scope', '-q', '-p', f'MemoryMax={MEMORY_MAX}', '-p', 'MemorySwapMax=3G',
                                  '--setenv=NAVIS_HARNESS_CAPPED=1', sys.executable, *sys.argv])
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))  # unwind: stop the emulator, KWin and the temporary worktree
    try:
        return args.fn(args)
    except InfraError as error:
        print(f'ERROR (infrastructure, not a FAIL): {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
