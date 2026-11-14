#!/usr/bin/env python3
"""验证S8 App/XCTest音频对照的输入、宿主和非音频状态边界；不判定音频是否必须通过。"""
import json
from pathlib import Path
import sys

FIELDS = ("host", "frameworkLoaded", "bundleIdentifierSHA256", "containerPathSHA256",
          "inputSHA256", "inputPathSHA256", "inputBytes", "applicationState", "readyWithinDeadline",
          "readyStatusAtDeadline", "advancedWithinDeadline", "cancelled", "elapsedMs", "playerStatus",
          "itemStatus", "hasError", "position", "duration", "rate", "timeControl", "timebaseRate",
          "effectiveRate", "likelyToKeepUp", "bufferEmpty", "outputSuppressed", "muted", "volume",
          "sourceClockOverridden", "category", "mode", "sampleRate", "outputTypes")


def verify(xctest, standalone, allow_rotated_container=False):
    for host, report, expected_framework in (("xctest", xctest, True), ("standalone", standalone, False)):
        if set(report) != set(FIELDS):
            raise ValueError(f"{host}: report字段不匹配")
        if report["host"] != host or report["frameworkLoaded"] is not expected_framework:
            raise ValueError(f"{host}: 实际宿主身份不匹配")
        if report["applicationState"] != 0 or report["cancelled"]:
            raise ValueError(f"{host}: App未在有效前台完成探针")
        if report["hasError"] or report["itemStatus"] != 1:
            raise ValueError(f"{host}: AVPlayerItem没有形成可比较的ready状态")
        if not report["inputSHA256"] or report["inputBytes"] <= 0:
            raise ValueError(f"{host}: 输入摘要无效")
    # 内容身份任何模式都不放宽：同一bundle、同一输入字节、同一字节数。
    for key in ("bundleIdentifierSHA256", "inputSHA256", "inputBytes"):
        if xctest[key] != standalone[key]:
            raise ValueError(f"对照未固定同一App与同一实际输入：{key}")
    rotated = False
    for key in ("containerPathSHA256", "inputPathSHA256"):
        if xctest[key] != standalone[key]:
            # xcodebuild test每次重装App会轮换数据容器UUID。仅交错脚本standalone先行轮
            # 允许在显式标志下容忍路径差异；内容身份已在上方校验，不接受其他松动。
            if not allow_rotated_container:
                raise ValueError(f"对照未固定同一App容器与同一实际输入：{key}")
            rotated = True
    return {
        "comparisonValid": True,
        "sameInstalledApp": True,
        "sameContainer": not rotated,
        "containerRotated": rotated,
        "sameExactInputPathAndBytes": not rotated,
        "sameExactInputBytes": True,
        "xctest": {"ready": xctest["readyWithinDeadline"], "advanced": xctest["advancedWithinDeadline"],
                   "elapsedMs": xctest["elapsedMs"], "position": xctest["position"],
                   "timebaseRate": xctest["timebaseRate"], "effectiveRate": xctest["effectiveRate"]},
        "standalone": {"ready": standalone["readyWithinDeadline"], "advanced": standalone["advancedWithinDeadline"],
                       "elapsedMs": standalone["elapsedMs"], "position": standalone["position"],
                       "timebaseRate": standalone["timebaseRate"], "effectiveRate": standalone["effectiveRate"]},
        "outcomesMatch": (xctest["readyWithinDeadline"], xctest["advancedWithinDeadline"])
                          == (standalone["readyWithinDeadline"], standalone["advancedWithinDeadline"]),
    }


def main(argv):
    allow_rotated = False
    paths = []
    for arg in argv:
        if arg == "--allow-rotated-container":
            allow_rotated = True
        else:
            paths.append(arg)
    if len(paths) != 2:
        raise ValueError("需要xctest.json和standalone.json")
    result = verify(*(json.loads(Path(path).read_text()) for path in paths),
                    allow_rotated_container=allow_rotated)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, OSError, json.JSONDecodeError) as error:
        print(f"音频宿主对照拒绝：{error}", file=sys.stderr)
        raise SystemExit(1)
