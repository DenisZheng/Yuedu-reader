#!/bin/bash
# S1固定输入与平台PoC验收入口。支持边界见media-poc.md；不代表RSS生产功能完成。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-s1-acceptance.XXXXXX")}"
mkdir -p "$EVIDENCE"
printf 'evidence: %s\n' "$EVIDENCE"
args=()
for suite in RSSPoCTestHostTests RSSAlignmentFixtureTests RSSFlowFixtureTests RSSPageDecodingTests RSSMediaPoCTests RSSWebResourcePoCTests RSSSchemeResourcePoCTests RSSResourcePipelinePoCTests VideoEpisodeStillTests; do
  args+=("-only-testing:yuedu appTests/$suite")
done
# 只选无App启动依赖的刷新竞态合同；注册/真实冷启动仍由普通S0 scheme验证。
for test in cancellationStopsRefresh disabledDuringRefresh cancelledRefreshKeepsMergedFeeds; do
  args+=("-only-testing:yuedu appTests/RSSBackgroundRefreshTests/${test}()")
done
# 沿用仓库900秒构建预算；切换设备会重新裁剪资源。各媒体/导航等待仍独立限时。
bash scripts/xctest.sh -l "$EVIDENCE/tests.log" -- -resultBundlePath "$EVIDENCE/tests.xcresult" "${args[@]}"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/tests.xcresult" --format json > "$EVIDENCE/summary.json"
python3 - "$EVIDENCE/summary.json" <<'PY'
import json,sys
result=json.load(open(sys.argv[1]))
assert result["result"]=="Passed", result["result"]
assert result["totalTestCount"]>=54, result["totalTestCount"]
assert result["failedTests"]==0 and result["skippedTests"]==0, "S1关键用例不能失败或跳过"
print("S1固定输入与平台PoC全部执行通过；生产功能仍须S2–S8逐段验收")
PY
git diff --check
