#!/usr/bin/env python3
"""Focused regression checks for clone action result attribution."""

import unittest

from tool.sync_diagnostics_action import action_evidence, completed_action


def ledger(runs):
    return {"durableRuns": runs}


def run(
    request_id,
    *,
    intent="auxiliaryRefresh",
    plan="auxiliaryRefresh",
    outcome="completed",
    target="starred",
    attempt_id=None,
    origin="timer",
    completed_at="2026-10-08T00:00:00Z",
):
    return {
        "requestId": request_id,
        "attemptId": attempt_id,
        "origin": origin,
        "intent": intent,
        "planKind": plan,
        "outcome": outcome,
        "targetKind": target,
        "completedAt": completed_at,
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
        self.before = ledger([
            run(
                10,
                intent="repairLibrary",
                plan="repairLibrary",
                outcome="awaitingConfirmation",
                target="catalog",
                attempt_id=7,
                origin="settingsRepair",
            )
        ])

    def evidence(self, scenario, before, after, attempts):
        return action_evidence(scenario, before, after, attempts, {
            "requestActive": False,
            "planReason": "manualMeteredLimitedDiscovery" if scenario == "manual" else None,
        })

    def test_cellular_action_uses_new_auxiliary_attempt_not_old_repair(self):
        after = ledger([
            run(12, outcome="deferred", target="playlistHeaders"),
            run(11, attempt_id=8),
            *self.before["durableRuns"],
        ])
        evidence = self.evidence(
            "automatic", self.before, after,
            {"attempts": [
                attempt(11, 8, {"getStarredContent": 1}),
                attempt(10, 7, {"getArtists": 1}),
            ]},
        )
        self.assertEqual(evidence["requestIds"], [11, 12])
        self.assertEqual(evidence["terminalRequestId"], 12)
        self.assertEqual(evidence["endpointRequests"], {"getStarredContent": 1})

    def test_catalog_sweep_is_rejected(self):
        after = ledger([run(11, attempt_id=8), *self.before["durableRuns"]])
        with self.assertRaisesRegex(ValueError, "swept the catalog"):
            self.evidence(
                "automatic", self.before, after,
                {"attempts": [attempt(11, 8, {"getArtists": 1})]},
            )

    def test_manual_check_requires_its_new_bounded_discovery(self):
        after = ledger([
            run(
                11, intent="manualCatalogCheck", plan="manualCatalogDiscovery",
                target="catalog", attempt_id=8, origin="libraryPullToRefresh",
            ),
            *self.before["durableRuns"],
        ])
        evidence = self.evidence(
            "manual", self.before, after,
            {"attempts": [attempt(11, 8, {"getNewestAlbumList2": 1, "getAlbum": 2})]},
        )
        self.assertEqual(evidence["endpointRequests"]["getNewestAlbumList2"], 1)

    def test_old_terminal_is_not_a_new_action(self):
        self.assertIsNone(completed_action(self.before, self.before, "automatic"))

    def test_missing_attempt_is_not_silently_accepted(self):
        after = ledger([run(11, attempt_id=8), *self.before["durableRuns"]])
        with self.assertRaisesRegex(ValueError, "omitted a durable attempt"):
            self.evidence("automatic", self.before, after, {"attempts": []})

    def test_incomplete_endpoint_telemetry_is_rejected(self):
        after = ledger([run(11, attempt_id=8), *self.before["durableRuns"]])
        broken_attempt = attempt(11, 8, {})
        broken_attempt["telemetry"]["captureComplete"] = False
        with self.assertRaisesRegex(ValueError, "incomplete endpoint telemetry"):
            self.evidence(
                "automatic", self.before, after, {"attempts": [broken_attempt]},
            )

    def test_unrelated_manual_run_is_not_an_automatic_completion(self):
        after = ledger([run(11, origin="libraryPullToRefresh")])
        self.assertIsNone(completed_action(self.before, after, "automatic"))

    def test_unfinished_run_is_not_completion(self):
        after = ledger([run(11, completed_at=None)])
        self.assertIsNone(completed_action(self.before, after, "automatic"))

    def test_failed_action_is_rejected(self):
        after = ledger([run(11, intent="automaticCatalogCheck", outcome="failed")])
        with self.assertRaisesRegex(ValueError, "action failed"):
            self.evidence("automatic", self.before, after, {"attempts": []})

    def test_active_request_is_not_completion(self):
        with self.assertRaisesRegex(ValueError, "has not settled"):
            action_evidence("automatic", self.before, ledger([run(11)]),
                            {"attempts": []}, {"requestActive": True})

    def test_manual_check_requires_bounded_cellular_reason(self):
        after = ledger([run(11, intent="manualCatalogCheck", target="catalog",
                            plan="manualCatalogDiscovery", attempt_id=8)])
        with self.assertRaisesRegex(ValueError, "bounded cellular discovery"):
            action_evidence("manual", self.before, after,
                            {"attempts": [attempt(11, 8, {"getNewestAlbumList2": 1})]},
                            {"requestActive": False, "planReason": "manualCheck"})


if __name__ == "__main__":
    unittest.main()
