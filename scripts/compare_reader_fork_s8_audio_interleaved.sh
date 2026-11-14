#!/usr/bin/env bash
# #77交错A/B：同一已启动模拟器上交替XCTest/Standalone先行，多轮采样间歇性音频时钟故障，
# 消除原对照"A/B顺序固定、可能预热混杂"的缺口。任一轮失败即停止并保留证据，不重试刷绿。
# 不装手机、不关闭/重置模拟器、不启动用户源/网络；每轮使用新UUID目录，不覆盖历史证据。
#
# 实测：xcodebuild test每次重装App会轮换数据容器UUID，因此容器路径只在每次XCTest之后、
# Standalone启动之前现场解析，探针报告一写出立即复制到宿主证据目录；Standalone先行的轮次
# 两端容器必然不同，比较器用--allow-rotated-container只容忍路径哈希差异，仍要求同一
# bundle、同一输入内容SHA-256和字节数。
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${YUEDU_PACKAGE_DIR:-}" || -n "${YUEDU_WORKSPACE:-}" ]]; then
  echo "S8交错对照拒绝工程覆盖" >&2; exit 2
fi
ROUNDS="${YUEDU_AUDIO_AB_ROUNDS:-3}"
[[ "$ROUNDS" =~ ^[1-5]$ ]] || { echo "轮数须为1-5（有限采样，不是重试）：'$ROUNDS'" >&2; exit 2; }
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
export YUEDU_DEST="${YUEDU_DEST:-$(bash scripts/sim.sh dest)}"
export YUEDU_SCHEME=Reader-Fork-RSS-PoC
EVIDENCE="${YUEDU_EVIDENCE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/readerfork-audio-host-interleaved.XXXXXX")}"
mkdir -p "$EVIDENCE"
[[ ! -e "$EVIDENCE/final.json" && ! -e "$EVIDENCE/build-settings.json" ]] || { echo "拒绝覆盖已有对照证据" >&2; exit 2; }
FIXTURE="Tests/iOS/yuedu appTests/Fixtures/VideoStill/video-still-audio-only.m4a"
[[ -f "$FIXTURE" ]] || { echo "缺少固定m4a fixture：$FIXTURE" >&2; exit 2; }
xcrun simctl list devices --json > "$EVIDENCE/simulators.json"
UDID="$(python3 scripts/verify_reader_fork_s8.py destination "$YUEDU_DEST" "$EVIDENCE/simulators.json")"
python3 - "$UDID" "$EVIDENCE/simulators.json" <<'PY'
import json,sys
inventory=json.load(open(sys.argv[2]))
states=[d['state'] for runtime,devices in inventory['devices'].items() if 'SimRuntime.iOS-' in runtime
        for d in devices if d.get('udid')==sys.argv[1] and d.get('isAvailable') is True]
if states != ['Booted']:
    raise SystemExit('S8交错音频对照只接受一个已启动的iOS Simulator；拒绝自动boot/关机或真机')
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
DEVICE_DATA="/Users/$USER/Library/Developer/CoreSimulator/Devices/$UDID/data/Containers/Data/Application"
CACHE=""
resolve_cache() { # xcodebuild test会轮换容器；只在调用当下解析，绝不缓存复用。
  local container
  container="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
  CACHE="$container/Library/Caches"
}

PROBE_LAUNCHED=false
cleanup_probe() {
  if [[ "$PROBE_LAUNCHED" == true ]]; then
    xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1 || true
  fi
}
trap cleanup_probe EXIT

