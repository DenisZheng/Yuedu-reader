#!/bin/bash
# S0 独立 Fork 的自动验收入口。只跑本阶段相关回归，不代表真机媒体或真实 iCloud 同步。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-Dev
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-s0-acceptance.XXXXXX")}"
mkdir -p "$EVIDENCE"
printf 'evidence: %s\n' "$EVIDENCE"
python3 scripts/tests/test_fork_configuration.py
python3 scripts/tests/test_fork_feedback_removal.py
python3 scripts/tests/test_host_test_verdicts.py
ruby scripts/check_localizations.rb
git diff --check
unit_suites=(
  AuthAndICloudConfigurationTests ICloudSourceSyncConvergenceTests ICloudSyncBlobDecodingTests
  ICloudSyncShadowCommitTests ICloudSyncChangeDetectionTests SyncMergeTests ReadingPositionSyncTests
  ReaderSettingsPublicationTests ReaderPreferencesMarginSyncTests AppearanceThemePresetTests
  AppearanceSlotTabTests TouchZoneConfigTests ReaderTouchZoneEditorModelTests BookSourceImportDeepLinkTests
  OnboardingTests LocalDiagnosticContextTests DiagnosticRedactorTests RSSNotificationAuthorizationTests
  LegadoRSSCompatTests RSSStoreTests RSSBackgroundRefreshTests RSSLinkRouteTests ReaderTextColorOverrideTests
  RootTabCustomizationTests
)
args=()
for suite in "${unit_suites[@]}"; do args+=("-only-testing:yuedu appTests/$suite"); done
for suite in DiagnosticsPageUITests ForkLocalAccessUITests; do args+=("-only-testing:yuedu appUITests/$suite"); done
bash scripts/xctest.sh -l "$EVIDENCE/tests.log" -- -resultBundlePath "$EVIDENCE/tests.xcresult" "${args[@]}"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/tests.xcresult" --format json > "$EVIDENCE/summary.json"
printf 'S0 automated regression completed; device/cloud/manual gates remain in validation.md\n'
