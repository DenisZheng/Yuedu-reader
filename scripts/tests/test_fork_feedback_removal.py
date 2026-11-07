"""S0 云端反馈移除的静态防复活检查；不是 App/UI 或网络行为验收。"""
import plistlib
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ForkFeedbackRemovalTests(unittest.TestCase):
    def test_retired_clients_are_removed(self):
        for directory in ("Modules/Services/Feedback", "Modules/Features/Feedback"):
            self.assertEqual(list((ROOT / directory).glob("*.swift")), [])
        self.assertFalse((ROOT / "Modules/Services/Diagnostics/DiagnosticReportUploader.swift").exists())

    def test_no_remaining_feedback_callers_or_apns_registration(self):
        forbidden = re.compile(
            r"\b(?:FeedbackService|FeedbackCenterView|FeedbackScreenshotPrompt|"
            r"FeedbackPushRegistration|FeedbackNotificationPresenter|DiagnosticReportUploader|"
            r"registerForRemoteNotifications|didRegisterForRemoteNotificationsWithDeviceToken)\b"
        )
        for directory in ("Modules", "Targets"):
            for path in (ROOT / directory).rglob("*.swift"):
                self.assertIsNone(forbidden.search(path.read_text()), str(path.relative_to(ROOT)))

    def test_notification_start_only_initializes_local_delivery(self):
        source = (ROOT / "Modules/Services/RSS/RSSNotificationManager.swift").read_text()
        start = source.split("func start(", 1)[1].split("// MARK: - Badge", 1)[0]
        self.assertNotIn("requestAuthorization", start)
        self.assertIn("registerCategories()", start)
        self.assertIn("UNNotificationRequest(", source)
        self.assertIn("handleNotificationAction(", source)

    def test_push_entitlement_is_removed_but_icloud_and_groups_remain(self):
        with (ROOT / "Resources/Yuedu-Reader.entitlements").open("rb") as handle:
            entitlements = plistlib.load(handle)
        self.assertNotIn("aps-environment", entitlements)
        self.assertTrue(entitlements["com.apple.developer.icloud-container-identifiers"])
        self.assertTrue(entitlements["com.apple.security.application-groups"])

    def test_diagnostics_is_reachable_with_only_local_export(self):
        settings = (ROOT / "Modules/Features/Settings/ProfileView.swift").read_text()
        diagnostics = (ROOT / "Modules/Features/Settings/DiagnosticsView.swift").read_text()
        self.assertIn('accessibilityIdentifier("settings_diagnostics")', settings)
        self.assertIn("ShareLink(item: exportBundle", diagnostics)
        self.assertNotIn("diagnostics_send_button", diagnostics)
        self.assertNotIn("sendReport(", diagnostics)


if __name__ == "__main__":
    unittest.main()
