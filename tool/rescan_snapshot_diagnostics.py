#!/usr/bin/env python3
"""Fixture certification that a server rescan reaches the library.

Runs the Linux clone build against the `rescan` fixture scenario: a baseline
sync (phase A), then a server that retagged ReplayGain, removed songs and an
album, moved and renamed a song and changed a genre behind a new completed
scan (phase B). Check for updates must run one catalog snapshot, the library
must match the server, and a restart plus a second check must not repeat it.
Then the automatic entry point (24 h throttle, large-deletion hold) and a
metered network (no scan request, no bulk song request) are checked.

The Subsonic server and the profile are isolated fixtures; no real server,
profile or download folder is read or written. Run it with one heavy job at a
time. Output: build/rescan-snapshot-diagnostics/<stamp>-clone/.
"""

import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from types import SimpleNamespace
from urllib import request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dev_sync_scenario import (  # noqa: E402
    _api,
    _clone_diagnostic_defines,
    _stop,
    _wait_for_json,
    prepare_database,
    prepare_support_directory,
)
from diagnostics_profile import primary_database  # noqa: E402
from playback_harness import Display  # noqa: E402

PROJECT_ROOT = Path(__file__).resolve().parent.parent
STAMP = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
OUT = PROJECT_ROOT / "build" / "rescan-snapshot-diagnostics" / f"{STAMP}-clone"
SCAN = {"A": "2026-11-07T04:00:00.000Z", "B": "2026-11-07T12:00:00.000Z", "C": "2026-11-07T18:00:00.000Z"}


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAILED: {message}")
    print(f"ok: {message}", flush=True)


