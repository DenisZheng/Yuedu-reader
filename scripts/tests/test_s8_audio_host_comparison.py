"""隔离App与XCTest必须是同输入/同宿主；探针失败不可误判媒体通过。"""
import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from compare_reader_fork_s8_audio import FIELDS, verify


class AudioHostComparisonVerdictTests(unittest.TestCase):
    def reports(self):
        base = dict.fromkeys(FIELDS)
        base.update(bundleIdentifierSHA256="bundle", containerPathSHA256="container",
                    inputSHA256="input", inputPathSHA256="path", inputBytes=45222,
                    applicationState=0, readyWithinDeadline=True, readyStatusAtDeadline=1,
                    advancedWithinDeadline=True, cancelled=False, elapsedMs=470,
                    playerStatus=1, itemStatus=1, hasError=False, position=0.21,
                    duration=4.97, rate=1, timeControl=2, timebaseRate=1, effectiveRate=1,
                    likelyToKeepUp=True, bufferEmpty=False, outputSuppressed=False, muted=False,
                    volume=1, sourceClockOverridden=False, category="playback", mode="default",
                    sampleRate=48000, outputTypes=["Speaker"])
        xctest = dict(base, host="xctest", frameworkLoaded=True)
        app = dict(base, host="standalone", frameworkLoaded=False)
        return xctest, app

    def test_same_exact_file_and_container_pass(self):
        report = verify(*self.reports())
        self.assertTrue(report["comparisonValid"])
        self.assertTrue(report["outcomesMatch"])
        self.assertTrue(report["xctest"]["advanced"])

    def test_failure_remains_observable_not_false_success(self):
        xctest, app = self.reports()
        xctest["advancedWithinDeadline"] = False
        xctest["timebaseRate"] = 0
        report = verify(xctest, app)
        self.assertTrue(report["comparisonValid"])
        self.assertFalse(report["outcomesMatch"])
        self.assertFalse(report["xctest"]["advanced"])

    def test_reject_changed_input_or_app(self):
        for field in ("bundleIdentifierSHA256", "containerPathSHA256", "inputSHA256", "inputPathSHA256", "inputBytes"):
            xctest, app = self.reports()
            app[field] = "mismatch" if field != "inputBytes" else 999
            with self.subTest(field=field), self.assertRaises(ValueError):
                verify(xctest, app)

    def test_reject_wrong_host_or_invalid_context(self):
        for field, value in (("host", "xctest"), ("frameworkLoaded", True),
                             ("applicationState", 2), ("cancelled", True),
                             ("itemStatus", 0), ("hasError", True)):
            xctest, app = self.reports()
            app[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                verify(xctest, app)

    def test_reject_missing_or_extra_fields(self):
        for mutation in (lambda r: r.pop("inputSHA256"), lambda r: r.update(secret="do-not-store")):
            xctest, app = self.reports()
            mutation(app)
            with self.assertRaises(ValueError):
                verify(xctest, app)

    def test_rotated_container_requires_explicit_flag_and_same_content(self):
        xctest, app = self.reports()
        app["containerPathSHA256"] = "rotated-container"
        app["inputPathSHA256"] = "rotated-path"
        with self.assertRaises(ValueError):
            verify(xctest, app)
        report = verify(xctest, app, allow_rotated_container=True)
        self.assertTrue(report["comparisonValid"])
        self.assertTrue(report["containerRotated"])
        self.assertFalse(report["sameContainer"])
        xctest, app = self.reports()
        app["containerPathSHA256"] = "rotated-container"
        app["inputPathSHA256"] = "rotated-path"
        app["inputSHA256"] = "different-content"
        with self.assertRaises(ValueError):
            verify(xctest, app, allow_rotated_container=True)


if __name__ == "__main__":
    unittest.main()
