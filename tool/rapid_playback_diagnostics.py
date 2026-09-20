#!/usr/bin/env python3
"""Stress the production playback handler in an isolated Linux profile."""

import concurrent.futures
import json
import os
import sqlite3
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path(os.environ.get("NAVIS_DIAGNOSTICS_PRIMARY_DB", "~/Documents/navis.sqlite.sqlite")).expanduser()
OUTPUT = ROOT / "build" / "rapid-playback" / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
HANDSHAKE = OUTPUT / "handshake.json"
DATABASE = OUTPUT / "navis-diagnostics.sqlite"
LOG = OUTPUT / "navis.log"


def prepare_clone():
    if not SOURCE.is_file():
        raise RuntimeError("The source database was not found")
    OUTPUT.mkdir(parents=True, mode=0o700)
    OUTPUT.chmod(0o700)
    source = sqlite3.connect(f"file:{SOURCE}?mode=ro", uri=True)
    clone = sqlite3.connect(DATABASE)
    source.backup(clone)
    source.close()
    cache_root = OUTPUT / "cache"
    cache_root.mkdir(mode=0o700)
    # The clone must not read or remove user-owned cache files.
    clone.execute("UPDATE cached_tracks SET file_path = ? || '/' || song_id", (str(cache_root),))
    username = os.environ.get("NAVIS_DIAGNOSTICS_USERNAME", "").strip()
    if username:
        clone.execute("UPDATE server_config SET username = ?", (username,))
    queue_length = int(os.environ.get("NAVIS_RAPID_QUEUE_LENGTH", "20"))
    if queue_length < 2 or queue_length > 500:
        raise RuntimeError("Queue length must be between 2 and 500")
    rows = clone.execute(
        "SELECT id FROM songs WHERE server_deleted_at IS NULL AND is_provisional = 0 "
        "ORDER BY id LIMIT ?", (queue_length,)
    ).fetchall()
    clone.commit()
    clone.close()
    DATABASE.chmod(0o600)
    if len(rows) < queue_length:
        raise RuntimeError("The clone does not have enough available songs")
    return [row[0] for row in rows]


class App:
    def __init__(self, log_file):
        self.log_file = log_file
        self.process = None
        self.port = None
        self.token = None

    def start(self):
        HANDSHAKE.unlink(missing_ok=True)
        args = [
            "flutter", "run", "-d", "linux", "--profile",
            "--dart-define=NAVIS_UPDATE_CHANNEL=dev",
            "--dart-define=NAVIS_APP_ID_SUFFIX=.dev",
            "--dart-define=NAVIS_APP_NAME=Navis Rapid Playback Diagnostics",
            "--dart-define=NAVIS_SYNC_DIAGNOSTICS=true",
            "--dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone",
            f"--dart-define=NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE={HANDSHAKE}",
            f"--dart-define=NAVIS_SYNC_DIAGNOSTICS_ROOT={OUTPUT}",
            f"--dart-define=NAVIS_SYNC_DIAGNOSTICS_DB_PATH={DATABASE}",
        ]
        credential = os.environ.get("NAVIS_DIAGNOSTICS_CREDENTIAL_PATH", "")
        if credential:
            file = Path(credential)
            if not file.is_file() or file.is_symlink() or file.stat().st_mode & 0o077:
                raise RuntimeError("Diagnostics credential file must be a private regular file")
            args.append(f"--dart-define=NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH={file}")
        self.process = subprocess.Popen(args, cwd=ROOT, stdout=self.log_file, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError("Navis exited before diagnostics startup")
            if HANDSHAKE.is_file() and HANDSHAKE.stat().st_size:
                value = json.loads(HANDSHAKE.read_text())
                self.port = value["port"]
                self.token = value["token"]
                break
            time.sleep(0.25)
        if self.port is None:
            raise TimeoutError("Navis diagnostics startup timed out")
        self.request("GET", "/v1/health")

    def request(self, method, path, body=None, timeout=40):
        payload = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}{path}",
            data=payload,
            method=method,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
            },
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.load(response)

    def close(self):
        if self.process is None:
            return
        try:
            self.request("POST", "/v1/shutdown", timeout=5)
        except (OSError, ValueError, urllib.error.URLError):
            pass
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.process = None


def wait_for(app, predicate, timeout):
    deadline = time.monotonic() + timeout
    last = None
    while time.monotonic() < deadline:
        last = app.request("GET", "/v1/playback/status")
        if predicate(last):
            return last
        time.sleep(0.2)
    raise TimeoutError(f"Playback did not settle; last state: "
                       f"index={last.get('navigation', {}).get('confirmedIndex') if last else None}, "
                       f"pending={last.get('navigation', {}).get('pending') if last else None}")


def burst(app, endpoint, count):
    def send(_):
        started = time.monotonic()
        result = app.request("POST", endpoint)
        return ((time.monotonic() - started) * 1000,
                result.get("navigation", {}).get("pendingQueueMutations", 0))

    with concurrent.futures.ThreadPoolExecutor(max_workers=20) as pool:
        results = list(pool.map(send, range(count)))
    latencies = [latency for latency, _ in results]
    max_pending = max(pending for _, pending in results)
    if max_pending > 1:
        raise RuntimeError("Queue mutations accumulated during the burst")
    return {
        "requests": count,
        "medianResponseMs": round(statistics.median(latencies)),
        "p95ResponseMs": round(sorted(latencies)[int((count - 1) * 0.95)]),
        "maxResponseMs": round(max(latencies)),
        "maxPendingQueueMutations": max_pending,
    }


