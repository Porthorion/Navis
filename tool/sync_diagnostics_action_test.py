#!/usr/bin/env python3
"""Focused regression checks for clone action result attribution."""

import unittest

from tool.sync_diagnostics_action import action_evidence, completed_action


def ledger(events, runs):
    return {"events": events, "durableRuns": runs}


def run(
    request_id,
    *,
    intent="auxiliaryRefresh",
    plan="auxiliaryRefresh",
    outcome="completed",
    target="starred",
    attempt_id=None,
):
    return {
        "requestId": request_id,
        "attemptId": attempt_id,
        "intent": intent,
        "planKind": plan,
        "outcome": outcome,
        "targetKind": target,
    }


def attempt(request_id, attempt_id, endpoints):
    return {
        "requestId": request_id,
        "attemptId": attempt_id,
        "status": "terminal",
        "telemetry": {"captureComplete": True, "logicalEndpointRequests": endpoints},
    }


class SyncDiagnosticsActionTest(unittest.TestCase):
    def setUp(self):
        self.before = ledger(
            [{"id": 8, "cause": "repair", "phase": "terminal"}],
            [
                run(
                    10,
                    intent="repairLibrary",
                    plan="repairLibrary",
                    outcome="awaitingConfirmation",
                    target="catalog",
                    attempt_id=7,
                )
            ],
        )

    def test_cellular_action_uses_new_auxiliary_attempt_not_old_repair(self):
        after = ledger(
            self.before["events"]
            + [
                {"id": 9, "cause": "automatic", "phase": "started"},
                {
                    "id": 10,
                    "cause": "automatic",
                    "phase": "terminal",
                    "result": "partial",
                },
            ],
            [
                run(12, outcome="deferred", target="playlistHeaders"),
                run(11, attempt_id=8),
                *self.before["durableRuns"],
            ],
        )
        evidence = action_evidence(
            "automatic",
            self.before,
            after,
            {
                "attempts": [
                    attempt(11, 8, {"getStarredContent": 1}),
                    attempt(10, 7, {"getArtists": 1}),
                ]
            },
        )
        self.assertEqual(evidence["requestIds"], [11, 12])
        self.assertEqual(evidence["endpointRequests"], {"getStarredContent": 1})

    def test_catalog_sweep_is_rejected(self):
        after = ledger(
            self.before["events"]
            + [
                {"id": 9, "cause": "automatic", "phase": "started"},
                {"id": 10, "cause": "automatic", "phase": "terminal"},
            ],
            [run(11, attempt_id=8), *self.before["durableRuns"]],
        )
        with self.assertRaisesRegex(ValueError, "swept the catalog"):
            action_evidence(
                "automatic",
                self.before,
                after,
                {"attempts": [attempt(11, 8, {"getArtists": 1})]},
            )

    def test_manual_check_requires_its_new_bounded_discovery(self):
        after = ledger(
            self.before["events"]
            + [
                {"id": 9, "cause": "manualCheck", "phase": "started"},
                {
                    "id": 10,
                    "cause": "manualCheck",
                    "phase": "terminal",
                    "planReason": "manualMeteredLimitedDiscovery",
                },
            ],
            [
                run(
                    11,
                    intent="manualCatalogCheck",
                    plan="manualCatalogDiscovery",
                    target="catalog",
                    attempt_id=8,
                ),
                *self.before["durableRuns"],
            ],
        )
        evidence = action_evidence(
            "manual",
            self.before,
            after,
            {
                "attempts": [
                    attempt(11, 8, {"getNewestAlbumList2": 1, "getAlbum": 2})
                ]
            },
        )
        self.assertEqual(evidence["endpointRequests"]["getNewestAlbumList2"], 1)

    def test_old_terminal_is_not_a_new_action(self):
        self.assertIsNone(completed_action(self.before, self.before, "automatic"))

    def test_missing_attempt_is_not_silently_accepted(self):
        after = ledger(
            self.before["events"]
            + [
                {"id": 9, "cause": "automatic", "phase": "started"},
                {"id": 10, "cause": "automatic", "phase": "terminal"},
            ],
            [run(11, attempt_id=8), *self.before["durableRuns"]],
        )
        with self.assertRaisesRegex(ValueError, "omitted a durable attempt"):
            action_evidence("automatic", self.before, after, {"attempts": []})

    def test_incomplete_endpoint_telemetry_is_rejected(self):
        after = ledger(
            self.before["events"]
            + [
                {"id": 9, "cause": "automatic", "phase": "started"},
                {"id": 10, "cause": "automatic", "phase": "terminal"},
            ],
            [run(11, attempt_id=8), *self.before["durableRuns"]],
        )
        broken_attempt = attempt(11, 8, {})
        broken_attempt["telemetry"]["captureComplete"] = False
        with self.assertRaisesRegex(ValueError, "incomplete endpoint telemetry"):
            action_evidence(
                "automatic", self.before, after, {"attempts": [broken_attempt]}
            )


if __name__ == "__main__":
    unittest.main()
