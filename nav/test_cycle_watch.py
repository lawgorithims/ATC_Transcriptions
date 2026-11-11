#!/usr/bin/env python3
"""Tests for `cycle_watch.assess` — the comparison, driven without a network.

The watchdog's whole job is to be right about one question: is the published cycle stale? These
pin the answers that matter, including the one that actually happened on 2026-11-11.

    python3 nav/test_cycle_watch.py
"""
import datetime
import os
import sys
import unittest

# ⚠️ `python3 -I` (the way this repo runs scripts near downloaded data) implies -P, which strips
# the script's own directory from sys.path. Without this line the import below fails under the
# exact invocation the rest of the tooling uses.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cycle_watch as W


def idx(expires, cycle="2610", effective="2026-10-01", staged=None, datasets=("cifp", "apt", "procedures")):
    return {"datasets": {d: {"cycle": cycle, "effective": effective, "expires": expires}
                         for d in datasets},
            "staged": staged or {}}


class AssessTests(unittest.TestCase):

    def test_the_miss_that_prompted_this(self):
        """2026-11-11: published 2610 expired on 2026-10-29. This must be EXPIRED, exit 1."""
        r = W.assess(idx("2026-10-29"), datetime.date(2026, 11, 11), warn_days=14)
        self.assertEqual(r["status"], "EXPIRED")
        self.assertEqual(r["exit_code"], 1)
        self.assertEqual(r["days_left"], -13)

    def test_current_cycle_is_quiet(self):
        r = W.assess(idx("2026-11-26", cycle="2611"), datetime.date(2026, 10, 30), warn_days=14)
        self.assertEqual(r["status"], "CURRENT")
        self.assertEqual(r["exit_code"], 0)

    def test_it_warns_before_the_roll_not_after(self):
        """The point of warning is that there is still time to build and stage."""
        r = W.assess(idx("2026-11-26", cycle="2611"), datetime.date(2026, 11, 15), warn_days=14)
        self.assertEqual(r["status"], "EXPIRING")
        self.assertEqual(r["exit_code"], 2)
        self.assertEqual(r["days_left"], 11)

    def test_expiring_exactly_on_the_boundary_warns(self):
        r = W.assess(idx("2026-11-26"), datetime.date(2026, 11, 12), warn_days=14)
        self.assertEqual(r["exit_code"], 2, "14 days out with warn-days 14 must warn")

    def test_the_expiry_date_already_belongs_to_the_next_cycle(self):
        """⚠️ THE EXPIRY DATE IS THE SUCCESSOR'S EFFECTIVE DATE. 2610 expires 2026-10-29 and 2611
        becomes effective that same day, so "expires today" means the published data is already the
        old cycle. Written the other way round first, which would have let the roll day pass
        silently — the one day it most matters."""
        r = W.assess(idx("2026-11-26"), datetime.date(2026, 11, 26), warn_days=0)
        self.assertEqual(r["exit_code"], 1)
        self.assertEqual(r["days_left"], 0)

    def test_the_worst_dataset_decides(self):
        """⚠️ ONE STALE DATASET IS A DROPPED CYCLE. procedures.json going stale 404s every plate on
        its own, so an average or a majority would hide exactly the case that breaks a feature."""
        bad = idx("2026-11-26", cycle="2611")
        bad["datasets"]["procedures"]["expires"] = "2026-10-01"
        r = W.assess(bad, datetime.date(2026, 11, 11), warn_days=14)
        self.assertEqual(r["status"], "EXPIRED")
        self.assertEqual(r["days_left"], -41)

    def test_next_effective_is_the_current_expiry(self):
        r = W.assess(idx("2026-11-26"), datetime.date(2026, 11, 1), warn_days=0)
        self.assertEqual(r["next_effective"], "2026-11-26")

    def test_staged_is_reported(self):
        r = W.assess(idx("2026-11-26", staged={"cifp": {}}), datetime.date(2026, 11, 1), warn_days=0)
        self.assertEqual(r["staged"], ["cifp"])

    def test_an_empty_manifest_raises_rather_than_passing(self):
        """⚠️ NEVER READ 'no datasets' AS 'nothing wrong'. An empty or malformed manifest is the
        shape a half-finished upload leaves behind, and it must not exit 0."""
        with self.assertRaises(ValueError):
            W.assess({"datasets": {}}, datetime.date(2026, 11, 11), warn_days=14)

    def test_a_dataset_with_no_expiry_raises(self):
        broken = idx("2026-11-26")
        del broken["datasets"]["cifp"]["expires"]
        with self.assertRaises(ValueError):
            W.assess(broken, datetime.date(2026, 11, 11), warn_days=14)


if __name__ == "__main__":
    unittest.main(verbosity=2) if "-v" in sys.argv else unittest.main()
