#!/usr/bin/env python3
"""Launch an interactive, isolated Linux profile in a sync/setup state."""

import argparse
import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
from urllib import request


if __package__:
    from .diagnostics_profile import primary_database
else:
    from diagnostics_profile import primary_database


PROJECT_ROOT = Path(__file__).resolve().parent.parent
RUNS_ROOT = PROJECT_ROOT / "build" / "dev-sync-scenarios"
SCENARIOS = {
    "first-setup": None,
    "bad-cache": None,
    "force-setup": None,
    "manual-cache-reset": "/library-rebuild?reason=manual-cache-reset",
    "playback-recovery": "/library-rebuild?reason=playback-recovery",
    "partial-album": None,
    "server-error": None,
    "fresh-login": None,
}
FIRST_CATALOG_SCENARIOS = {"first-setup", "partial-album", "server-error"}
REQUIRES_READY_CATALOG = {
    "force-setup",
    "manual-cache-reset",
    "playback-recovery",
    "bad-cache",
}
RESET_TABLES = (
    "library_sync_run_outcome",
    "library_sync_run_attempt",
    "library_sync_run_request",
    "library_sync_operation_ledger",
    "library_sync_execution_lease",
    "library_sync_work",
    "library_sync_local_mutations",
    "library_sync_candidate_songs",
    "library_sync_candidate_albums",
    "library_sync_candidate_artists",
    "listenbrainz_feedback_queue",
    "scrobble_queue",
    "star_sync_queue",
    "annotation_dispatch_lease",
    "download_queue",
    "play_queue_items",
    "play_queue",
    "match_flow_songs",
    "match_flows",
    "playlist_songs",
    "playlists",
    "play_history",
    "recent_searches",
    "album_info_cache",
    "external_lyrics_cache",
    "listenbrainz_weekly_cache",
    "network_usage",
    "song_identity_aliases",
    "cached_tracks",
    "songs",
    "albums",
    "artists",
    "library_sync_state",
)
SANITIZE_TABLES = (
    "listenbrainz_feedback_queue",
    "scrobble_queue",
    "star_sync_queue",
    "annotation_dispatch_lease",
    "download_queue",
    "play_queue_items",
    "play_queue",
    "cached_tracks",
)


def _tables(db: sqlite3.Connection) -> set[str]:
    return {
        row[0]
        for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")
    }


def _columns(db: sqlite3.Connection, table: str) -> set[str]:
    return {row[1] for row in db.execute(f"PRAGMA table_info({table})")}


def _is_ready(db: sqlite3.Connection, server_id: int, tables: set[str]) -> bool:
    row = db.execute(
        "SELECT last_synced FROM server_config WHERE id = ?", (server_id,)
    ).fetchone()
    if row and row[0] is not None:
        return True
    if "library_sync_state" not in tables:
        return False
    columns = _columns(db, "library_sync_state")
    timestamps = [
        name
        for name in ("last_catalog_synced_at", "initial_catalog_usable_at")
        if name in columns
    ]
    if not timestamps:
        return False
    values = db.execute(
        "SELECT current_generation, "
        + ", ".join(timestamps)
        + " FROM library_sync_state WHERE server_id = ?",
        (server_id,),
    ).fetchone()
    return bool(values and values[0] > 0 and any(value is not None for value in values[1:]))


