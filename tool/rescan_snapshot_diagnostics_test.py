#!/usr/bin/env python3
"""Self-test of the rescan harness ReplayGain filter read against cross-fade decks."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rescan_snapshot_diagnostics import replay_gain_filter_db  # noqa: E402


def deck(db, playing):
    return {"playing": playing, "requestedPlaying": playing, "replayGainDb": db,
            "audioFilters": f"@navis_rg:lavfi=graph=%31%volume={db:.3f}dB:precision=float,"
                            "@navis_tempo:scaletempo=scale=%3%1.0"}


def status(*transports):
    return {"native": {"mediaKitTransport": list(transports)}}


class ReplayGainFilterDbTest(unittest.TestCase):
    def test_idle_crossfade_deck_listed_first_is_ignored(self):
        # After a cross-fade swap the old main deck is idle, parked on the song
        # it ran into at EOF (-3.5); the playing deck applied song 3's -8.0.
        self.assertEqual(replay_gain_filter_db(status(deck(-3.5, False), deck(-8.0, True))), -8.0)

    def test_playing_deck_listed_first_is_read(self):
        self.assertEqual(replay_gain_filter_db(status(deck(-8.0, True), deck(-3.5, False))), -8.0)

    def test_single_deck_keeps_its_gain(self):
        self.assertEqual(replay_gain_filter_db(status(deck(-9.0, True))), -9.0)
        self.assertEqual(replay_gain_filter_db(status(deck(-4.0, False))), -4.0)

    def test_mid_fade_two_playing_decks_are_ambiguous(self):
        # The caller's wait loop keeps polling until one deck remains playing.
        self.assertIsNone(replay_gain_filter_db(status(deck(-8.0, True), deck(-3.5, True))))

    def test_no_filter_is_none(self):
        self.assertIsNone(replay_gain_filter_db(status()))
        self.assertIsNone(replay_gain_filter_db({}))
        idle_filter = deck(-8.0, True)
        idle_filter["audioFilters"] = "@navis_tempo:scaletempo=scale=%3%1.0"
        self.assertIsNone(replay_gain_filter_db(status(idle_filter)))


    def test_idle_deck_is_ignored_when_the_playing_deck_has_no_filter(self):
        playing = {**deck(-3.5, True), "audioFilters": None}
        self.assertIsNone(replay_gain_filter_db(status(deck(-9.0, False), playing)))

if __name__ == "__main__":
    unittest.main()
