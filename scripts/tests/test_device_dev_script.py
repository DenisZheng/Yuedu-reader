"""验证真机开发脚本生成的xcconfig路径；不调用编译、签名或设备安装。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class DeviceDevScriptTests(unittest.TestCase):
    def test_trailing_temp_slash_does_not_become_xcconfig_comment(self):
        script = (ROOT / "scripts/device_dev_test.sh").read_text()
        prefix = script.split("\nxcodebuild -project", 1)[0]
        self.assertNotIn("xcodebuild", prefix)
        with tempfile.TemporaryDirectory(prefix="readerfork-device-path-") as temporary:
            env = os.environ.copy()
            env.pop("READER_FORK_DEVICE_WORK", None)
            env.update(TMPDIR=temporary + "/", READER_FORK_TEAM="fixture-team",
                       READER_FORK_DEVICE="fixture-device", DEVELOPER_DIR="fixture-xcode")
            subprocess.run(["bash", "-c", prefix], cwd=ROOT, env=env, check=True)
            config = Path(temporary) / "readerfork-device/device.xcconfig"
            line = next(line for line in config.read_text().splitlines()
                        if line.startswith("CODE_SIGN_ENTITLEMENTS ="))
            # xcconfig把双斜线解释为注释，不能把临时路径截成T目录。
            actual = line.split("=", 1)[1].strip().split("//", 1)[0]
            expected = str((config.parent / "empty.entitlements").resolve())
            self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