def main():
    song_ids = prepare_clone()
    forward_target = min(100, len(song_ids) - 1)
    report = {"queueLength": len(song_ids), "bursts": []}
    with LOG.open("a", encoding="utf-8") as log:
        app = App(log)
        try:
            app.start()
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                queue = pool.submit(app.request, "POST", "/v1/playback/queue", {"songIds": song_ids})
                wait_for(app, lambda state: state.get("loadingSongId") == song_ids[0] or
                         state.get("songId") == song_ids[0], 60)
                report["bursts"].append({"direction": "next", **burst(app, "/v1/playback/next", 100)})
                queue.result(timeout=120)
            wait_for(app, lambda state: state.get("navigation", {}).get("confirmedIndex") == forward_target
                     and state.get("navigation", {}).get("pending") is False
                     and state.get("processingState") == "ready"
                     and state.get("playing") is True, 60)
            report["bursts"].append({"direction": "previous", **burst(app, "/v1/playback/previous", 100)})
            settled = wait_for(app, lambda state: state.get("navigation", {}).get("confirmedIndex") == 0
                               and state.get("navigation", {}).get("pending") is False
                               and state.get("processingState") == "ready"
                               and state.get("playing") is True, 60)
            report["navigation"] = settled.get("navigation")
            report["firstRun"] = {
                "playing": settled.get("playing"),
                "processingState": settled.get("processingState"),
                "positionMs": settled.get("positionMs"),
                "queueRestoreOutcome": settled.get("queueRestoreOutcome"),
            }
            # Pause after admitting a row selection while its source is still
            # changing. The later transport command must win without leaving
            # the navigation state pending forever.
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                selection = pool.submit(app.request, "POST", "/v1/playback/queue-index", {"index": 1})
                wait_for(app, lambda state: state.get("navigation", {}).get("desiredIndex") == 1, 20)
                app.request("POST", "/v1/playback/pause")
                selection.result(timeout=60)
            paused = wait_for(app, lambda state: state.get("navigation", {}).get("confirmedIndex") == 1
                              and state.get("navigation", {}).get("pending") is False
                              and state.get("processingState") == "ready"
                              and state.get("playing") is False, 60)
            report["pauseDuringSelection"] = {
                "confirmedIndex": paused.get("navigation", {}).get("confirmedIndex"),
                "playing": paused.get("playing"),
            }
            app.request("POST", "/v1/playback/play")
            wait_for(app, lambda state: state.get("playing") is True, 20)
            app.request("POST", "/v1/playback/queue-index", {"index": 0})
            wait_for(app, lambda state: state.get("navigation", {}).get("confirmedIndex") == 0
                     and state.get("navigation", {}).get("pending") is False
                     and state.get("playing") is True, 60)
            (OUTPUT / "report.json").write_text(json.dumps(report, indent=2))
            app.request("POST", "/v1/presentation/screenshot", {"label": "rapid-playback"})
        except Exception:
            try:
                last = app.request("GET", "/v1/playback/status", timeout=3)
                report["firstRunFailure"] = {
                    "navigation": last.get("navigation"),
                    "processingState": last.get("processingState"),
                    "playing": last.get("playing"),
                    "queueRestoreOutcome": last.get("queueRestoreOutcome"),
                }
                (OUTPUT / "report.json").write_text(json.dumps(report, indent=2))
            except Exception:
                pass
            raise
        finally:
            app.close()

        app = App(log)
        try:
            app.start()
            try:
                restored = wait_for(app, lambda state: state.get("navigation", {}).get("confirmedIndex") == 0
                                    and state.get("queueLength") == len(song_ids)
                                    and state.get("queueRestoreOutcome") == "restored"
                                    and state.get("processingState") == "ready"
                                    and state.get("playing") is False,
                                    30)
            except TimeoutError:
                last = app.request("GET", "/v1/playback/status")
                report["restartFailure"] = {
                    "queueRestoreOutcome": last.get("queueRestoreOutcome"),
                    "processingState": last.get("processingState"),
                    "playing": last.get("playing"),
                    "bootstrap": app.request("GET", "/v1/playback/bootstrap/status"),
                }
                (OUTPUT / "report.json").write_text(json.dumps(report, indent=2))
                raise
            report["restoredIndex"] = restored.get("navigation", {}).get("confirmedIndex")
            report["restoredQueueLength"] = restored.get("queueLength")
        finally:
            app.close()

    (OUTPUT / "report.json").write_text(json.dumps(report, indent=2))
    print(f"Rapid playback diagnostics passed. Evidence: {OUTPUT}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Rapid playback diagnostics failed: {type(error).__name__}: {error}", file=sys.stderr)
        print(f"Evidence: {OUTPUT}", file=sys.stderr)
        raise SystemExit(1)
