#!/usr/bin/env python3
"""Fixture certification that a server rescan reaches the library.

Runs the Linux clone build against the `rescan` fixture scenario: a baseline
sync (phase A), then a server that retagged ReplayGain, removed songs and an
album, moved and renamed a song and changed a genre behind a new completed
scan (phase B). Check for updates must run one catalog snapshot, the library
must match the server, and a restart plus a second check must not repeat it.
While phase B syncs, a queue of three songs is playing: song 2's retag must
reach it at the next song, never mid-song (the playback gain check).
Then the automatic entry point (24 h throttle, large-deletion hold) and a
metered network (no scan request, no bulk song request) are checked.

The Subsonic server and the profile are isolated fixtures; no real server,
profile or download folder is read or written. Run it with one heavy job at a
time. Output: build/rescan-snapshot-diagnostics/<stamp>-clone/.
"""

import json
import math
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
# Queue played through the phase B sync: the first song keeps its gain, the
# second is retagged -7.0 to -3.5, the third loses its gain.
PLAY_QUEUE = ["rs-s3", "rs-s1", "rs-s4"]
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
        self.samples = []
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

    def play_sample(self, label):
        """One playback status read: the heard song, its ReplayGain decision
        and the volume the player applies."""
        status = self.get("/v1/playback/status")
        row = {
            "label": label, "songId": status["songId"], "playing": status["playing"],
            "positionMs": status["positionMs"], "replayGain": status["replayGain"],
            "volume": status["effectivePlayerVolume"], "userVolume": status["userVolume"],
        }
        self.samples.append(row)
        print("playback sample:", row, flush=True)
        return row

    def wait_song(self, song_id, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            row = self.play_sample("wait")
            if row["songId"] == song_id and row["playing"] and row["positionMs"] > 500:
                return row
            time.sleep(1)
        raise SystemExit(f"FAILED: {song_id} never played")

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
    sink_module = ""
    display = Display(OUT)  # headless KWin: the clone never opens a window on the desktop
    try:
        run.display_env = display.__enter__()
        # The fixture tone must never reach the desktop's speakers.
        sink = f"navis_rescan_{os.getpid()}"
        sink_module = subprocess.run(
            ["pactl", "load-module", "module-null-sink", f"sink_name={sink}"],
            capture_output=True, text=True, check=True).stdout.strip()
        run.display_env["PULSE_SINK"] = sink
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

        print("== Playback: a queue of three songs starts before the server retags", flush=True)
        # The clone starts with ReplayGain off and the volume at 0.
        run.post("/v1/playback/replay-gain", {"mode": "track", "preamp": 0})
        run.post("/v1/playback/volume", {"value": 1})
        run.post("/v1/playback/queue", {"songIds": PLAY_QUEUE})
        first = run.wait_song(PLAY_QUEUE[0])
        check(first["replayGain"]["db"] == -9.0, f"song 1 plays at its -9.0 dB gain ({first['replayGain']})")
        run.play_sample("before-sync")

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
        # (a) the DB has song 2's new gain; (b) song 1 keeps playing at its level.
        before, after = run.samples[-1], run.play_sample("after-sync")
        time.sleep(4)
        later = run.play_sample("later")
        check(after["songId"] == later["songId"] == before["songId"] == PLAY_QUEUE[0], "song 1 kept playing through the sync")
        check(later["positionMs"] > after["positionMs"] > before["positionMs"], "song 1 position advanced (it was not restarted)")
        check(before["replayGain"] == after["replayGain"] == later["replayGain"], "song 1 ReplayGain decision unchanged by the sync")
        check(before["volume"] == after["volume"] == later["volume"], f"song 1 applied volume unchanged ({before['volume']})")
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

        print("== Playback: the retag is heard from the next song", flush=True)
        # (c) join song 2 naturally, then skip to song 3 (its gain was cleared).
        run.post("/v1/playback/seek", {"positionMs": 87000})  # the fixture songs last 90 s
        run.wait_song(PLAY_QUEUE[1], timeout=30)
        time.sleep(1)
        joined = run.play_sample("joined-song-2")
        check(joined["songId"] == PLAY_QUEUE[1], "the natural join reached song 2")
        check(joined["replayGain"]["db"] == -3.5, f"song 2 uses the new -3.5 dB gain, not -7.0 ({joined['replayGain']})")
        check(math.isclose(joined["volume"], joined["userVolume"] * 10 ** (-3.5 / 60), abs_tol=0.002), f"song 2 volume follows -3.5 dB ({joined['volume']})")
        check(abs(joined["volume"] - joined["userVolume"] * 10 ** (-7.0 / 60)) > 0.004, "song 2 volume is not the stale -7.0 dB level")
        run.post("/v1/playback/next")
        run.wait_song(PLAY_QUEUE[2], timeout=30)
        time.sleep(2)  # the gain fade settles
        skipped = run.play_sample("skipped-song-3")
        # Untagged songs take the Automatic level (the median tagged gain, -8.0 here).
        check(skipped["songId"] == PLAY_QUEUE[2] and skipped["replayGain"]["source"] == "untagged", f"song 3 lost its gain ({skipped['replayGain']})")
        check(math.isclose(skipped["volume"], skipped["userVolume"] * 10 ** (skipped["replayGain"]["db"] / 60), abs_tol=0.002), f"song 3 volume follows its untagged level ({skipped['volume']})")
        run.post("/v1/playback/pause")
        json.dump(run.samples, open(OUT / "playback-samples.json", "w"), indent=1)

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

        def snapshot_row():
            return run.sql("SELECT status, updated_at, not_before FROM library_sync_work WHERE kind='catalogSnapshot'")

        print("== A rescan during collection defers the promotion; the retry after the backoff promotes fresh data", flush=True)

        def snapshot_row_full():
            return run.sql("SELECT status, not_before FROM library_sync_work WHERE kind='catalogSnapshot'")

        reconciled_c = run.sql("SELECT reconciled_token FROM library_scan_observation")[0][0]
        checked_before = run.sql("SELECT last_checked_at, last_catalog_synced_at FROM library_sync_state")[0]
        run.set_phase("D")
        import threading
        flipped = threading.Event()
        mark = run.request_mark()

        def flip_on_first_bulk_request():
            # The server rescans while the snapshot is collecting its songs.
            while not flipped.is_set():
                if bulk_song_requests(run.requests_since(mark)):
                    run.set_phase("E")
                    flipped.set()
                time.sleep(0.05)

        watcher = threading.Thread(target=flip_on_first_bulk_request, daemon=True)
        watcher.start()
        run.post("/v1/sync/check")
        run.idle()
        flipped.set()
        check(run.sql("SELECT replay_gain_track_gain FROM songs WHERE id='rs-s1'")[0][0] == -3.5, "the waiting promotion keeps the previous song data")
        row = snapshot_row_full()[0]
        check(row[0] == "queued" and row[1] is not None and row[1] > time.time(), f"the snapshot stays queued with a backoff {row}")
        check(run.sql("SELECT last_checked_at, last_catalog_synced_at FROM library_sync_state")[0] == checked_before, "a waiting promotion leaves the last-checked clocks alone")
        deferred = [r for r in run.runs() if "napshot" in str(r.get("planKind")) and r["outcome"] == "deferred"]
        check(deferred and deferred[0]["reason"] == "scanChanged", "run history reports the waiting promotion as deferred (scanChanged)")
        check(run.sql("SELECT reconciled_token FROM library_scan_observation")[0][0] == reconciled_c, "no scan was reconciled by the waiting promotion")
        # The backoff passes: the automatic entry point retries and collects again.
        run.exec("UPDATE library_sync_work SET not_before=? WHERE kind='catalogSnapshot'", (int(time.time()) - 60,))
        run.exec("UPDATE library_sync_state SET last_checked_at=?, next_automatic_check_at=NULL", (int(time.time()) - 7200,))
        mark = run.request_mark()
        run.post("/v1/sync/automatic")
        run.idle()
        check(len(bulk_song_requests(run.requests_since(mark))) >= 1, "the retry after the backoff collects the songs again")
        check(run.sql("SELECT replay_gain_track_gain FROM songs WHERE id='rs-s1'")[0][0] == -1.0, "the retry promotes fresh data (the retag that landed during the rescan)")
        obs = run.sql("SELECT observed_token, reconciled_token, pending_reconciliation FROM library_scan_observation")[0]
        check(obs[0] == obs[1] and obs[2] == 0 and obs[0].startswith("2026-11-08T03:00:00"), f"the scan the data was collected under is reconciled {obs}")

        print("== A held large deletion is confirmed even after a new scan", flush=True)
        run.set_phase("F")
        run.post("/v1/sync/check")
        run.idle()
        state = run.sql("SELECT candidate_status FROM library_sync_state")[0][0]
        check(state == "awaitingDeletionConfirmation", f"sixteen vanished albums wait for confirmation ({state})")
        check(run.sql("SELECT COUNT(*) FROM songs WHERE id LIKE 'rs-s20' OR id LIKE 'rs-s30'")[0][0] == 2, "the held removal has not been applied")
        # Nothing but the dialog's confirmation applies the hold: Force rescan
        # (a repair with no confirmation) and an automatic pass collect the
        # same removal set and hold again.
        removed = "SELECT COUNT(*) FROM songs WHERE id LIKE 'rs-s20' OR id LIKE 'rs-s30'"
        run.post("/v1/sync/repair")
        run.idle()
        check(run.sql("SELECT candidate_status FROM library_sync_state")[0][0] == "awaitingDeletionConfirmation", "Force rescan keeps the hold")
        check(run.sql(removed)[0][0] == 2, "Force rescan does not apply the held removal")
        run.post("/v1/sync/automatic")
        run.idle()
        check(run.sql("SELECT candidate_status FROM library_sync_state")[0][0] == "awaitingDeletionConfirmation", "an automatic pass keeps the hold")
        check(run.sql(removed)[0][0] == 2, "an automatic pass does not apply the held removal")
        # A scan completed since the hold (G); the user presses Repair Library,
        # and another scan (H) lands while that confirming run is collecting.
        run.set_phase("G")
        flipped_repair = threading.Event()
        mark = run.request_mark()

        def flip_during_confirm():
            while not flipped_repair.is_set():
                if bulk_song_requests(run.requests_since(mark)):
                    run.set_phase("H")
                    flipped_repair.set()
                time.sleep(0.05)

        threading.Thread(target=flip_during_confirm, daemon=True).start()
        run.post("/v1/sync/repair", {"confirmHeldDeletion": True})
        run.idle()
        flipped_repair.set()
        check(run.sql("SELECT candidate_status FROM library_sync_state")[0][0] == "awaitingDeletionConfirmation", "a scan landing during the confirming press keeps the hold")
        check(run.sql("SELECT COUNT(*) FROM songs WHERE id LIKE 'rs-s20' OR id LIKE 'rs-s30'")[0][0] == 2, "the unconfirmed removal has not been applied")
        repairs = [r for r in run.runs() if r["intent"] == "repairLibrary" and r["outcome"] == "deferred"]
        check(repairs and repairs[-1]["reason"] == "scanChanged", f"the confirming press that waited is reported as deferred {repairs[-1:]}")
        # The server is quiet at H: the next dialog confirmation applies it.
        run.post("/v1/sync/repair", {"confirmHeldDeletion": True})
        run.idle()
        check(run.sql("SELECT candidate_status FROM library_sync_state")[0][0] is None, "the retry after the scan applies the removal without a second hold")
        check(run.sql("SELECT COUNT(*) FROM songs WHERE id LIKE 'rs-s20' OR id LIKE 'rs-s30'")[0][0] == 0, "the removed albums' songs are gone")
        obs = run.sql("SELECT observed_token, reconciled_token FROM library_scan_observation")[0]
        check(obs[0] == obs[1] and obs[0].startswith("2026-11-08T06:00:00"), f"the confirming pass reconciles the new scan {obs}")
        # Back to a quiet, reconciled state for the phases below.
        run.set_phase("B")

        print("== Awaiting deletion confirmation: no new snapshot", flush=True)
        run.exec("UPDATE library_scan_observation SET pending_reconciliation=1, reconciled_token='stale-token'")
        run.exec("UPDATE library_sync_state SET candidate_status='awaitingDeletionConfirmation', candidate_generation=99, last_checked_at=?", (stale,))
        run.exec("UPDATE library_sync_work SET updated_at=? WHERE kind='catalogSnapshot'", (int(time.time()) - 48 * 3600,))
        held_row = snapshot_row()
        held_runs = len(snapshot_runs(run.runs()))
        mark = run.request_mark()
        run.post("/v1/sync/check")
        run.idle()
        rows = run.requests_since(mark)
        print("held manual requests:", [r["endpoint"] for r in rows], flush=True)
        check(snapshot_row() == held_row, "the held phase leaves the snapshot work row untouched")
        check(len(snapshot_runs(run.runs())) == held_runs, "the held phase adds no snapshot run")
        check(not bulk_song_requests(rows), "a held large-deletion candidate is not re-collected")
        check(not any(r["endpoint"] == "getScanStatus" for r in rows), "no scan pre-observation while held")

        print("== Metered with unmetered-only off: no scan request, no bulk request", flush=True)
        run.exec("UPDATE library_sync_state SET candidate_status=NULL, candidate_generation=NULL")
        run.exec("UPDATE library_scan_observation SET pending_reconciliation=1, reconciled_token='stale-token'")
        run.exec("UPDATE library_sync_work SET updated_at=? WHERE kind='catalogSnapshot'", (int(time.time()) - 48 * 3600,))
        run.post("/v1/diagnostics/overrides", {
            "networkType": "cellular", "nativeMetered": True,
            "backgroundSyncUnmeteredOnly": False, "requestReporting": True,
        })
        metered_row = snapshot_row()
        mark = run.request_mark()
        run.post("/v1/sync/check")
        run.idle()
        rows = run.requests_since(mark)
        print("metered requests:", [r["endpoint"] for r in rows], flush=True)
        check(not any(r["endpoint"] == "getScanStatus" for r in rows), "metered check made no getScanStatus request")
        check(not bulk_song_requests(rows), "metered check made no bulk song request")
        check(snapshot_row() == metered_row, "the metered phase leaves the snapshot work row untouched")

        print("== A queued scan snapshot never resumes on metered data without the grant", flush=True)
        # What an interrupted Wi-Fi pass leaves behind: a queued row that
        # carries the scan token. Interrupting a real pass is timing-dependent,
        # so seed that exact state.
        run.exec("UPDATE library_sync_work SET status='queued', not_before=NULL, updated_at=?, "
                 "checkpoint_json='{\"intent\":null,\"evidenceVersion\":\"2026-11-07T18:00:00.000Z\"}' "
                 "WHERE kind='catalogSnapshot'", (int(time.time()) - 600,))
        run.exec("UPDATE library_scan_observation SET pending_reconciliation=1, reconciled_token='stale-token'")
        for label, route in (("manual", "/v1/sync/check"), ("automatic", "/v1/sync/automatic")):
            run.exec("UPDATE library_sync_state SET last_checked_at=?, next_automatic_check_at=NULL", (stale,))
            mark = run.request_mark()
            run.post(route)
            run.idle()
            rows = run.requests_since(mark)
            check(not bulk_song_requests(rows), f"a queued scan snapshot on metered data makes no bulk request ({label})")
            check(snapshot_row()[0][0] == "queued", f"the queued scan snapshot stays queued ({label})")
        mark = run.request_mark()
        run.post("/v1/sync/check", {"allowMeteredBroadOverride": True})
        run.idle()
        rows = run.requests_since(mark)
        check(len(bulk_song_requests(rows)) >= 1, "with the one-time broad grant the queued snapshot runs on metered data")
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
        if sink_module:
            subprocess.run(["pactl", "unload-module", sink_module], check=False)
        display.__exit__()


if __name__ == "__main__":
    sys.exit(main())