class Run:
    def __init__(self):
        OUT.mkdir(parents=True, mode=0o700)
        self.db = OUT / "navis-diagnostics.sqlite"
        self.phase_file = OUT / "phase"
        self.request_log = OUT / "requests.jsonl"
        self.handshake_path = OUT / "handshake.json"
        self.flutter = None
        self.display_env = {}
        self.handshake = None
        self.app_log = None
        self.set_phase("A")

    def start_fixture(self):
        self.fixture_log = (OUT / "fixture.log").open("wb")
        self.fixture = subprocess.Popen(
            [
                sys.executable,
                str(PROJECT_ROOT / "tool" / "auth_lifecycle_fixture_server.py"),
                "--handshake", str(OUT / "fixture-handshake.json"),
                "--failure-flag", str(OUT / "unused-failure-flag"),
                "--scenario", "rescan",
                "--phase-file", str(self.phase_file),
                "--request-log", str(self.request_log),
            ],
            cwd=PROJECT_ROOT, stdout=self.fixture_log, stderr=subprocess.STDOUT,
        )
        info = _wait_for_json(OUT / "fixture-handshake.json", self.fixture, 30)
        self.fixture_url = f"http://127.0.0.1:{info['port']}"
        credential = OUT / "fixture-credential"
        credential.write_text("navis-rescan-fixture\n", encoding="utf-8")
        os.chmod(credential, 0o600)

    def prepare_profile(self):
        prepare_support_directory(OUT, "first-setup")
        prepare_database(primary_database(), self.db, "first-setup", fixture_url=self.fixture_url)

    def set_phase(self, phase):
        self.phase_file.write_text(phase + "\n", encoding="utf-8")

    def launch(self, label):
        options = SimpleNamespace(scenario="first-setup", offline=False, metered=False)
        defines = _clone_diagnostic_defines(
            options, root=OUT, database=self.db, handshake_path=self.handshake_path,
            fixture_credential=OUT / "fixture-credential",
        )
        check(defines.get("NAVIS_SYNC_DIAGNOSTICS_MODE") == "clone", "launch defines select clone mode")
        self.handshake_path.unlink(missing_ok=True)
        command = ["flutter", "run", "-d", "linux", "--profile"]
        command += [f"--dart-define={key}={value}" for key, value in defines.items()]
        self.app_log = (OUT / f"{label}-navis.log").open("wb")
        self.flutter = subprocess.Popen(
            command, cwd=PROJECT_ROOT, stdout=self.app_log, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            env={k: v for k, v in os.environ.items() if k != 'DISPLAY'} | self.display_env,
        )
        self.handshake = _wait_for_json(self.handshake_path, self.flutter, 900)
        health = self.get("/v1/health")
        check(health.get("mode") == "clone", f"{label}: diagnostics report clone mode")
        # A headless session reports an unknown transport; pin unmetered Wi-Fi.
        self.post("/v1/diagnostics/overrides", {"networkType": "wifi", "nativeMetered": False})

    def get(self, route):
        call = request.Request(
            f"http://127.0.0.1:{self.handshake['port']}{route}",
            headers={"Authorization": f"Bearer {self.handshake['token']}"},
        )
        with request.urlopen(call, timeout=60) as response:
            return json.load(response)

    def post(self, route, body=None):
        return _api(self.handshake, route, body or {})

    def idle(self, timeout=240):
        deadline = time.monotonic() + timeout
        time.sleep(1)
        while time.monotonic() < deadline:
            status = self.get("/v1/sync/status")
            if not status.get("requestActive"):
                return status
            time.sleep(1)
        raise SystemExit("FAILED: sync did not settle")

    def stop_app(self):
        if self.flutter is not None and self.flutter.poll() is None:
            try:
                self.post("/v1/shutdown")
                self.flutter.wait(timeout=30)
            except Exception:
                _stop(self.flutter)
        self.flutter = None

    def requests_since(self, mark):
        rows = [json.loads(line) for line in self.request_log.read_text().splitlines()]
        return rows[mark:]

    def request_mark(self):
        return len(self.request_log.read_text().splitlines()) if self.request_log.exists() else 0

    def sql(self, query, args=()):
        with sqlite3.connect(f"file:{self.db}?mode=ro", uri=True) as db:
            return db.execute(query, args).fetchall()

    def exec(self, query, args=()):
        with sqlite3.connect(self.db) as db:
            db.execute(query, args)

    def runs(self):
        return [r for r in self.get("/v1/sync/ledger")["durableRuns"] if r["targetKind"] == "catalog"]

    def screenshot(self, label):
        shot = self.post("/v1/presentation/screenshot", {"label": label})
        print(f"screenshot {label}: {OUT / shot['artifact']}", flush=True)
        return shot


def bulk_song_requests(rows):
    # Sync pages the whole library with an empty query (parse_qs drops it);
    # UI search always sends a query text.
    return [r for r in rows if r["endpoint"] == "search3" and "songOffset" in r["query"] and "query" not in r["query"]]


def snapshot_runs(runs):
    return [r for r in runs if "napshot" in str(r.get("planKind"))]


