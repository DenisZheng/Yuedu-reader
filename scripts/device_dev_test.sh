#!/bin/bash
# 免费个人团队（Personal Team）真机调试：去掉iCloud/App Group权限，编译时关闭CloudKit容器创建（READER_FORK_NO_ICLOUD）。
# 不修改工程文件、不提交团队ID。用法：
#   READER_FORK_TEAM=<TeamID> READER_FORK_DEVICE=<UDID> bash scripts/device_dev_test.sh [suite ...]
# 未给suite时只编译、安装并启动App。分享扩展/Widget的App Group数据共享与iCloud在此构建中不可用。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
: "${READER_FORK_TEAM:?需要READER_FORK_TEAM}"
: "${READER_FORK_DEVICE:?需要READER_FORK_DEVICE}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-$(bash scripts/sim.sh xcode)}"
WORK="${READER_FORK_DEVICE_WORK:-${TMPDIR:-/tmp}/readerfork-device}"
mkdir -p "$WORK"
cat > "$WORK/empty.entitlements" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
EOF
cat > "$WORK/device.xcconfig" <<EOF
DEVELOPMENT_TEAM = $READER_FORK_TEAM
CODE_SIGN_STYLE = Automatic
CODE_SIGN_ENTITLEMENTS = $WORK/empty.entitlements
SWIFT_ACTIVE_COMPILATION_CONDITIONS = \$(inherited) READER_FORK_NO_ICLOUD
EOF
# 真机签名产物与模拟器DerivedData分开，避免个人签名配置混入日常模拟器构建。
xcodebuild -project Yuedu-Reader.xcodeproj -scheme Reader-Fork-Dev -configuration Debug \
  -destination "id=$READER_FORK_DEVICE" -xcconfig "$WORK/device.xcconfig" -derivedDataPath "$WORK/dd" \
  -allowProvisioningUpdates build-for-testing > "$WORK/build.log" 2>&1 || { grep -E 'error:' "$WORK/build.log" | sort -u; exit 1; }
APP="$(find "$WORK/dd/Build/Products/Debug-iphoneos" -maxdepth 1 -name '*.app' | head -1)"
xcrun devicectl device install app --device "$READER_FORK_DEVICE" "$APP"
xcrun devicectl device process launch --device "$READER_FORK_DEVICE" dev.denis.readerfork.dev
[ "$#" -eq 0 ] && exit 0
args=(); for suite in "$@"; do args+=("-only-testing:yuedu appTests/$suite"); done
RESULT="$WORK/tests-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild test-without-building -xctestrun "$(ls "$WORK"/dd/Build/Products/*.xctestrun | head -1)" \
  -destination "id=$READER_FORK_DEVICE" -resultBundlePath "$RESULT" "${args[@]}" > "$WORK/test.log" 2>&1 || true
xcrun xcresulttool get test-results summary --path "$RESULT" --format json | python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d["result"],"total",d["totalTestCount"],"passed",d["passedTests"],"failed",d["failedTests"],"skipped",d["skippedTests"])
sys.exit(0 if d["result"]=="Passed" and d["totalTestCount"]>0 and d["failedTests"]==0 and d["skippedTests"]==0 else 1)'
echo "证据：$RESULT"
