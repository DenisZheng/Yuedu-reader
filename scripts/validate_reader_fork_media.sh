#!/bin/bash
# 正常Dev宿主的平台媒体前置门槛；不是S6生产资源/播放器闭环验收，不执行私人源。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-Dev
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-media-acceptance.XXXXXX")}"
mkdir -p "$EVIDENCE"
# 等待真实系统启动信号，不用固定延迟或失败后自动重试隐藏音频/系统服务未就绪。
if [[ "$YUEDU_DEST" != id=* ]]; then echo '媒体验收请使用sim.sh解析的id目标' >&2; exit 1; fi
xcrun simctl bootstatus "${YUEDU_DEST#id=}" -b > "$EVIDENCE/boot.log"
suites=(RSSMediaPoCTests RSSResourcePipelinePoCTests RSSSchemeResourcePoCTests RSSWebResourcePoCTests VideoEpisodeStillTests)
args=()
for suite in "${suites[@]}"; do args+=("-only-testing:yuedu appTests/$suite"); done
bash scripts/xctest.sh -l "$EVIDENCE/tests.log" -- -resultBundlePath "$EVIDENCE/tests.xcresult" "${args[@]}"
xcrun xcresulttool get test-results summary --path "$EVIDENCE/tests.xcresult" --format json > "$EVIDENCE/summary.json"
xcrun xcresulttool get test-results tests --path "$EVIDENCE/tests.xcresult" --format json > "$EVIDENCE/tests.json"
python3 - "$EVIDENCE/summary.json" "$EVIDENCE/tests.json" "${suites[@]}" <<'PY'
import json,sys
summary=json.load(open(sys.argv[1]))
assert summary['result']=='Passed',summary
assert summary['totalTestCount']>=36,summary
assert summary['failedTests']==0 and summary['skippedTests']==0,summary
tree=json.load(open(sys.argv[2]))
executed={}
cases={}
def walk(node):
    if node.get('nodeType')=='Test Case':
        identifier=node.get('nodeIdentifier','')
        if identifier:
            executed.setdefault(identifier.split('/',1)[0],[]).append(node.get('result'))
            cases[identifier]=node.get('result')
    for child in node.get('children',[]): walk(child)
for node in tree['testNodes']: walk(node)
for suite in sys.argv[3:]:
    assert executed.get(suite),f'未执行suite: {suite}'
    assert all(value=='Passed' for value in executed[suite]),(suite,executed[suite])
for name in ['testLocalAudioActuallyAdvances','testAudioActuallySeeksAndAdvances','testMP4ActuallySeeksAndAdvances','testHLSActuallyLoadsSegmentsSeeksAndAdvances']:
    assert cases.get(f'RSSMediaPoCTests/{name}()')=='Passed',name
print('正常Dev宿主媒体前置通过：',summary['totalTestCount'],'项，所有suite及实际播放用例均执行；不替代S6生产验收')
PY
git diff --check
