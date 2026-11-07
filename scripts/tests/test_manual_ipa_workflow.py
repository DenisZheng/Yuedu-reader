"""手动IPA工作流的触发/工具链/权限合同，不启动GitHub云端构建。"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/build-ios.yml"


def load_workflow():
    # 使用macOS已有Ruby/Psych，不给项目增加PyYAML依赖。
    return json.loads(subprocess.check_output([
        "ruby", "-ryaml", "-rjson", "-e",
        "puts JSON.generate(YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false))", str(WORKFLOW)
    ], text=True))


class ManualIPAWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workflow = load_workflow()
        cls.job = cls.workflow["jobs"]["ipa"]
        cls.steps = {step["name"]: step for step in cls.job["steps"]}

    def test_only_manual_trigger(self):
        self.assertEqual(set(self.workflow["on"]), {"workflow_dispatch"})
        self.assertEqual(set(self.workflow["jobs"]), {"ipa"})
        self.assertTrue(self.workflow["concurrency"]["cancel-in-progress"])
        self.assertIn("github.ref", self.workflow["concurrency"]["group"])
        self.assertEqual(self.job["timeout-minutes"], 60)

    def test_stable_runner_and_read_only_pinned_actions(self):
        self.assertEqual(self.job["runs-on"], "macos-26")
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        checkout = self.steps["Checkout selected branch or tag"]
        self.assertFalse(checkout["with"]["persist-credentials"])
        for step in self.job["steps"]:
            if "uses" in step:
                self.assertRegex(step["uses"], r"^actions/[a-z-]+@[0-9a-f]{40}$")

    def test_unsigned_device_archive_no_tests_or_derived_data_workaround(self):
        archive = self.steps["Archive unsigned device app"]["run"]
        for token in ("xcodebuild archive", "-configuration Release", "generic/platform=iOS",
                      "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "DEVELOPMENT_TEAM=",
                      "-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile"):
            self.assertIn(token, archive)
        scripts = "\n".join(step.get("run", "") for step in self.job["steps"])
        for forbidden in ("-derivedDataPath", "-allowProvisioningUpdates", "swift test", "xctest.sh", "simctl", "gh release", "git push"):
            self.assertNotIn(forbidden, scripts)
        self.assertEqual(self.job["env"]["SCHEME"], "Reader-Fork-Dev")

    def test_cache_only_dependencies_and_require_artifacts(self):
        cache = self.steps["Cache SwiftPM dependencies only"]["with"]
        self.assertEqual(cache["path"], "${{ env.SOURCE_PACKAGES }}")
        self.assertIn("Package.resolved", cache["key"])
        self.assertIn("steps.toolchain.outputs.build", cache["key"])
        output = self.steps["Upload unsigned IPA"]
        self.assertNotIn("if", output, "失败时不能上传部分IPA作为成功产物")
        self.assertEqual(output["with"]["if-no-files-found"], "error")
        self.assertEqual(output["with"]["retention-days"], 14)
        self.assertIn("unsigned.ipa.sha256", output["with"]["path"])
        self.assertEqual(self.steps["Upload build failure diagnostics"]["if"], "failure()")

    def probe_toolchain(self, swift, sdk, build="17F113"):
        script = self.steps["Check selected toolchain"]["run"]
        python = re.search(r"python3 - <<'PY'\n(.*?)\nPY(?:\n|$)", script, re.S).group(1)
        with tempfile.TemporaryDirectory(prefix="readerfork-toolchain-test-") as temporary:
            directory = Path(temporary)
            binary = directory / "bin"
            binary.mkdir()
            fake = """#!/usr/bin/env python3
import os,sys
from pathlib import Path
command=Path(sys.argv[0]).name
if command=='xcode-select': print('/fixture/Xcode.app/Contents/Developer')
elif command=='xcodebuild': print('Xcode fixture\\nBuild version '+os.environ['FAKE_BUILD'])
elif sys.argv[1]=='swiftc': print('Apple Swift version '+os.environ['FAKE_SWIFT'])
else: print(os.environ['FAKE_SDK'])
"""
            for name in ("xcode-select", "xcodebuild", "xcrun"):
                path = binary / name
                path.write_text(fake)
                path.chmod(0o755)
            environment = os.environ.copy()
            environment.update(PATH=str(binary) + os.pathsep + environment["PATH"], FAKE_SWIFT=swift,
                               FAKE_SDK=sdk, FAKE_BUILD=build,
                               GITHUB_ENV=str(directory / "env"), GITHUB_OUTPUT=str(directory / "output"))
            result = subprocess.run(["python3", "-c", python], env=environment, text=True, capture_output=True)
            output = (directory / "output").read_text() if (directory / "output").exists() else ""
            return result, output

    def test_accepts_compatible_26_toolchain_without_requiring_27(self):
        for swift, sdk in [("6.2", "26.0"), ("6.3.2", "26.5")]:
            result, output = self.probe_toolchain(swift, sdk)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(output, "build=17F113\n")

    def test_accepts_current_toolchain(self):
        result, output = self.probe_toolchain("6.4.2", "27.2", "27B52")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output, "build=27B52\n")

    def test_rejects_too_old_compiler_and_missing_sdk_api(self):
        for swift, sdk in [("6.0", "26.0"), ("6.2", "18.5"), ("6.4", "27.0")]:
            result, output = self.probe_toolchain(swift, sdk)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output, "")

    def test_new_viewport_api_is_compile_guarded(self):
        source = (ROOT / "Modules/Features/Reader/ReaderViewportReporting.swift").read_text()
        block = re.search(r"#if compiler\(>=6\.4\)(.*?)#endif", source, re.S).group(1)
        self.assertIn("if #available(iOS 27.1", block)
        self.assertIn("ReservedRegion", block)
        self.assertIn(".reservedRegions", block)


if __name__ == "__main__":
    unittest.main()
