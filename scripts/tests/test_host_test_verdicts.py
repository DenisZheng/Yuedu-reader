"""宿主测试包装器的退出码合同；模拟 xcrun 输出，不冒充业务测试结果。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ("test_local_diagnostics.sh", "test_rss_notification_authorization.sh")


class HostTestVerdictTests(unittest.TestCase):
    def run_wrapper(self, script, count, exit_code):
        with tempfile.TemporaryDirectory(prefix="readerfork-verdict-") as directory:
            shim = Path(directory) / "xcrun"
            shim.write_text(
                "#!/bin/sh\n"
                'printf "Test run with %s tests in 1 suite passed after 0.001 seconds.\\n" "$FAKE_TEST_COUNT"\n'
                'exit "$FAKE_TEST_EXIT"\n'
            )
            shim.chmod(0o755)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                       DEVELOPER_DIR=directory, FAKE_TEST_COUNT=str(count), FAKE_TEST_EXIT=str(exit_code))
            return subprocess.run(["bash", str(ROOT / "scripts" / script)], env=env,
                                  capture_output=True, text=True, timeout=20).returncode

    def test_zero_tests_never_pass(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                self.assertNotEqual(self.run_wrapper(script, 0, 0), 0)

    def test_success_requires_nonzero_tests(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                self.assertEqual(self.run_wrapper(script, 2, 0), 0)

    def test_nonzero_process_exit_overrides_success_text(self):
        for script in SCRIPTS:
            with self.subTest(script=script):
                self.assertNotEqual(self.run_wrapper(script, 2, 1), 0)


if __name__ == "__main__":
    unittest.main()
