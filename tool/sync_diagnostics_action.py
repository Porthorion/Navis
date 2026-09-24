#!/usr/bin/env python3
"""Correlate clone diagnostics actions with new, redacted sync ledger rows."""

import json
import sys
from pathlib import Path


def _read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _maximum(rows, key):
    return max((row.get(key) or 0 for row in rows), default=0)


def completed_action(before, after, cause):
    cursor = _maximum(before.get("events", []), "id")
    events = [
        event
        for event in after.get("events", [])
        if (event.get("id") or 0) > cursor and event.get("cause") == cause
    ]
    starts = [event for event in events if event.get("phase") == "started"]
    terminals = [
        event for event in events if event.get("phase") in ("terminal", "failed")
    ]
    if not starts or not terminals:
        return None
    terminal = terminals[-1]
    if terminal["id"] <= starts[-1]["id"]:
        return None
    return terminal


def action_evidence(scenario, before, after, attempts):
    cause = "manualCheck" if scenario == "manual" else "automatic"
    terminal = completed_action(before, after, cause)
    if terminal is None:
        raise ValueError("diagnostics action has no correlated terminal event")
    if terminal["phase"] == "failed":
        raise ValueError("diagnostics action failed")

    cursor = _maximum(before.get("durableRuns", []), "requestId")
    runs = [
        run
        for run in after.get("durableRuns", [])
        if (run.get("requestId") or 0) > cursor
    ]
    if not runs:
        raise ValueError("diagnostics action produced no durable sync requests")
    if any(
        run.get("attemptId") is None and (run.get("requestCount") or 0) > 0
        for run in runs
    ):
        raise ValueError("diagnostics action has unverified request counts")
    run_ids = {run["requestId"] for run in runs}
    relevant_attempts = [
        attempt
        for attempt in attempts.get("attempts", [])
        if attempt.get("requestId") in run_ids
    ]
    if any(
        run.get("attemptId") is not None
        and not any(
            attempt.get("attemptId") == run["attemptId"]
            for attempt in relevant_attempts
        )
        for run in runs
    ):
        raise ValueError("diagnostics action omitted a durable attempt")

    endpoints = {}
    for attempt in relevant_attempts:
        if attempt.get("status") != "terminal":
            raise ValueError("diagnostics action has an unsettled attempt")
        telemetry = attempt.get("telemetry") or {}
        counts = telemetry.get("logicalEndpointRequests")
        if telemetry.get("captureComplete") is not True or not isinstance(
            counts, dict
        ):
            raise ValueError("diagnostics action has incomplete endpoint telemetry")
        for name, count in counts.items():
            endpoints[name] = endpoints.get(name, 0) + count

    for name in (
        "getArtists",
        "getArtist",
        "getAlbumListPage",
        "getAlbumList2",
        "searchSongsPage",
    ):
        if endpoints.get(name, 0) != 0:
            raise ValueError(f"diagnostics action swept the catalog via {name}")
    if endpoints.get("getIndexes", 0) > 1:
        raise ValueError("diagnostics action exceeded the bounded index probe")

    if scenario == "manual":
        if not any(
            run.get("intent") == "manualCatalogCheck"
            and run.get("planKind") == "manualCatalogDiscovery"
            for run in runs
        ):
            raise ValueError("manual check did not create a catalog discovery run")
        if terminal.get("planReason") != "manualMeteredLimitedDiscovery":
            raise ValueError("manual check did not use bounded cellular discovery")
        if endpoints.get("getNewestAlbumList2", 0) != 1:
            raise ValueError("manual check did not request exactly one newest page")
        if endpoints.get("getAlbum", 0) > 3:
            raise ValueError("manual check hydrated too many changed albums")
    elif scenario == "automatic":
        if endpoints.get("getNewestAlbumList2", 0) > 1:
            raise ValueError(
                "automatic cellular work exceeded the bounded newest probe"
            )
        if any(
            run.get("targetKind") == "catalog"
            and run.get("planKind") == "repairLibrary"
            and run.get("outcome") not in ("deferred", "skipped")
            for run in runs
        ):
            raise ValueError("automatic cellular work resumed a broad repair")
    else:
        raise ValueError("unknown diagnostics scenario")

    return {
        "cause": cause,
        "terminalEventId": terminal["id"],
        "requestIds": sorted(run_ids),
        "outcomes": sorted({run.get("outcome") or "unknown" for run in runs}),
        "endpointRequests": endpoints,
    }


def main():
    command = sys.argv[1]
    if command == "complete":
        before, after, cause = (_read(sys.argv[2]), _read(sys.argv[3]), sys.argv[4])
        return 0 if completed_action(before, after, cause) else 1
    if command == "validate":
        scenario = sys.argv[2]
        before, after, attempts = map(_read, sys.argv[3:6])
        print(json.dumps(action_evidence(scenario, before, after, attempts)))
        return 0
    raise ValueError("usage: sync_diagnostics_action.py complete|validate ...")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ValueError, KeyError, TypeError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(2) from None
