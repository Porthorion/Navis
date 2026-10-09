#!/usr/bin/env python3
"""Reproduce lock-cache seek recovery via the sync diagnostics API."""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

from diagnostics_profile import primary_database


def api(port: int, token: str, method: str, path: str, body: dict | None = None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            **({"Content-Type": "application/json"} if body is not None else {}),
        },
    )
    with urllib.request.urlopen(req, timeout=120) as resp:
        raw = resp.read()
        return resp.status, json.loads(raw) if raw else {}


def wait_handshake(path: Path, pid: int, timeout_s: int = 180) -> dict:
    for _ in range(timeout_s):
        if path.is_file() and path.stat().st_size > 0:
            return json.loads(path.read_text(encoding="utf-8"))
        if os.waitpid(pid, os.WNOHANG)[0] != 0:
            raise RuntimeError("app exited before handshake")
        time.sleep(1)
    raise TimeoutError("handshake timeout")


def summarize(status: dict) -> dict:
    keys = [
        "songId",
        "playing",
        "positionMs",
        "bufferedPositionMs",
        "durationMs",
        "sourceKind",
        "lockCachingBypassed",
        "partialCacheBytes",
        "processingState",
        "isLoading",
        "cacheActivity",
        "providerCacheActivity",
    ]
    return {k: status.get(k) for k in keys}


def mute_and_verify(port: int, token: str) -> None:
    _, volume = api(port, token, "POST", "/v1/playback/volume", {"value": 0})
    if volume.get("volume") != 0 or volume.get("effectivePlayerVolume") != 0:
        raise RuntimeError("diagnostics mute could not be confirmed")
    print("MUTED", {"effectivePlayerVolume": volume["effectivePlayerVolume"]})


