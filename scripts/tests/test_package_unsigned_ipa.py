"""未签名IPA打包合同；合成archive只验证包装，不冒充Xcode真机编译。"""
import hashlib
import importlib.util
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("package_unsigned_ipa", ROOT / "scripts/package_unsigned_ipa.py")
PACKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PACKER)


class UnsignedIPAPackagingTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="readerfork-ipa-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.archive = self.root / "ReaderFork.xcarchive"
        self.output = self.root / "output"
        self.app = self.archive / "Products/Applications/YueduReader.app"
        self.make_bundle(self.app, PACKER.BUNDLE_ID)
        for suffix in ("widget", "shareextension"):
            self.make_bundle(self.app / "PlugIns" / (suffix + ".appex"), PACKER.BUNDLE_ID + "." + suffix)

    def make_bundle(self, path, bundle_id, platform="iPhoneOS"):
        path.mkdir(parents=True)
        with (path / "Info.plist").open("wb") as file:
            plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleSupportedPlatforms": [platform],
                          "CFBundleExecutable": "Executable"}, file)
        executable = path / "Executable"
        executable.write_bytes(b"synthetic packaging fixture, not a Mach-O")
        executable.chmod(0o755)

    def change_info(self, path, **values):
        info_path = path / "Info.plist"
        with info_path.open("rb") as file:
            info = plistlib.load(file)
        info.update(values)
        with info_path.open("wb") as file:
            plistlib.dump(info, file)

    def test_payload_checksum_extensions_and_symlink_are_preserved(self):
        (self.app / "ExecutableAlias").symlink_to("Executable")
        ipa = PACKER.package(self.archive, self.output)
        self.assertEqual(ipa.name, PACKER.IPA_NAME)
        self.assertTrue((self.app / "Executable").exists(), "不能移动或删除原archive")
        with zipfile.ZipFile(ipa) as zipped:
            names = set(zipped.namelist())
            prefix = "Payload/YueduReader.app/"
            self.assertIn(prefix + "Info.plist", names)
            self.assertIn(prefix + "PlugIns/widget.appex/Info.plist", names)
            self.assertIn(prefix + "PlugIns/shareextension.appex/Info.plist", names)
            self.assertTrue(all(name.startswith("Payload/") for name in names))
            self.assertTrue((zipped.getinfo(prefix + "Executable").external_attr >> 16) & stat.S_IXUSR)
            link = zipped.getinfo(prefix + "ExecutableAlias")
            self.assertTrue(stat.S_ISLNK(link.external_attr >> 16))
            self.assertEqual(zipped.read(link), b"Executable")
        checksum = (self.output / (PACKER.IPA_NAME + ".sha256")).read_text()
        self.assertEqual(checksum, hashlib.sha256(ipa.read_bytes()).hexdigest() + "  " + PACKER.IPA_NAME + "\n")
        self.assertEqual(len(list(self.output.iterdir())), 2)

    def test_simulator_app_is_rejected(self):
        self.change_info(self.app, CFBundleSupportedPlatforms=["iPhoneSimulator"])
        with self.assertRaisesRegex(ValueError, "模拟器"):
            PACKER.package(self.archive, self.output)

    def test_upstream_bundle_id_is_rejected(self):
        self.change_info(self.app, CFBundleIdentifier="com.example.upstream")
        with self.assertRaisesRegex(ValueError, "Fork Bundle ID"):
            PACKER.package(self.archive, self.output)

    def test_missing_executable_is_rejected(self):
        (self.app / "Executable").unlink()
        with self.assertRaisesRegex(ValueError, "可执行文件"):
            PACKER.package(self.archive, self.output)

    def test_extension_identity_or_platform_mismatch_is_rejected(self):
        extension = self.app / "PlugIns/widget.appex"
        self.change_info(extension, CFBundleIdentifier="com.example.widget")
        with self.assertRaisesRegex(ValueError, "其他扩展"):
            PACKER.package(self.archive, self.output)
        self.change_info(extension, CFBundleIdentifier=PACKER.BUNDLE_ID + ".widget", CFBundleSupportedPlatforms=["iPhoneSimulator"])
        with self.assertRaisesRegex(ValueError, "模拟器"):
            PACKER.package(self.archive, self.output)

    def test_missing_extension_is_rejected(self):
        (self.app / "PlugIns/widget.appex").rename(self.app / "PlugIns/widget.disabled")
        with self.assertRaisesRegex(ValueError, "缺少Fork"):
            PACKER.package(self.archive, self.output)

    def test_missing_or_ambiguous_main_app_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "一个主App"):
            PACKER.package(self.root / "missing", self.output)
        self.make_bundle(self.archive / "Products/Applications/Extra.app", PACKER.BUNDLE_ID)
        with self.assertRaisesRegex(ValueError, "一个主App"):
            PACKER.package(self.archive, self.output)

    def test_existing_ipa_is_not_overwritten(self):
        ipa = PACKER.package(self.archive, self.output)
        previous = ipa.read_bytes()
        with self.assertRaises(FileExistsError):
            PACKER.package(self.archive, self.output)
        self.assertEqual(ipa.read_bytes(), previous)


if __name__ == "__main__":
    unittest.main()
