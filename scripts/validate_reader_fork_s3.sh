#!/bin/bash
# S3身份、状态、升级、快照及消费者回归。媒体平台门槛仍由S6/S8单独验收。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-Dev
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-s3-acceptance.XXXXXX")}"
mkdir -p "$EVIDENCE"
args=()
for suite in RSSIdentityStateTests RSSWebDAVBackupTests RSSImportServiceTests RSSSourceFidelityTests RSSRealPackImportTests LegadoRSSCompatTests RSSStoreTests RSSBackgroundRefreshTests RSSExportTests RSSPageDecodingTests RSSArticleLinkResolutionTests SubscriptionArticlesSectionTests RSSFlowFixtureTests RSSLinkRouteTests; do
  args+=("-only-testing:yuedu appTests/$suite")
done
args+=("-only-testing:yuedu appTests/RSSUnreadCountTests/countsMatchListedArticles()")
bash scripts/xctest.sh -l "$EVIDENCE/tests.log" -- -resultBundlePath "$EVIDENCE/tests.xcresult" "${args[@]}"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/tests.xcresult" --format json > "$EVIDENCE/summary.json"
python3 - "$EVIDENCE/summary.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
assert result["result"]=="Passed",result["result"]
assert result["totalTestCount"]>=120,result["totalTestCount"]
assert result["failedTests"]==0 and result["skippedTests"]==0,result
print("S3所有选定合同通过：",result["totalTestCount"])
PY
ruby scripts/check_localizations.rb
git diff --check