def prepare_database(
    source: Path,
    destination: Path,
    scenario: str,
    *,
    fixture_url: str | None = None,
) -> None:
    """Backup the primary DB and alter only the disposable copy."""
    if scenario == "fresh-login":
        return
    if not source.is_file():
        raise ValueError(f"Source database does not exist: {source}")
    source_uri = source.resolve().as_uri() + "?mode=ro"
    with sqlite3.connect(source_uri, uri=True) as primary:
        with sqlite3.connect(destination) as clone:
            primary.backup(clone)
    os.chmod(destination, 0o600)
    db = sqlite3.connect(destination)
    try:
        tables = _tables(db)
        required = {"server_config", "app_settings", "cache_system_state"}
        if not required <= tables:
            raise ValueError("Source database needs a current Navis schema")
        if "onboarding_version" not in _columns(db, "app_settings"):
            raise ValueError("Source database needs a current onboarding schema")
        server = db.execute(
            "SELECT id FROM server_config WHERE is_authenticated = 1 LIMIT 1"
        ).fetchone()
        if server is None:
            raise ValueError("Sign in to Navis once before using this preset")
        server_id = server[0]
        if scenario in REQUIRES_READY_CATALOG and not _is_ready(db, server_id, tables):
            raise ValueError("This preset needs an already usable library")
        # Clone-only setup: remove outbound work and cached file references so
        # resets and playback cannot touch the source profile's owned files.
        db.execute("PRAGMA foreign_keys = OFF")
        with db:
            settings_columns = _columns(db, "app_settings")
            isolated_settings = {
                "custom_download_folder_enabled": 0,
                "custom_download_folder_path": None,
                "custom_download_folder_storage_kind": "filesystem",
                "auto_download_starred_on_wifi": 0,
            }
            for column, value in isolated_settings.items():
                if column in settings_columns:
                    db.execute(f"UPDATE app_settings SET {column} = ?", (value,))
            for table in RESET_TABLES if scenario in FIRST_CATALOG_SCENARIOS else SANITIZE_TABLES:
                if table in tables:
                    db.execute(f"DELETE FROM {table}")
            if scenario in FIRST_CATALOG_SCENARIOS:
                db.execute(
                    "UPDATE server_config SET last_synced = NULL, "
                    "last_full_synced = NULL, capabilities = NULL"
                )
                db.execute("UPDATE app_settings SET onboarding_version = 0")
            elif scenario == "force-setup":
                db.execute("UPDATE app_settings SET onboarding_version = 0")
            if scenario == "bad-cache":
                db.execute("DELETE FROM cache_system_state")
            else:
                db.execute(
                    "INSERT INTO cache_system_state "
                    "(id, cache_system_version) VALUES (1, 3) "
                    "ON CONFLICT(id) DO UPDATE SET cache_system_version = 3"
                )
            if fixture_url is not None:
                db.execute(
                    "UPDATE server_config SET name = ?, url = ?, username = ?, "
                    "api_version = ?, is_authenticated = 1 WHERE id = ?",
                    ("Navis sync fixture", fixture_url, "diagnostics", "1.16.1", server_id),
                )
        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("Isolated database failed integrity check")
        if db.execute("PRAGMA foreign_key_check").fetchall():
            raise ValueError("Isolated database failed foreign-key check")
    finally:
        db.close()


def _app_version() -> str:
    for line in (PROJECT_ROOT / "pubspec.yaml").read_text(encoding="utf-8").splitlines():
        if line.startswith("version:"):
            return line.split(":", 1)[1].strip().split("+", 1)[0]
    raise ValueError("pubspec.yaml has no version")


def prepare_support_directory(root: Path, scenario: str) -> None:
    """Seed the clone's app-support directory, which the app keeps in root."""
    support = root / "support"
    support.mkdir(mode=0o700, exist_ok=True)
    if scenario == "fresh-login":
        # An empty profile shows this build's What's New card, as a new
        # install does.
        return
    marker = support / "changelog_seen_version.txt"
    marker.write_text(_app_version() + "\n", encoding="utf-8")
    os.chmod(marker, 0o600)


def _wait_for_json(path: Path, process: subprocess.Popen, timeout: int) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if path.is_file():
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except (ValueError, OSError):
                pass
        if process.poll() is not None:
            raise RuntimeError(f"Process exited before startup (code {process.returncode})")
        time.sleep(0.2)
    raise RuntimeError("Timed out waiting for startup")


