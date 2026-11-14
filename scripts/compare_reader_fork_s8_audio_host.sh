#!/usr/bin/env bash
# 比较隔离App与XCTest，不装手机、不关闭/重置模拟器、不启动用户源/网络。
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${YUEDU_PACKAGE_DIR:-}" || -n "${YUEDU_WORKSPACE:-}" ]]; then
  echo "S8宿主对照拒绝工程覆盖" >&2; exit 2
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
export TEST_RUNNER_RSS_AUDIO_HOST_RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())')"
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-audio-host-ab.XXXXXX")}"
mkdir -p "$EVIDENCE"
[[ ! -e "$EVIDENCE/host-ab.xcresult" && ! -e "$EVIDENCE/original-recheck.xcresult" \
   && ! -e "$EVIDENCE/build-settings.json" ]] || { echo "拒绝覆盖已有对照证据" >&2; exit 2; }
xcrun simctl list devices --json > "$EVIDENCE/simulators.json"
UDID="$(python3 scripts/verify_reader_fork_s8.py destination "$YUEDU_DEST" "$EVIDENCE/simulators.json")"
python3 - "$UDID" "$EVIDENCE/simulators.json" <<'PY'
import json,sys
inventory=json.load(open(sys.argv[2]))
states=[d['state'] for runtime,devices in inventory['devices'].items() if 'SimRuntime.iOS-' in runtime
        for d in devices if d.get('udid')==sys.argv[1] and d.get('isAvailable') is True]
if states != ['Booted']:
    raise SystemExit('S8音频宿主对照只接受一个已启动的iOS Simulator；拒绝自动boot/关机或真机')
PY
xcodebuild -project Yuedu-Reader.xcodeproj -scheme "$YUEDU_SCHEME" -destination "$YUEDU_DEST" \
  -showBuildSettings -json > "$EVIDENCE/build-settings.json"
BUNDLE_ID="$(python3 - "$EVIDENCE/build-settings.json" <<'PY'
import json,sys
entries=json.load(open(sys.argv[1]))
app=[e['buildSettings'] for e in entries if e.get('buildSettings',{}).get('PRODUCT_MODULE_NAME')=='yuedu_app'
     and e.get('buildSettings',{}).get('PRODUCT_TYPE')=='com.apple.product-type.application']
if len(app)!=1 or not app[0].get('PRODUCT_BUNDLE_IDENTIFIER'):
    raise SystemExit('无法唯一确定XCTest实际宿主App')
print(app[0]['PRODUCT_BUNDLE_IDENTIFIER'])
PY
)"
run_id="$TEST_RUNNER_RSS_AUDIO_HOST_RUN_ID"
status=0
bash scripts/xctest.sh -l "$EVIDENCE/xctest.log" -- \
  -resultBundlePath "$EVIDENCE/host-ab.xcresult" \
  -only-testing:'yuedu appTests/RSSAudioHostComparisonTests' || status=$?
xcrun xcresulttool get test-results summary --path "$EVIDENCE/host-ab.xcresult" --format json > "$EVIDENCE/xctest-summary.json"
xcrun xcresulttool get test-results tests --path "$EVIDENCE/host-ab.xcresult" --format json > "$EVIDENCE/xctest-tests.json"
python3 - "$EVIDENCE/xctest-summary.json" "$EVIDENCE/xctest-tests.json" "$EVIDENCE/xctest.log" "$status" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); tree=json.load(open(sys.argv[2])); log=open(sys.argv[3]).read(); status=int(sys.argv[4])
def walk(n):
 if isinstance(n,dict):
  if n.get('nodeType')=='Test Case': yield n.get('nodeIdentifier'),n.get('result')
  for v in n.values(): yield from walk(v)
 elif isinstance(n,list):
  for v in n: yield from walk(v)
cases=list(walk(tree))
expected='RSSAudioHostComparisonTests/testSameAppPlayerAndM4AInputUnderXCTestHost()'
if status or s.get('result')!='Passed' or s.get('failedTests')!=0 or s.get('skippedTests')!=0 or cases!=[(expected,'Passed')]:
 raise SystemExit('XCTest对照未精确通过；不启动Standalone，也不重试')