run_xctest() { # $1=run_id $2=round_dir；结束后立即把报告复制到宿主证据目录。
  local run_id="$1" round_dir="$2" status=0
  TEST_RUNNER_RSS_AUDIO_HOST_RUN_ID="$run_id" \
    bash scripts/xctest.sh -l "$round_dir/xctest.log" -- \
    -resultBundlePath "$round_dir/host-ab.xcresult" \
    -only-testing:'yuedu appTests/RSSAudioHostComparisonTests' || status=$?
  xcrun xcresulttool get test-results summary --path "$round_dir/host-ab.xcresult" --format json > "$round_dir/xctest-summary.json"
  xcrun xcresulttool get test-results tests --path "$round_dir/host-ab.xcresult" --format json > "$round_dir/xctest-tests.json"
  python3 - "$round_dir/xctest-summary.json" "$round_dir/xctest-tests.json" "$round_dir/xctest.log" "$status" <<'PY'
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
 raise SystemExit('本轮XCTest对照未精确通过；交错采样停止，证据保留')
if '** TEST SUCCEEDED **' not in log or '** TEST FAILED **' in log: raise SystemExit('缺少XCTest最终通过结论')
PY
  resolve_cache
  cp "$CACHE/readerfork-audio-host-$run_id/xctest.json" "$round_dir/xctest.json"
}

run_standalone() { # $1=run_id $2=round_dir $3=first(true时预置fixture目录)；报告一写出立即复制到宿主。
  local run_id="$1" round_dir="$2" first="$3"
  resolve_cache
  local run_dir="$CACHE/readerfork-audio-host-$run_id"
  if [[ "$first" == true ]]; then
    python3 - "$FIXTURE" "$run_dir" <<'PY'
from pathlib import Path
import hashlib,shutil,sys
fixture=Path(sys.argv[1]).resolve(); run=Path(sys.argv[2]).resolve()
if run.exists(): raise SystemExit('拒绝复用已存在的本轮目录')
run.mkdir(parents=True)
target=run/'sample.m4a'
shutil.copyfile(fixture,target)
a=fixture.read_bytes(); b=target.read_bytes()
if not (0<len(b)<=1048576) or hashlib.sha256(a).digest()!=hashlib.sha256(b).digest():
    raise SystemExit('预置fixture与源文件不一致')
PY
  fi
  # 不在有未完成XCTest/App流程时强制结束；仅启动同一隔离PoC宿主。
  if xcrun simctl spawn "$UDID" launchctl list | grep -Fq "$BUNDLE_ID"; then
    echo "模拟器中同bundle仍有运行任务；为保护现有进程，停止本轮Standalone对照" >&2; exit 1
  fi
  SIMCTL_CHILD_RSS_AUDIO_HOST_RUN_ID="$run_id" xcrun simctl launch "$UDID" "$BUNDLE_ID" \
    -rss-poc-isolated-host -rss-audio-host-comparison > "$round_dir/standalone.log" 2>&1
  PROBE_LAUNCHED=true
  # 探针内部最坏路径：等前台5s + ready截止10s + 时钟截止8s + App启动/会话开销，接近30s；
  # 此处只是脚本侧等待探针写出报告的上限，不是音频断言本身；ready10s/时钟8s截止保持不变。
  local waited=0
  while (( waited < 60 )); do
    [[ -s "$run_dir/standalone.json" ]] && break
    sleep 1; waited=$((waited + 1)) # 等待固定探针实际写出的有限报告，不重跑播放器/请求。
  done
  if [[ ! -s "$run_dir/standalone.json" ]]; then
    echo "Standalone 60秒内没有报告；本轮失败，证据保留，不重试" >&2; exit 1
  fi
  cp "$run_dir/standalone.json" "$round_dir/standalone.json"
  # 结束的仅是刚启动的隔离探针App进程；不关闭或重置Simulator。
  xcrun simctl terminate "$UDID" "$BUNDLE_ID"
  PROBE_LAUNCHED=false
}

