#!/bin/bash
# S7入口/源管理/调试/WebDAV门槛：S6门槛（含S5回归）+ S7单元与UI。只用合成fixture与内存WebDAV。
# 真实WebDAV服务、真人VoiceOver使用、iOS17弹层时序不在此脚本覆盖范围，必须另记为未验证。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-Dev
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-s7-acceptance.XXXXXX")}"
mkdir -p "$EVIDENCE"
s7=(
  RootTabCustomizationTests OnboardingTests OnboardingVoiceOverTests AppearanceThemeWriteBackTests
  RSSSourceManagementTests WebDAVVersionedBackupTests RSSWebDAVBackupTests RSSS7AccessibilityTests
)
s7ui=(ForkRootTabsUITests RootTabNavigationOwnershipUITests LibraryTabUITests RSSHomeSwipeActionsUITests PublicLibrarySearchTabUITests RSSImportUITests)
YUEDU_EVIDENCE_DIR="$EVIDENCE/s6" bash scripts/validate_reader_fork_s6.sh
args=()
for suite in "${s7[@]}"; do args+=("-only-testing:yuedu appTests/$suite"); done
for suite in "${s7ui[@]}"; do args+=("-only-testing:yuedu appUITests/$suite"); done
bash scripts/xctest.sh -l "$EVIDENCE/s7.log" -- -resultBundlePath "$EVIDENCE/s7.xcresult" "${args[@]}"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/s7.xcresult" --format json > "$EVIDENCE/s7-summary.json"
xcrun xcresulttool get test-results tests --path "$EVIDENCE/s7.xcresult" --format json > "$EVIDENCE/s7-tests.json"
python3 - "$EVIDENCE/s7-summary.json" "$EVIDENCE/s7-tests.json" "${s7[@]}" "${s7ui[@]}" <<'PY'
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
    assert executed.get(suite),f"未执行S7 suite: {suite}"
    assert all(r=="Passed" for r in executed[suite]),(suite,executed[suite])
print("S7专项通过：",summary["totalTestCount"],"项，",len(sys.argv)-3,"个suite全部实际执行")
PY
echo "证据：$EVIDENCE"
