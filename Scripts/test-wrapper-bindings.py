#!/usr/bin/env python3
"""Pure regression checks for the existing strict source-binding verifier."""
import copy
import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("wrapper_bindings", ROOT / "Scripts/verify-wrapper-bindings.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class WrapperBindingTests(unittest.TestCase):
    def setUp(self):
        self.document = json.loads((ROOT / "Scripts/wrapper-expected-bindings.json").read_text())
        self.lock = json.loads((ROOT / "Package.resolved").read_text())

    def expected(self, document=None):
        return checks.expected_pins(self.document if document is None else document)

    def core(self, lock):
        return next(row for row in lock["pins"] if row["identity"] == "latticecore")

    def test_legacy_versioned_bindings_keep_exact_release_checks(self):
        legacy = copy.deepcopy(self.document)
        core = next(row for row in legacy["pins"] if row["identity"] == "latticecore")
        core.pop("selection")
        core.update(version="2.2.8", revision="543ad0be9d69b65f116c487483b05becb6707990")
        lock = copy.deepcopy(self.lock)
        self.core(lock)["state"] = {"version": core["version"], "revision": core["revision"]}
        expected = self.expected(legacy)
        self.assertEqual(checks.verify_resolved(lock, expected), [])
        for key, changed in [("version", "2.2.9"), ("revision", "0" * 40)]:
            mismatch = copy.deepcopy(lock)
            self.core(mismatch)["state"][key] = changed
            self.assertTrue(checks.verify_resolved(mismatch, expected))

    def test_current_version_pin_matches_released_source(self):
        expected = self.expected()
        self.assertEqual(expected["latticecore"]["selection"], "version")
        self.assertEqual(expected["latticecore"]["version"], "3.0.0")
        self.assertEqual(self.core(self.lock)["state"], {
            "revision": "f6eb64e0ccd3f1bef04371f3049c24a1467ba2f8", "version": "3.0.0"})
        self.assertEqual(checks.verify_resolved(self.lock, expected), [])

    def test_version_expectation_requires_release_identity(self):
        for key, value in [("version", None), ("version", ""), ("version", 3),
                           ("selection", "anything"), ("revision", "short")]:
            document = copy.deepcopy(self.document)
            next(row for row in document["pins"] if row["identity"] == "latticecore")[key] = value
            with self.subTest(key=key, value=value), self.assertRaises(checks.BindingError):
                self.expected(document)
        document = copy.deepcopy(self.document)
        next(row for row in document["pins"] if row["identity"] == "latticecore").pop("version")
        with self.assertRaises(checks.BindingError):
            self.expected(document)

    def test_version_pin_refuses_changed_release_and_source_scope(self):
        expected = self.expected()
        revision = expected["latticecore"]["revision"]
        version = expected["latticecore"]["version"]
        for state in [{"revision": "0" * 40, "version": version}, {},
                      {"revision": revision},
                      {"revision": revision, "version": None},
                      {"revision": revision, "version": "2.2.8"},
                      {"revision": revision, "version": version, "branch": "main"}]:
            lock = copy.deepcopy(self.lock)
            self.core(lock)["state"] = state
            with self.subTest(state=state):
                self.assertTrue(checks.verify_resolved(lock, expected))
        for field, value in [("location", "https://github.com/foreign/LatticeCore.git"),
                             ("kind", "fileSystem"), ("identity", "other-core")]:
            lock = copy.deepcopy(self.lock)
            self.core(lock)[field] = value
            with self.subTest(field=field):
                self.assertTrue(checks.verify_resolved(lock, expected))


if __name__ == "__main__":
    unittest.main()
