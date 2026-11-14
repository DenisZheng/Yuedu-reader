import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import verify_reader_fork_s8 as gate


class S8RegressionVerdictTests(unittest.TestCase):
    def fixture(self, mode="nonmedia"):
        identifiers = sorted(gate.selected_cases(mode))
        summary = dict(result="Passed", totalTestCount=len(identifiers), passedTests=len(identifiers),
                       failedTests=0, skippedTests=0, expectedFailures=0,
                       devicesAndConfigurations=[{"device": {"platform": "iOS Simulator", "deviceId": "SIM"}}])
        tree = {"testNodes": [{"nodeType": "Test Case", "nodeIdentifier": identifier, "result": "Passed"}
                              for identifier in identifiers]}
        console = (gate.PROBE_MARKER + "\n") * 2 + "** TEST SUCCEEDED **\n"
        return summary, tree, console

    def test_modes_are_exact_and_never_accept_stage(self):
        for mode, count, suites, excluded in [("nonmedia", 22, 5, 2), ("full", 47, 12, 0)]:
            result = gate.verify(mode, *self.fixture(mode), device_id="SIM")
            self.assertEqual((result["passed"], result["suites"], result["explicitExclusions"]), (count, suites, excluded))
            self.assertEqual(result["notSelectedFromFull"], 47 - count)
            self.assertEqual(result["externalPreconditionsNotRun"], 1)
            self.assertIs(result["stageAccepted"], False)
        self.assertTrue(gate.EXCLUDED_NONMEDIA <= gate.selected_cases("full"))
        self.assertFalse(gate.EXCLUDED_NONMEDIA & gate.selected_cases("nonmedia"))
        # 外部前置条件用例不属于任何模式；混入结果树时按“多出项目”拒绝，不能被计为通过。
        for mode in ("nonmedia", "full"):
            self.assertFalse(gate.EXTERNAL_PRECONDITIONS & gate.selected_cases(mode))
            summary, tree, console = self.fixture(mode)
            tree["testNodes"].append({"nodeType": "Test Case", "result": "Passed",
                                      "nodeIdentifier": next(iter(gate.EXTERNAL_PRECONDITIONS))})
            summary["totalTestCount"] += 1
            summary["passedTests"] += 1
            with self.assertRaises(ValueError):
                gate.verify(mode, summary, tree, console, device_id="SIM")

    def test_wrapper_failure_cannot_be_overridden_by_passed_summary(self):
        with self.assertRaises(ValueError):
            gate.verify("nonmedia", *self.fixture(), wrapper_status=1)

    def test_failure_skip_expected_failure_and_zero_tests_rejected(self):
        for key, value in [("result", "Failed"), ("failedTests", 1), ("skippedTests", 1),
                           ("expectedFailures", 1), ("totalTestCount", 0), ("passedTests", 0)]:
            summary, tree, console = self.fixture()
            summary[key] = value
            with self.assertRaises(ValueError, msg=key):
                gate.verify("nonmedia", summary, tree, console)

    def test_same_count_cannot_hide_missing_extra_or_duplicate_case(self):
        summary, tree, console = self.fixture()
        for replacement in ["UnreviewedSuite/other()", tree["testNodes"][1]["nodeIdentifier"]]:
            altered = copy.deepcopy(tree)
            altered["testNodes"][0]["nodeIdentifier"] = replacement
            with self.assertRaises(ValueError):
                gate.verify("nonmedia", summary, altered, console)

    def test_tree_failure_and_malformed_identifier_rejected(self):
        summary, tree, console = self.fixture()
        for key, value in [("result", "Failed"), ("nodeIdentifier", ["invalid"])]:
            altered = copy.deepcopy(tree)
            altered["testNodes"][0][key] = value
            with self.assertRaises(ValueError):
                gate.verify("nonmedia", summary, altered, console)

    def test_console_interim_verdict_missing_probe_and_leak_rejected(self):
        summary, tree, console = self.fixture()
        bad = ["Test run with 16 tests passed", console.replace(gate.PROBE_MARKER, ""),
               console + "** TEST FAILED **", console + gate.PROBE_PAYLOADS[0]]
        for text in bad:
            with self.assertRaises(ValueError):
                gate.verify("nonmedia", summary, tree, text)

    def test_actual_device_must_match_simulator_target(self):
        summary, tree, console = self.fixture()
        for platform, identifier in [("iOS", "SIM"), ("iOS Simulator", "OTHER")]:
            altered = copy.deepcopy(summary)
            altered["devicesAndConfigurations"][0]["device"].update(platform=platform, deviceId=identifier)
            with self.assertRaises(ValueError):
                gate.verify("nonmedia", altered, tree, console, device_id="SIM")

    def inventory(self):
        return {"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-fixture": [
            {"udid": "SIM", "isAvailable": True}, {"udid": "UNAVAILABLE", "isAvailable": False}
        ]}}

    def test_destination_rejects_phone_unknown_unavailable_and_name_fallback(self):
        self.assertEqual(gate.simulator_id("id=SIM", self.inventory()), "SIM")
        self.assertEqual(gate.simulator_id("platform=iOS Simulator,id=SIM", self.inventory()), "SIM")
        for destination in ["platform=iOS,id=SIM", "id=PHONE", "id=UNAVAILABLE", "name=fixture", "id=SIM,id=OTHER"]:
            with self.assertRaises(ValueError):
                gate.simulator_id(destination, self.inventory())

    def test_evidence_footer_executes_under_nounset(self):
        root = Path(__file__).resolve().parents[2]
        footer = next(line for line in (root / "scripts/validate_reader_fork_s8.sh").read_text().splitlines()
                      if line.startswith('echo "证据：'))
        result = subprocess.run(["/bin/bash", "-uc", 'EVIDENCE="/tmp/fixture-path"; MODE=nonmedia; ' + footer],
                                text=True, errors="replace", capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/tmp/fixture-path", result.stdout)

    def test_shell_stops_before_xctest_for_physical_destination(self):
        root = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as directory:
            temporary = Path(directory)
            binary = temporary / "bin"
            binary.mkdir()
            xcrun = binary / "xcrun"
            xcrun.write_text("#!/bin/sh\nprintf '%s\\n' '" + json.dumps(self.inventory()) + "'\n")
            xcrun.chmod(0o755)
            marker = temporary / "xctest-invoked"
            bash = binary / "bash"
            bash.write_text('#!/bin/sh\ntouch "$S8_FIXTURE_MARKER"\nexit 99\n')
            bash.chmod(0o755)
            environment = dict(os.environ, PATH=str(binary) + ":" + os.environ["PATH"],
                               DEVELOPER_DIR="/fixture", YUEDU_DEST="platform=iOS,id=SIM",
                               YUEDU_EVIDENCE_DIR=str(temporary / "evidence"), S8_FIXTURE_MARKER=str(marker))
            for key in ["YUEDU_WORKSPACE", "YUEDU_PACKAGE_DIR"]:
                environment.pop(key, None)
            result = subprocess.run(["/bin/bash", "scripts/validate_reader_fork_s8.sh", "nonmedia"],
                                    cwd=root, env=environment, text=True, capture_output=True, timeout=15)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("iOS Simulator", result.stderr)
            self.assertFalse(marker.exists(), "拒绝设备必须发生在任何xctest调用之前")


if __name__ == "__main__":
    unittest.main()