cleanup_round_dirs() { # $1=run_id $2=round_dir；跨容器按精确UUID名定位，核对宿主证据后只删本轮目录。
  local run_id="$1" round_dir="$2" candidate
  while IFS= read -r candidate; do
    python3 - "$candidate" "$run_id" "$round_dir/xctest.json" "$round_dir/standalone.json" <<'PY'
from pathlib import Path
import json,re,sys,shutil
run=Path(sys.argv[1]).resolve(); rid=sys.argv[2]
if not re.fullmatch(r'[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}',rid): raise SystemExit('拒绝清理无效本轮ID')
if run.parent.name!='Caches' or run.name!='readerfork-audio-host-'+rid: raise SystemExit('拒绝清理精确缓存目录之外的路径')
if not (run/'sample.m4a').is_file(): raise SystemExit('本轮目录缺少预期输入，保留待查')
for name, host_copy in (('xctest.json',sys.argv[3]),('standalone.json',sys.argv[4])):
    probe=run/name
    if probe.is_file():
        if json.loads(probe.read_text())!=json.loads(Path(host_copy).read_text()):
            raise SystemExit('容器内报告与宿主证据不一致，保留待查')
shutil.rmtree(run)
PY
  done < <(find "$DEVICE_DATA" -mindepth 4 -maxdepth 4 -type d -name "readerfork-audio-host-$run_id" 2>/dev/null)
}

echo "交错A/B开始：rounds=$ROUNDS evidence=$EVIDENCE"
for round in $(seq 1 "$ROUNDS"); do
  round_dir="$EVIDENCE/round-$round"
  mkdir -p "$round_dir"
  run_id="$(python3 -c 'import uuid; print(uuid.uuid4())')"
  # 奇数轮XCTest先行、偶数轮Standalone先行：同一文件同一App构建，只交替起始宿主。
  if (( round % 2 == 1 )); then first=xctest; else first=standalone; fi
  echo "round $round/$ROUNDS first=$first run_id=$run_id"
  if [[ "$first" == xctest ]]; then
    run_xctest "$run_id" "$round_dir"
    run_standalone "$run_id" "$round_dir" false
    rotation_flag=""
  else
    run_standalone "$run_id" "$round_dir" true
    run_xctest "$run_id" "$round_dir"
    # xctest重装App后两端容器必然不同；只容忍路径差异，内容身份仍强校验。
    rotation_flag="--allow-rotated-container"
  fi
  python3 scripts/compare_reader_fork_s8_audio.py "$round_dir/xctest.json" "$round_dir/standalone.json" \
    $rotation_flag | tee "$round_dir/comparison.json"
  python3 - "$round_dir/comparison.json" <<'PY'
import json,sys
comparison=json.load(open(sys.argv[1]))
for host in ('xctest','standalone'):
    if not comparison[host]['ready'] or not comparison[host]['advanced']:
        raise SystemExit('本轮有音频未ready/未推进；交错采样停止并保留证据，不重试')
PY
  cleanup_round_dirs "$run_id" "$round_dir"
done
python3 - "$EVIDENCE" "$ROUNDS" <<'PY'
import json,sys
from pathlib import Path
evidence=Path(sys.argv[1]); rounds=int(sys.argv[2])
rows=[]
for r in range(1,rounds+1):
    comparison=json.loads((evidence/f'round-{r}'/'comparison.json').read_text())
    rows.append({'round':r,'firstHost':'xctest' if r%2==1 else 'standalone',
        'containerRotated':comparison.get('containerRotated',False),
        'xctestElapsedMs':comparison['xctest']['elapsedMs'],'standaloneElapsedMs':comparison['standalone']['elapsedMs'],
        'xctestReady':comparison['xctest']['ready'],'standaloneReady':comparison['standalone']['ready'],
        'xctestAdvanced':comparison['xctest']['advanced'],'standaloneAdvanced':comparison['standalone']['advanced']})
result={'rounds':rows,'allRoundsPassed':True,'stageAccepted':False}
print(json.dumps(result,ensure_ascii=False,sort_keys=True))
(evidence/'final.json').write_text(json.dumps(result,ensure_ascii=False,sort_keys=True))
PY
echo "交错A/B全部通过（仅本轮采样，不证明永久修复）；证据留在${EVIDENCE}。stageAccepted=false。"