def main() -> int:
    project = Path(__file__).resolve().parents[1]
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    root = project / "build" / "sync-diagnostics" / f"seek-diag-{stamp}"
    root.mkdir(parents=True, exist_ok=True)
    os.chmod(root, 0o700)
    cache_root = root / "cache"
    cache_root.mkdir(exist_ok=True)
    clone_db = root / "navis-diagnostics.sqlite"
    handshake = root / "handshake.json"
    app_log = root / "navis.log"
    source_db = primary_database()

    source = sqlite3.connect(f"file:{source_db}?mode=ro", uri=True)
    target = sqlite3.connect(clone_db)
    source.backup(target)
    source.close()
    for song_id, source_path in target.execute(
        "SELECT song_id, file_path FROM cached_tracks"
    ).fetchall():
        extension = os.path.splitext(source_path)[1] or ".isolated"
        destination = cache_root / f"{song_id}{extension}"
        if os.path.isfile(source_path):
            shutil.copy2(source_path, destination)
        target.execute(
            "UPDATE cached_tracks SET file_path = ? WHERE song_id = ?",
            (str(destination), song_id),
        )
    row = target.execute(
        "SELECT id, title, duration FROM songs "
        "WHERE duration BETWEEN 240 AND 480 ORDER BY RANDOM() LIMIT 1"
    ).fetchone()
    if row is None:
        raise RuntimeError("no suitable song found")
    song_id, title, duration = row
    (root / "song.txt").write_text(song_id, encoding="utf-8")
    target.commit()
    target.close()
    print(f"ROOT={root}")
    print(f"SONG={song_id}|{title}|{duration}")

    if handshake.exists():
        handshake.unlink()
    app_log.write_text("", encoding="utf-8")
    log_fh = open(app_log, "a", encoding="utf-8")
    command = [
        "flutter",
        "run",
        "-d",
        "linux",
        "--profile",
        "--dart-define=NAVIS_UPDATE_CHANNEL=dev",
        "--dart-define=NAVIS_APP_ID_SUFFIX=.dev",
        "--dart-define=NAVIS_APP_NAME=Navis Diagnostics",
        "--dart-define=NAVIS_SYNC_DIAGNOSTICS=true",
        "--dart-define=NAVIS_SYNC_DIAGNOSTICS_MUTED=true",
        "--dart-define=NAVIS_SYNC_DIAGNOSTICS_MODE=clone",
        f"--dart-define=NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE={handshake}",
        f"--dart-define=NAVIS_SYNC_DIAGNOSTICS_ROOT={root}",
        f"--dart-define=NAVIS_SYNC_DIAGNOSTICS_DB_PATH={clone_db}",
    ]
    # Like the other clone gates: an optional mode-600 password file signs the
    # clone in where the system keyring holds no Navis password.
    credential = os.environ.get("NAVIS_DIAGNOSTICS_CREDENTIAL_PATH", "")
    if credential:
        if not Path(credential).is_file():
            raise RuntimeError("Diagnostics credential file was not found.")
        command.append(
            f"--dart-define=NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH={credential}"
        )
    proc = subprocess.Popen(
        command,
        cwd=project,
        stdout=log_fh,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    (root / "flutter.pid").write_text(str(proc.pid), encoding="utf-8")
    print(f"FLUTTER_PID={proc.pid}")
    try:
        hs = wait_handshake(handshake, proc.pid)
        port = int(hs["port"])
        token = str(hs["token"])
        print(f"PORT={port}")
        # The handler's seek-specific buffering recovery has a short deadline.
        # Wait past it before asserting the transport state.
        time.sleep(5)
        status_code, health = api(port, token, "GET", "/v1/health")
        print("health", status_code, {k: health.get(k) for k in ("mode", "schemaVersion")})
        mute_and_verify(port, token)

        _, start = api(
            port, token, "POST", "/v1/playback/start", {"songId": song_id}
        )
        print("start", start)

        ready = None
        for i in range(90):
            _, status = api(port, token, "GET", "/v1/playback/status")
            print(f"t={i+1}s", summarize(status))
            source_kind = status.get("sourceKind")
            buffered = status.get("bufferedPositionMs") or 0
            caching = (status.get("cacheActivity") or {}).get("status") == "caching"
            # Prefer seeking while the sidecar cache is still filling so we
            # exercise the original hang path (seek past uncached audio).
            if (
                status.get("playing")
                and buffered > 5000
                and source_kind in ("directStream", "lockCachedStream")
                and (caching or i >= 4)
            ):
                ready = status
                break
            time.sleep(1)
        if ready is None:
            print("FAILED_TO_READY")
            return 2

        buf = int(ready.get("bufferedPositionMs") or 0)
        dur_ms = int(ready.get("durationMs") or duration * 1000)
        # Jump well past the current buffer into uncached territory when possible.
        target_ms = min(max(buf + 60000, 120000), max(dur_ms - 5000, buf + 10000))
        # If the player has already buffered nearly the whole track, still seek
        # near the end to measure seek latency on a direct stream.
        if buf >= dur_ms - 15000:
            target_ms = max(dur_ms - 10000, 30000)
        print(f"SEEK_PAST targetMs={target_ms}")
        _, past = api(
            port,
            token,
            "POST",
            "/v1/playback/seek",
            {"positionMs": target_ms},
        )
        print(
            "SEEK_PAST_RESULT",
            {
                "elapsedMs": past.get("elapsedMs"),
                "before": summarize(past.get("before") or {}),
                "after": summarize(past.get("after") or {}),
                "seekEvents": (past.get("after") or {}).get("seekEvents"),
            },
        )
        time.sleep(2)
        _, settle = api(port, token, "GET", "/v1/playback/status")
        print("SETTLE", summarize(settle))

        print("SEEK_BACK targetMs=5000")
        _, back = api(
            port, token, "POST", "/v1/playback/seek", {"positionMs": 5000}
        )
        print(
            "SEEK_BACK_RESULT",
            {
                "elapsedMs": back.get("elapsedMs"),
                "before": summarize(back.get("before") or {}),
                "after": summarize(back.get("after") or {}),
                "seekEvents": (back.get("after") or {}).get("seekEvents"),
            },
        )
        time.sleep(2)
        _, final = api(port, token, "GET", "/v1/playback/status")
        print("FINAL", summarize(final))
        print("EVENTS", json.dumps(final.get("seekEvents") or [], indent=2))
        (root / "seek-report.json").write_text(
            json.dumps(
                {
                    "past": past,
                    "settle": settle,
                    "back": back,
                    "final": final,
                    "logTail": app_log.read_text(encoding="utf-8")[-4000:],
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        print(f"REPORT={root / 'seek-report.json'}")
        return 0
    except (urllib.error.URLError, TimeoutError, RuntimeError) as error:
        print(f"ERROR: {error}")
        print(app_log.read_text(encoding="utf-8")[-3000:])
        return 1
    finally:
        try:
            api(port, token, "POST", "/v1/shutdown", {})
        except Exception:
            pass
        try:
            os.killpg(proc.pid, 15)
        except Exception:
            proc.terminate()
        try:
            proc.wait(timeout=15)
        except Exception:
            proc.kill()
        log_fh.close()


if __name__ == "__main__":
    sys.exit(main())
