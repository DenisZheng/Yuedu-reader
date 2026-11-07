"""独立 Fork 的静态装配边界。补充 App/UI 测试，不宣称已验证网络行为。"""
import json
from pathlib import Path
import plistlib
import re
import subprocess
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]


def project_objects(content):
    result = subprocess.run(["plutil", "-convert", "json", "-o", "-", "-"],
                            input=content, capture_output=True, check=True)
    return json.loads(result.stdout)["objects"]


class ForkConfigurationTests(unittest.TestCase):
    def test_no_google_products_resources_or_billing_configuration(self):
        project = (ROOT / "Yuedu-Reader.xcodeproj/project.pbxproj").read_text()
        for retired in ("Firebase", "GoogleSignIn", "GoogleService-Info", "YueduPro.storekit"):
            self.assertNotIn(retired, project)
        pins = json.loads((ROOT / "Yuedu-Reader.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved").read_text())
        for pin in pins["pins"]:
            self.assertNotRegex(pin["identity"], r"firebase|googlesignin|googleappmeasurement|grpc")

    def test_no_account_or_purchase_execution_paths(self):
        pattern = re.compile(
            r"^import (?:Firebase\w*|GoogleSignIn\w*|AppAuth)\b|"
            r"\b(?:SubscriptionStore|FirebaseAuthManager|AccountBackendRouter|FirestoreSyncManager|"
            r"SKPaymentQueue|SKPayment|AppTransaction|PaywallView|isProActive|hasResolvedEntitlements)\b|"
            r"\bTransaction\.(?:currentEntitlements|updates)|\bProduct\.products\(", re.M
        )
        for base in ("Modules", "Targets"):
            for path in (ROOT / base).rglob("*.swift"):
                # 注释中保留历史错误出处，不将其当作可执行调用。
                text = re.sub(r"(?m)^\s*//[^\n]*", "", path.read_text())
                self.assertIsNone(pattern.search(text), str(path.relative_to(ROOT)))

    def test_external_scheme_does_not_compete_with_original_app(self):
        with (ROOT / "Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        schemes = [s for entry in info["CFBundleURLTypes"] for s in entry["CFBundleURLSchemes"]]
        self.assertEqual(schemes, ["readerfork-dev"])
        for key in ("GIDClientID", "GatewayBaseURL", "FirebaseAppDelegateProxyEnabled"):
            self.assertNotIn(key, info)

    def test_shared_container_and_icloud_identity_are_isolated(self):
        expected_group = ["group.dev.denis.readerfork.dev"]
        for name in ("Resources/Yuedu-Reader.entitlements", "Widget/Yuedu-Reader-Widget.entitlements",
                     "ShareExtension/Yuedu-Reader-ShareExtension.entitlements"):
            with (ROOT / name).open("rb") as handle:
                values = plistlib.load(handle)
            self.assertEqual(values["com.apple.security.application-groups"], expected_group)
            self.assertNotIn("aps-environment", values)
            self.assertNotIn("com.apple.developer.applesignin", values)
            if name.startswith("Resources/"):
                self.assertEqual(values["com.apple.developer.icloud-container-identifiers"], ["iCloud.dev.denis.readerfork.dev"])
                self.assertEqual(values["com.apple.developer.icloud-services"], ["CloudKit"])
        for base in ("Modules", "Targets", "Widget", "ShareExtension"):
            for path in (ROOT / base).rglob("*.swift"):
                self.assertNotIn('"group.com.zhangruilin.yuedureader"', path.read_text(), str(path))
                self.assertNotIn('"iCloud.com.zhangruilin.yuedureader"', path.read_text(), str(path))

    def test_bundle_ids_and_signature_do_not_reuse_upstream(self):
        objects = project_objects((ROOT / "Yuedu-Reader.xcodeproj/project.pbxproj").read_bytes())
        ids = set()
        for item in objects.values():
            settings = item.get("buildSettings", {})
            if "PRODUCT_BUNDLE_IDENTIFIER" in settings:
                value = settings["PRODUCT_BUNDLE_IDENTIFIER"]
                self.assertTrue(value.startswith("dev.denis.readerfork.dev"), value)
                ids.add(value)
            if "DEVELOPMENT_TEAM" in settings:
                self.assertEqual(settings["DEVELOPMENT_TEAM"], "")
        self.assertEqual(len(ids), 5)

    def test_language_and_isolation_settings_unchanged(self):
        before = subprocess.check_output(["git", "show", "HEAD:Yuedu-Reader.xcodeproj/project.pbxproj"], cwd=ROOT)
        old = project_objects(before)
        new = project_objects((ROOT / "Yuedu-Reader.xcodeproj/project.pbxproj").read_bytes())
        for key, item in old.items():
            settings = item.get("buildSettings", {})
            for field, value in settings.items():
                if field.startswith(("SWIFT_", "IPHONEOS_DEPLOYMENT_TARGET")):
                    self.assertEqual(new[key]["buildSettings"].get(field), value, f"{key}: {field}")

    def test_local_scheme_has_no_purchase_fixture(self):
        path = ROOT / "Yuedu-Reader.xcodeproj/xcshareddata/xcschemes/Reader-Fork-Dev.xcscheme"
        tree = ET.parse(path)
        self.assertEqual(tree.findall(".//StoreKitConfigurationFileReference"), [])
        self.assertEqual(len(tree.findall(".//TestableReference")), 2)
        self.assertFalse((ROOT / "Configuration/YueduPro.storekit").exists())


if __name__ == "__main__":
    unittest.main()
