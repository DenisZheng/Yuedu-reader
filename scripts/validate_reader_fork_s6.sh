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
  VideoEpisodeStillTests RSSWebResourcePoCTests RSSSchemeResourcePoCTests RSSResourcePipelinePoCTests
)
# 两个真实音频输出时钟断言仍保留在 XCTest 和真机验收中；当前模拟器媒体服务没有启动可用音频单元，
# 干净启动后也稳定复现ready延迟/timebase=0。15a29143真机S6的101项已含本地与HTTP音频实际时钟验证。
# S6模拟器门槛只排除这两项，继续实际运行RSSMediaPoCTests的其他传输、视频与WebKit合同测试。
s6media=(
  testHTTPRangeHEADAndAuthenticationFixture testMP4ActuallySeeksAndAdvances
  testHLSActuallyLoadsSegmentsSeeksAndAdvances
  testExistingHeaderOptionCrossHostRedirectBoundary
  testWebKitMainDocumentHeaderDoesNotAuthenticateSubresources
  testWebKitCrossOriginFetchEnforcesCORSWithoutLeakingMainHeaders
)
YUEDU_EVIDENCE_DIR="$EVIDENCE/s5" bash scripts/validate_reader_fork_s5.sh
args=()
for suite in "${s6[@]}"; do args+=("-only-testing:yuedu appTests/$suite"); done
for test in "${s6media[@]}"; do args+=("-only-testing:yuedu appTests/RSSMediaPoCTests/$test"); done
bash scripts/xctest.sh -l "$EVIDENCE/s6.log" -- -resultBundlePath "$EVIDENCE/s6.xcresult" "${args[@]}"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/s6.xcresult" --format json > "$EVIDENCE/s6-summary.json"
xcrun xcresulttool get test-results tests --path "$EVIDENCE/s6.xcresult" --format json > "$EVIDENCE/s6-tests.json"
python3 - "$EVIDENCE/s6-summary.json" "$EVIDENCE/s6-tests.json" "${s6[@]}" -- "${s6media[@]}" <<'PY'
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
            if identifier: executed[identifier]=node.get("result")
        for child in node.get("children",[]):walk(child)
    elif isinstance(node,list):
        for child in node:walk(child)
walk(tree["testNodes"])
separator=sys.argv.index("--")
suites=sys.argv[3:separator]
media={f"RSSMediaPoCTests/{name}()" for name in sys.argv[separator+1:]}
for suite in suites:
    cases=[(key,result) for key,result in executed.items() if key.startswith(suite+"/")]
    assert cases and all(result=="Passed" for _,result in cases),(suite,cases)
for case in media:
    assert executed.get(case)=="Passed",(case,executed.get(case))
assert not any(key in executed for key in [
    "RSSMediaPoCTests/testAudioActuallySeeksAndAdvances()",
    "RSSMediaPoCTests/testLocalAudioActuallyAdvances()"]),"模拟器门槛意外执行了音频输出时钟用例"
print("S6专项通过：",summary["totalTestCount"],"项；",len(suites),"个suite及",len(media),"个媒体合同用例全部实际通过")
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