def main():
    run = Run()
    display = Display(OUT)  # headless KWin: the clone never opens a window on the desktop
    try:
        run.display_env = display.__enter__()
        run.start_fixture()
        run.prepare_profile()

        print("== Phase A: first setup builds the baseline", flush=True)
        run.launch("a")
        status = run.idle()
        for _ in range(60):
            if run.sql("SELECT COUNT(*) FROM songs")[0][0] >= 102:
                break
            time.sleep(1)
        songs = run.sql("SELECT COUNT(*) FROM songs")[0][0]
        check(songs == 102, f"baseline holds 102 songs (got {songs})")
        run.idle()
        obs = run.sql("SELECT observed_token, reconciled_token, pending_reconciliation FROM library_scan_observation")
        print("baseline observation:", obs, flush=True)
        check(len(obs) == 1 and obs[0][0] == obs[0][1] and obs[0][2] == 0, "baseline scan token is reconciled")
        check(run.sql("SELECT replay_gain_track_gain FROM songs WHERE id='rs-s1'")[0][0] == -7.0, "baseline rs-s1 gain -7.0")
        run.post("/v1/presentation/onboarding/complete")
        run.post("/v1/presentation/navigate", {"location": "/library"})
        time.sleep(3)
        run.screenshot("baseline-library")

        print("== Phase B: server retag + removals + new scan, then Check for updates", flush=True)
        run.set_phase("B")
        mark = run.request_mark()
        run.post("/v1/sync/check")
        status = run.idle()
        rows = run.requests_since(mark)
        print("check status:", {k: status.get(k) for k in ("status", "planKind", "planReason", "outcome")}, flush=True)
        check(rows[0]["endpoint"] == "getScanStatus", "the check observes the scan first")
        check(len(bulk_song_requests(rows)) >= 1, "the check ran the bulk song pass")
        runs = run.runs()
        snap = snapshot_runs(runs)
        print("catalog runs:", [(r["planKind"], r["outcome"], r.get("reason")) for r in runs][-4:], flush=True)
        check(len(snap) >= 1 and snap[-1]["outcome"] in ("completed", "noChanges"), "durable history shows a completed catalog snapshot")
        check(snap[-1]["intent"] == "manualCatalogCheck", "the snapshot keeps manual intent")
        gain = run.sql("SELECT id, replay_gain_track_gain FROM songs WHERE id IN ('rs-s1','rs-s4') ORDER BY id")
        check(gain == [("rs-s1", -3.5), ("rs-s4", None)], f"ReplayGain retag landed {gain}")
        check(run.sql("SELECT COUNT(*) FROM songs WHERE id IN ('rs-s5','rs-s7')")[0][0] == 0, "removed songs are gone")
        check(run.sql("SELECT COUNT(*) FROM albums WHERE id='rs-a7'")[0][0] == 0, "removed album is gone")
        check(run.sql("SELECT album_id FROM songs WHERE id='rs-s2'")[0][0] == "rs-a3", "moved song follows its album")
        check(run.sql("SELECT title FROM songs WHERE id='rs-s8'")[0][0] == "Renamed", "title edit landed")
        check("Jazz" in run.sql("SELECT genres FROM songs WHERE id='rs-s9'")[0][0], "genre change landed")
        obs = run.sql("SELECT observed_token, reconciled_token, pending_reconciliation FROM library_scan_observation")[0]
        check(obs[1] == obs[0] and obs[2] == 0 and obs[0] != SCAN["A"] and obs[0].startswith("2026-11-07T12:00:00"), f"scan reconciled {obs}")
        run.post("/v1/presentation/navigate", {"location": "/library"})
        time.sleep(3)
        run.screenshot("after-snapshot-library")
        run.post("/v1/presentation/navigate", {"location": "/settings/sync"})
        time.sleep(3)
        run.screenshot("after-snapshot-sync-settings")

        print("== Clean restart: state persists, the next check is not a snapshot", flush=True)
        run.stop_app()
        run.launch("b-restart")
        run.idle()
        check(run.sql("SELECT replay_gain_track_gain FROM songs WHERE id='rs-s1'")[0][0] == -3.5, "retag persisted across restart")
        before = len(snapshot_runs(run.runs()))
        mark = run.request_mark()
        run.post("/v1/sync/check")
        run.idle()
        rows = run.requests_since(mark)
        check(len(snapshot_runs(run.runs())) == before, "second check did not run another snapshot")
        check(not bulk_song_requests(rows), "second check made no bulk song request")

        print("== Automatic pass: 24 h throttle", flush=True)
        run.set_phase("C")  # another completed scan, no content change
        run.stop_app()
        stale = int(time.time()) - 7200

        def age_snapshot(hours):
            # The startup pass has already settled; make the entry point due
            # again and age the last snapshot attempt.
            run.exec("UPDATE library_sync_state SET last_checked_at=?, next_automatic_check_at=NULL", (stale,))
            run.exec("UPDATE library_sync_work SET updated_at=? WHERE kind='catalogSnapshot'", (int(time.time()) - int(hours * 3600),))

        run.launch("auto-fresh")
        run.idle()
        age_snapshot(2)
        mark = run.request_mark()
        run.post("/v1/sync/automatic")
        run.idle()
        rows = run.requests_since(mark)
        print("fresh automatic requests:", [r["endpoint"] for r in rows], flush=True)
        check(rows, "the automatic pass ran (it was due)")
        check(not bulk_song_requests(rows), "automatic pass 2 h after the last snapshot makes no bulk request")
        check(not any(r["endpoint"] == "getScanStatus" for r in rows), "the throttled automatic pass spends no scan request")
        age_snapshot(25)
        mark = run.request_mark()
        run.post("/v1/sync/automatic")
        run.idle()
        rows = run.requests_since(mark)
        print("aged automatic requests:", [r["endpoint"] for r in rows], flush=True)
        check(len(bulk_song_requests(rows)) >= 1, "automatic pass 25 h after the last snapshot runs the bulk pass")
        auto = [r for r in snapshot_runs(run.runs()) if r["intent"] == "automaticCatalogCheck"]
        check(len(auto) >= 1, "the automatic snapshot is recorded as automatic")

        print("== Awaiting deletion confirmation: no new snapshot", flush=True)
        run.exec("UPDATE library_scan_observation SET pending_reconciliation=1, reconciled_token='stale-token'")
        run.exec("UPDATE library_sync_state SET candidate_status='awaitingDeletionConfirmation', candidate_generation=99, last_checked_at=?", (stale,))
        run.exec("UPDATE library_sync_work SET updated_at=? WHERE kind='catalogSnapshot'", (int(time.time()) - 48 * 3600,))
        mark = run.request_mark()
        run.post("/v1/sync/check")
        run.idle()
        rows = run.requests_since(mark)
        print("held manual requests:", [r["endpoint"] for r in rows], flush=True)
        check(not bulk_song_requests(rows), "a held large-deletion candidate is not re-collected")
        check(not rows or rows[0]["endpoint"] != "getScanStatus", "no scan pre-observation while held")

        print("== Metered with unmetered-only off: no scan request, no bulk request", flush=True)
        run.exec("UPDATE library_sync_state SET candidate_status=NULL, candidate_generation=NULL")
        run.exec("UPDATE library_scan_observation SET pending_reconciliation=1, reconciled_token='stale-token'")
        run.exec("UPDATE library_sync_work SET updated_at=? WHERE kind='catalogSnapshot'", (int(time.time()) - 48 * 3600,))
        run.post("/v1/diagnostics/overrides", {
            "networkType": "cellular", "nativeMetered": True,
            "backgroundSyncUnmeteredOnly": False, "requestReporting": True,
        })
        mark = run.request_mark()
        run.post("/v1/sync/check")
        run.idle()
        rows = run.requests_since(mark)
        print("metered requests:", [r["endpoint"] for r in rows], flush=True)
        check(not any(r["endpoint"] == "getScanStatus" for r in rows), "metered check made no getScanStatus request")
        check(not bulk_song_requests(rows), "metered check made no bulk song request")
        run.stop_app()

        text = (OUT / "auto-fresh-navis.log").read_text(errors="replace")
        for pattern in ("Unhandled Exception", "Tried to modify a provider while the widget tree was building", "created the database class NavisDatabase multiple times"):
            check(pattern not in text, f"runtime log has no '{pattern}'")
        json.dump({"status": "passed", "scenario": "rescan", "output": str(OUT)}, open(OUT / "runtime-validation.json", "w"))
        print(f"Rescan diagnostics passed: {OUT}")
        return 0
    finally:
        run.stop_app()
        _stop(getattr(run, "fixture", None))
        display.__exit__()


if __name__ == "__main__":
    sys.exit(main())
