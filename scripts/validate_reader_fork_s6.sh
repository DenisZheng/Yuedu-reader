#!/bin/bash
# S6规则网页/资源/动作/媒体闭环门槛：S6专项 + S1媒体PoC + S5回归。只用合成fixture与loopback，不执行私人源包。
# 真机、iOS17、DRM、真人登录与正式签名不在此脚本覆盖范围，必须另记为未验证。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-Dev
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-s6-acceptance.XXXXXX")}"
mkdir -p "$EVIDENCE"
s6=(
  RSSRuleWebTests RSSWebRequestTests RSSWebInvalidationTests RSSWebNavigationTests
  RSSCookieAuthorizationTests RSSImageServiceTests RSSWebImageTests
  RSSWebActionRouterTests RSSLoginServiceTests RSSNativeWebFlowTests
  RSSMediaPlaybackTests RSSMediaResourceSessionTests RSSWebDocumentCacheTests RSSS6VisualAccessibilityTests
  RSSWebViewportTests
  RSSMediaPoCTests VideoEpisodeStillTests RSSWebResourcePoCTests RSSSchemeResourcePoCTests RSSResourcePipelinePoCTests
)
YUEDU_EVIDENCE_DIR="$EVIDENCE/s5" bash scripts/validate_reader_fork_s5.sh
args=()
for suite in "${s6[@]}"; do args+=("-only-testing:yuedu appTests/$suite"); done
bash scripts/xctest.sh -l "$EVIDENCE/s6.log" -- -resultBundlePath "$EVIDENCE/s6.xcresult" "${args[@]}"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/s6.xcresult" --format json > "$EVIDENCE/s6-summary.json"
xcrun xcresulttool get test-results tests --path "$EVIDENCE/s6.xcresult" --format json > "$EVIDENCE/s6-tests.json"
python3 - "$EVIDENCE/s6-summary.json" "$EVIDENCE/s6-tests.json" "${s6[@]}" <<'PY'
import json,sys
summary=json.load(open(sys.argv[1]))
assert summary["result"]=="Passed",summary["result"]
assert summary["failedTests"]==0 and summary["skippedTests"]==0,summary
tree=json.load(open(sys.argv[2]))
executed={}
def walk(node):
    if isinstance(node,dict):
        if node.get("nodeType")=="Test Case":
            identifier=node.get("nodeIdentifier","")
            if identifier: executed.setdefault(identifier.split("/",1)[0],[]).append(node.get("result"))
        for child in node.get("children",[]):walk(child)
    elif isinstance(node,list):
        for child in node:walk(child)
walk(tree["testNodes"])
for suite in sys.argv[3:]:
    assert executed.get(suite),f"未执行S6 suite: {suite}"
    assert all(r=="Passed" for r in executed[suite]),(suite,executed[suite])
print("S6专项通过：",summary["totalTestCount"],"项，",len(sys.argv)-3,"个suite全部实际执行")
PY
bash scripts/xctest.sh -l "$EVIDENCE/s6-ui.log" -- -resultBundlePath "$EVIDENCE/s6-ui.xcresult" \
  -only-testing:'yuedu appUITests/RSSWebDisplayUITests'
xcrun xcresulttool get test-results summary --path "$EVIDENCE/s6-ui.xcresult" --format json > "$EVIDENCE/s6-ui-summary.json"
xcrun xcresulttool get test-results tests --path "$EVIDENCE/s6-ui.xcresult" --format json > "$EVIDENCE/s6-ui-tests.json"
python3 - "$EVIDENCE/s6-ui-summary.json" "$EVIDENCE/s6-ui-tests.json" <<'PY'
import json,sys
summary=json.load(open(sys.argv[1]))
assert summary["result"]=="Passed" and summary["failedTests"]==0 and summary["skippedTests"]==0,summary
expected={"RSSWebDisplayUITests/"+name+"()" for name in [
    "testTwoPanelsCanCloseAndPageKeepsState", "testNativeCloseStaysReachableAtAX5AndDark", "testLandscapeClosePanelsAndReset"]}
executed={}
def walk(node):
    if isinstance(node,dict):
        if node.get("nodeType")=="Test Case": executed[node.get("nodeIdentifier","")]=node.get("result")
        for child in node.get("children",[]):walk(child)
    elif isinstance(node,list):
        for child in node:walk(child)
walk(json.load(open(sys.argv[2]))["testNodes"])
assert set(executed)==expected and all(r=="Passed" for r in executed.values()),executed
assert summary["totalTestCount"]==len(expected),summary
print("S6网页缩放/连续弹层/原生退出/横屏/AX5 UI：3项实际通过")
PY
echo "证据：$EVIDENCE"