def _api(handshake: dict, route: str, body: dict) -> dict:
    address = f"http://127.0.0.1:{handshake['port']}{route}"
    payload = json.dumps(body).encode("utf-8")
    call = request.Request(
        address,
        data=payload,
        headers={
            "Authorization": f"Bearer {handshake['token']}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with request.urlopen(call, timeout=15) as response:
        return json.load(response)


def _stop(process: subprocess.Popen | None) -> None:
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def _scenario_args(argv: list[str]) -> tuple[argparse.Namespace, list[str]]:
    parser = argparse.ArgumentParser(
        description="Run an isolated Navis Linux sync/setup scenario."
    )
    parser.add_argument("-d", "--device-id", required=True)
    scenarios = parser.add_mutually_exclusive_group(required=True)
    for name in SCENARIOS:
        scenarios.add_argument(f"--{name}", action="store_true")
    network = parser.add_mutually_exclusive_group()
    network.add_argument("--offline", action="store_true")
    network.add_argument("--metered", action="store_true")
    parser.add_argument("--scenario-source", type=Path, default=primary_database())
    options, flutter_args = parser.parse_known_args(argv)
    options.scenario = next(name for name in SCENARIOS if getattr(options, name.replace("-", "_")))
    if options.device_id != "linux":
        parser.error("sync scenarios currently support only -d linux")
    if any(
        arg in {"--debug", "--profile", "--release", "--flavor", "-t", "--target"}
        or arg.startswith("--dart-define")
        for arg in flutter_args
    ):
        parser.error("Flutter build mode, target, flavor, and dart-defines are managed by this preset")
    return options, flutter_args


def _clone_diagnostic_defines(
    options: argparse.Namespace,
    *,
    root: Path,
    database: Path,
    handshake_path: Path,
    fixture_credential: Path | None = None,
) -> dict[str, str]:
    """Build diagnostics defines that keep a long catalog run fenced."""
    defines = {
        "NAVIS_UPDATE_CHANNEL": "dev",
        "NAVIS_SELF_UPDATE": "true",
        "NAVIS_AGENT_DEBUG": "true",
        "NAVIS_APP_ID_SUFFIX": os.environ.get("NAVIS_APP_ID_SUFFIX", ".dev"),
        "NAVIS_APP_NAME": os.environ.get("NAVIS_APP_NAME", "Navis Dev"),
        "NAVIS_SYNC_DIAGNOSTICS": "true",
        "NAVIS_SYNC_DIAGNOSTICS_MODE": "clone",
        "NAVIS_SYNC_DIAGNOSTICS_ROOT": str(root),
        "NAVIS_SYNC_DIAGNOSTICS_DB_PATH": str(database),
        "NAVIS_SYNC_DIAGNOSTICS_HANDSHAKE": str(handshake_path),
        "NAVIS_SYNC_DIAGNOSTICS_MUTED": "true",
        # These interactive presets can collect a large live catalog. Keep the
        # production lease duration so the write fence remains valid during
        # atomic promotion; the short default is only for interruption tests.
        "NAVIS_SYNC_DIAGNOSTICS_LEASE_SECONDS": "600",
    }
    if options.scenario == "bad-cache":
        defines["NAVIS_SYNC_DIAGNOSTICS_ALLOW_CACHE_UPGRADE"] = "true"
    if options.offline:
        defines["NAVIS_SYNC_DIAGNOSTICS_INITIAL_NETWORK"] = "offline"
    elif options.metered:
        defines["NAVIS_SYNC_DIAGNOSTICS_INITIAL_NETWORK"] = "metered"
    if fixture_credential is not None:
        defines["NAVIS_SYNC_DIAGNOSTICS_CREDENTIAL_PATH"] = str(
            fixture_credential
        )
    return defines


def launch(argv: list[str]) -> int:
    options, flutter_args = _scenario_args(argv)
    RUNS_ROOT.mkdir(parents=True, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix=f"{options.scenario}-", dir=RUNS_ROOT))
    os.chmod(root, 0o700)
    (root / "scenario.json").write_text(
        json.dumps({"scenario": options.scenario}) + "\n", encoding="utf-8"
    )
    os.chmod(root / "scenario.json", 0o600)
    prepare_support_directory(root, options.scenario)
    database = root / "navis.sqlite"
    handshake_path = root / "handshake.json"
    fixture_process = None
    flutter_process = None
    fixture_log = None
    try:
        fixture_url = None
        if options.scenario in {"partial-album", "server-error"}:
            if options.scenario == "partial-album":
                (root / "incomplete-album.flag").touch(mode=0o600)
            else:
                (root / "server-error.flag").touch(mode=0o600)
            fixture_log = (root / "fixture.log").open("wb")
            fixture_args = [
                sys.executable,
                str(PROJECT_ROOT / "tool" / "auth_lifecycle_fixture_server.py"),
                "--handshake", str(root / "fixture-handshake.json"),
                "--failure-flag", str(root / "server-error.flag"),
                "--partial-album-flag", str(root / "incomplete-album.flag"),
            ]
            if options.scenario == "partial-album":
                fixture_args += ["--scenario", "partial-album"]
            fixture_process = subprocess.Popen(
                fixture_args, cwd=PROJECT_ROOT, stdout=fixture_log, stderr=subprocess.STDOUT
            )
            fixture = _wait_for_json(root / "fixture-handshake.json", fixture_process, 20)
            fixture_url = f"http://127.0.0.1:{fixture['port']}"
            credential = root / "fixture-credential"
            credential.write_text("navis-sync-scenario-fixture\n", encoding="utf-8")
            os.chmod(credential, 0o600)
        prepare_database(
            options.scenario_source.expanduser(), database, options.scenario,
            fixture_url=fixture_url,
        )
        defines = _clone_diagnostic_defines(
            options,
            root=root,
            database=database,
            handshake_path=handshake_path,
            fixture_credential=(root / "fixture-credential")
            if fixture_url is not None
            else None,
        )
        command = ["flutter", "run", "-d", "linux", "--profile"]
        command += [f"--dart-define={key}={value}" for key, value in defines.items()]
        command += flutter_args
        print(f"Scenario: {options.scenario}", flush=True)
        print(f"Isolated profile: {root}", flush=True)
        print("Build mode: profile (scenario controls require clone diagnostics)", flush=True)
        if fixture_url is not None:
            print(f"Fixture response: {options.scenario}", flush=True)
            print(f"Change it from another terminal: ./tool/dev_app.sh scenario {root} server-fix", flush=True)
        if options.offline or options.metered:
            print(f"Restore Wi-Fi from another terminal: ./tool/dev_app.sh scenario {root} online", flush=True)
        flutter_process = subprocess.Popen(command, cwd=PROJECT_ROOT)
        handshake = _wait_for_json(handshake_path, flutter_process, 180)
        route = SCENARIOS[options.scenario]
        if route:
            navigation = _api(handshake, "/v1/presentation/navigate", {"location": route})
            if navigation.get("actualLocation") != route:
                raise RuntimeError("Scenario route redirected before the rebuild could start")
        return flutter_process.wait()
    except KeyboardInterrupt:
        return 130
    finally:
        _stop(flutter_process)
        _stop(fixture_process)
        if fixture_log is not None:
            fixture_log.close()


def control(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Control a running isolated scenario.")
    parser.add_argument("root", type=Path)
    parser.add_argument("action", choices=("online", "offline", "metered", "server-fix", "server-break"))
    options = parser.parse_args(argv)
    root = options.root.expanduser().resolve()
    if not root.is_relative_to(RUNS_ROOT.resolve()):
        parser.error("scenario root must be under build/dev-sync-scenarios")
    handshake_path = root / "handshake.json"
    if not handshake_path.is_file():
        parser.error("scenario handshake is missing")
    if options.action in {"online", "offline", "metered"}:
        handshake = json.loads(handshake_path.read_text(encoding="utf-8"))
        payload = {
            "networkType": "wifi" if options.action == "online" else
                "offline" if options.action == "offline" else "cellular",
            "nativeMetered": options.action == "metered",
        }
        _api(handshake, "/v1/diagnostics/overrides", payload)
    else:
        manifest = root / "scenario.json"
        if not manifest.is_file():
            parser.error("scenario manifest is missing")
        scenario = json.loads(manifest.read_text(encoding="utf-8")).get("scenario")
        if scenario == "partial-album":
            selected = root / "incomplete-album.flag"
        elif scenario == "server-error":
            selected = root / "server-error.flag"
        else:
            parser.error("this scenario has no server response flag")
        if options.action == "server-fix":
            selected.unlink(missing_ok=True)
        else:
            selected.touch(mode=0o600)
    print(f"Scenario control applied: {options.action}")
    return 0


if __name__ == "__main__":
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "control":
            raise SystemExit(control(sys.argv[2:]))
        raise SystemExit(launch(sys.argv[1:]))
    except (OSError, ValueError, RuntimeError, sqlite3.Error) as error:
        print(f"Scenario launch failed: {error}", file=sys.stderr)
        raise SystemExit(1)
