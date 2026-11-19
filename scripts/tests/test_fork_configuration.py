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


def target_settings(objects, name):
    target, = (item for item in objects.values() if item.get("isa") == "PBXNativeTarget" and item["name"] == name)
    configurations = objects[target["buildConfigurationList"]]["buildConfigurations"]
    return {objects[key]["name"]: objects[key]["buildSettings"] for key in configurations}


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

    def test_paused_icloud_has_no_launch_access(self):
        manager = (ROOT / "Modules/Services/iCloud/ICloudSyncManager.swift").read_text()
        self.assertRegex(manager, r"static var isConfigured: Bool\s*\{\s*false\s*\}")
        app = (ROOT / "Targets/Yuedu/SharedApp/yuedu_appApp.swift").read_text()
        self.assertIn("if ICloudSyncManager.isConfigured, let syncReason", app)
        self.assertIn("if ICloudSyncManager.isConfigured {", app)
        self.assertIn("ChapterUpdater.refreshAll", app)
        self.assertIn("WebDAVManager.shared.bind", app)
        backup = (ROOT / "Modules/Features/Settings/BackupSyncView.swift").read_text()
        self.assertNotIn("ICloudSyncManager", backup)
        self.assertNotIn("ICloudSyncView()", backup)

    def test_shared_container_is_isolated_without_icloud_permission(self):
        expected_group = ["group.dev.denis.readerfork.dev"]
        for name in ("Resources/Yuedu-Reader.entitlements", "Widget/Yuedu-Reader-Widget.entitlements",
                     "ShareExtension/Yuedu-Reader-ShareExtension.entitlements"):
            with (ROOT / name).open("rb") as handle:
                values = plistlib.load(handle)
            self.assertEqual(values["com.apple.security.application-groups"], expected_group)
            self.assertNotIn("aps-environment", values)
            self.assertNotIn("com.apple.developer.applesignin", values)
            self.assertNotIn("com.apple.developer.icloud-container-identifiers", values)
            self.assertNotIn("com.apple.developer.icloud-services", values)
        for base in ("Modules", "Targets", "Widget", "ShareExtension"):
            for path in (ROOT / base).rglob("*.swift"):
                self.assertNotIn('"group.com.zhangruilin.yuedureader"', path.read_text(), str(path))
                self.assertNotIn('"iCloud.com.zhangruilin.yuedureader"', path.read_text(), str(path))

    def test_legadopro_display_name_in_both_configurations(self):
        objects = project_objects((ROOT / "Yuedu-Reader.xcodeproj/project.pbxproj").read_bytes())
        main_settings = target_settings(objects, "yuedu app")
        self.assertEqual(set(main_settings), {"Debug", "Release"})
        self.assertTrue(all(s["INFOPLIST_KEY_CFBundleDisplayName"] == "LegadoPro" for s in main_settings.values()))
        for lang in ("zh-Hans", "zh-Hant", "en", "ja", "ko"):
            file = ROOT / "Resources" / (lang + ".lproj") / "InfoPlist.strings"
            values = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", str(file)]))
            self.assertEqual(values["CFBundleDisplayName"], "LegadoPro")

    def test_release_bundle_ids_are_distinct_from_development(self):
        objects = project_objects((ROOT / "Yuedu-Reader.xcodeproj/project.pbxproj").read_bytes())
        debug = "dev.denis.readerfork.dev"
        release = "com.deniszheng.legadopro"
        for name, suffix, embedded in [
            ("yuedu app", "", True),
            ("Yuedu-Reader Widget", ".widget", True),
            ("Yuedu-Reader ShareExtension", ".shareextension", True),
            ("yuedu appTests", ".tests", False),
            ("yuedu appUITests", ".uitests", False),
        ]:
            with self.subTest(target=name):
                settings = target_settings(objects, name)
                self.assertEqual({config: value["PRODUCT_BUNDLE_IDENTIFIER"] for config, value in settings.items()},
                                 {"Debug": debug + suffix, "Release": (release if embedded else debug) + suffix})
        for item in objects.values():
            settings = item.get("buildSettings", {})
            if "DEVELOPMENT_TEAM" in settings:
                self.assertEqual(settings["DEVELOPMENT_TEAM"], "")

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