if '** TEST SUCCEEDED **' not in log or '** TEST FAILED **' in log: raise SystemExit('缺少XCTest最终通过结论')
PY
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
CACHE="$CONTAINER/Library/Caches"
RUN_DIR="$CACHE/readerfork-audio-host-$run_id"
XCTEST_REPORT="$RUN_DIR/xctest.json"
STANDALONE_REPORT="$RUN_DIR/standalone.json"
[[ -f "$XCTEST_REPORT" ]] || { echo "XCTest未在预期App容器写出对照报告，停止" >&2; exit 1; }
# 不在有未完成XCTest/App流程时强制结束；XCTest完成后仅启动同一隔离PoC宿主。
if xcrun simctl spawn "$UDID" launchctl list | grep -Fq "$BUNDLE_ID"; then
  echo "模拟器中同bundle仍有运行任务；为保护现有进程，停止Standalone对照" >&2; exit 1
fi
SIMCTL_CHILD_RSS_AUDIO_HOST_RUN_ID="$run_id" xcrun simctl launch "$UDID" "$BUNDLE_ID" \
  -rss-poc-isolated-host -rss-audio-host-comparison > "$EVIDENCE/standalone.log" 2>&1
PROBE_LAUNCHED=true
cleanup_probe() {
  if [[ "${PROBE_LAUNCHED:-false}" == true ]]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup_probe EXIT
for _ in $(seq 1 35); do
  [[ -s "$STANDALONE_REPORT" ]] && break
  sleep 1 # 等待固定探针实际写出的有限报告，不重跑播放器/请求。
done
if [[ ! -s "$STANDALONE_REPORT" ]]; then
  echo "Standalone 35秒内没有报告；停止，不重试" >&2
  exit 1
fi
cp "$XCTEST_REPORT" "$EVIDENCE/xctest.json"
cp "$STANDALONE_REPORT" "$EVIDENCE/standalone.json"
python3 scripts/compare_reader_fork_s8_audio.py "$EVIDENCE/xctest.json" "$EVIDENCE/standalone.json" \
  | tee "$EVIDENCE/comparison.json"
# 结束的仅是刚启动的隔离探针App进程；不关闭或重置Simulator。
xcrun simctl terminate "$UDID" "$BUNDLE_ID"
PROBE_LAUNCHED=false
trap - EXIT
# 只清理由本轮uuid准确标记、已比对的Caches媒体夹，不碰其他App/源配置/用户数据。
python3 - "$CACHE" "$RUN_DIR" "$run_id" <<'PY'
from pathlib import Path
import json,re,shutil,sys
cache=Path(sys.argv[1]).resolve(); run=Path(sys.argv[2]).resolve(); rid=sys.argv[3]
if not re.fullmatch(r'[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}',rid): raise SystemExit('拒绝清理无效本轮ID')
if run.parent!=cache or run.name!='readerfork-audio-host-'+rid: raise SystemExit('拒绝清理精确缓存目录之外的路径')
a=json.loads((run/'xctest.json').read_text()); b=json.loads((run/'standalone.json').read_text())
if a['host']!='xctest' or b['host']!='standalone' or a['inputSHA256']!=b['inputSHA256'] or a['inputPathSHA256']!=b['inputPathSHA256']:
 raise SystemExit('证据不匹配，保留Caches数据')
shutil.rmtree(run)
PY
# 复跑用户原先的精确音频推进断言；其结果单独记录，不覆盖A/B结论。
original_status=0
bash scripts/xctest.sh -l "$EVIDENCE/original-recheck.log" -- \
  -resultBundlePath "$EVIDENCE/original-recheck.xcresult" \
  -only-testing:'yuedu appTests/RSSMediaPoCTests/testLocalAudioActuallyAdvances' || original_status=$?
xcrun xcresulttool get test-results summary --path "$EVIDENCE/original-recheck.xcresult" --format json > "$EVIDENCE/original-recheck-summary.json"
printf '{"originalXCTestAudioRecheckExit":%s,"comparisonExit":0,"simulator":true,"stageAccepted":false}\n' \
  "$original_status" > "$EVIDENCE/final.json"
python3 - "$EVIDENCE/comparison.json" "$EVIDENCE/original-recheck-summary.json" "$original_status" <<'PY'
import json,sys
comparison=json.load(open(sys.argv[1])); original=json.load(open(sys.argv[2])); status=int(sys.argv[3])
if not comparison['xctest']['ready'] or not comparison['standalone']['ready'] or not comparison['xctest']['advanced'] or not comparison['standalone']['advanced']:
    raise SystemExit('A/B完成但仍有音频未推进；本轮媒体门槛失败，证据保留')
if status or original.get('result')!='Passed' or original.get('failedTests')!=0 or original.get('skippedTests')!=0 or original.get('totalTestCount')!=1:
    raise SystemExit('原始音频推进断言未通过；本轮媒体门槛失败，证据保留')
PY
echo "A/B和原音频断言当前通过；证据留在${EVIDENCE}。stageAccepted=false。"
