#!/usr/bin/env python3
"""S8自动回归的精确集合/控制台验收，不替代人工、实源限制及发布门槛。"""
import json
import sys
from pathlib import Path

CASES = {
    "AnalyzeUrlLogSafetyTests": "templateEvaluationPreservesRequest(restricted:)",
    "RSSCookieAuthorizationTests": "expiredCookieRemovesLegacy() redirectCookieContract() responseCannotPoisonOtherDomain() staleResponseCannotWriteCookie() structuredCookieRetiresLegacy()",
    "RSSImageServiceTests": "errorsAreNotImages() filterParity() imageDecodeAndHeaders()",
    "RSSMediaPlaybackTests": "attachmentMaterialization() backgroundStopsPlayback() expiredSignedURLReResolves() hlsPlaybackPersistsProgress() readerPagePlaysAndRevokes() typedArticleResourceURL()",
    "RSSMediaProgressCaptureTests": "capturesClockBetweenUITicks(exit:) completedSeekResumesClockCapture() loadingClosePreservesResumePosition() seekThenExitPreservesRequestedPosition(exit:)",
    "RSSMediaResourceSessionTests": "capabilityAndClose() manifestCredentialScope() rangeAndHead()",
    "RSSSharedBridgeTests": "metadataAndSession() ruleCallbacks() scopedVariables()",
    "S8AudioRuleContractTests": "fieldPutReadsArticleContext()",
    "S8RepresentativeSourceTests": "testPreScreenedPublicHTMLMediaRuleListPage() testPreScreenedPublicImageSourceRulesParseSyntheticMatchingDOM() testPreScreenedPublicRuleListPageUsesProductionFetcher() testPreScreenedPublicRSSImageCandidateListHasBoundedImageTargets() testPreScreenedPublicRSSImageCandidateListHasBoundedTargets() testPreScreenedPublicTextBookSourceSearch() testPreScreenedPublicXMLFeedUsesProductionFetcher() testPreScreenedRSSAudioResourceAdvancesAndProgressReloads() testPreScreenedRSSListImageDecodesAndStateReloads() testPreScreenedRSSPagingContentAndStateSurviveReload() testReviewedAudioCatalogPolicyRejectsParameterAndOriginChanges() testReviewedB122SearchResponseShapeAudit() testReviewedR146ImageRequiresSystemTrustAndNativeDecode()",
    "S8RequestBoundaryTests": "mediaHeadIsExplicitAndBounded() methodsCredentialsAndBudget() redirectRejectedBeforeNetwork() reviewedRedirectUsesNativeTransport() sessionRedirectDelegateIsNotAnEnforcementBoundary()",
    "S8RestrictedCookieFlowTests": "listArticleAndNativeImage(cookieJar:)",
    "S8TLSFailureMetadataTests": "boundsErrorChain() expiredCertificateCode() rejectsUnapprovedPayload()",
}
NONMEDIA_SUITES = {
    "AnalyzeUrlLogSafetyTests", "RSSSharedBridgeTests",
    "S8RepresentativeSourceTests", "S8TLSFailureMetadataTests", "S8RequestBoundaryTests",
}
# 外部前置条件：客户端没有可修复路径，结果取决于第三方证书链（R146图片：-1202/-9814）。
# 用例保留在源码中可单独运行，但不进入任何模式的通过集；结果里单列，不能读作“已通过”。
EXTERNAL_PRECONDITIONS = {
    "S8RepresentativeSourceTests/testReviewedR146ImageRequiresSystemTrustAndNativeDecode()",
}
EXCLUDED_NONMEDIA = {
    "S8RepresentativeSourceTests/testPreScreenedRSSAudioResourceAdvancesAndProgressReloads()",
    "S8RepresentativeSourceTests/testPreScreenedPublicRSSImageCandidateListHasBoundedTargets()",
}
PROBE_MARKER = "SOURCE_TEMPLATE_LOG_PROBE_COMPLETED"
PROBE_PAYLOADS = ("fixtureTemplateExpressionSecret9281", "fixtureTemplateResultSecret6742", "AnalyzeUrl 模板")


def selected_cases(mode):
    if mode not in ("full", "nonmedia"):
        raise ValueError("必须显式选择full或nonmedia")
    selected = {f"{suite}/{method}" for suite, methods in CASES.items()
                if mode == "full" or suite in NONMEDIA_SUITES for method in methods.split()}
    selected -= EXTERNAL_PRECONDITIONS
    return selected - EXCLUDED_NONMEDIA if mode == "nonmedia" else selected


def simulator_id(destination, inventory):
    pairs = [part.strip().partition("=") for part in destination.split(",")]
    ids = [value for key, sep, value in pairs if sep and key == "id"]
    platforms = [value for key, sep, value in pairs if sep and key == "platform"]
    if len(ids) != 1 or (platforms and platforms != ["iOS Simulator"]):
        raise ValueError("S8只允许明确id的iOS Simulator目标，禁止物理设备和名称回退")
    available = {device["udid"] for runtime, devices in inventory.get("devices", {}).items()
                 if "SimRuntime.iOS-" in runtime for device in devices if device.get("isAvailable") is True}
    if ids[0] not in available:
        raise ValueError("目标不是当前可用的iOS模拟器；未运行xctest")
    return ids[0]


def _cases(node):
    if isinstance(node, dict):
        if node.get("nodeType") == "Test Case":
            yield node.get("nodeIdentifier"), node.get("result")
        for value in node.values():
            yield from _cases(value)
    elif isinstance(node, list):
        for value in node:
            yield from _cases(value)


def verify(mode, summary, tree, console, wrapper_status=0, device_id=None):
    expected = selected_cases(mode)
    if wrapper_status != 0 or summary.get("result") != "Passed":
        raise ValueError("xctest或xcresult最终失败，不能用框架中途结果覆盖")
    if any(summary.get(key) != 0 for key in ("failedTests", "skippedTests", "expectedFailures")):
        raise ValueError("失败/跳过/预期失败都不能计为当前自动回归通过")
    if summary.get("totalTestCount") != len(expected) or summary.get("passedTests") != len(expected):
        raise ValueError("最终用例数量不匹配，拒绝零项或部分执行")
    entries = list(_cases(tree))
    identifiers = [identifier for identifier, _ in entries]
    if any(not isinstance(identifier, str) for identifier in identifiers):
        raise ValueError("用例标识格式无效")
    if len(identifiers) != len(set(identifiers)) or set(identifiers) != expected:
        raise ValueError("实际用例集合缺失、重复或多出项目，不能仅用总数放行")
    if any(result != "Passed" for _, result in entries):
        raise ValueError("用例树存在未通过项")
    configurations = summary.get("devicesAndConfigurations", [])
    if not configurations or any(c.get("device", {}).get("platform") != "iOS Simulator"
                                 or (device_id and c.get("device", {}).get("deviceId") != device_id)
                                 for c in configurations):
        raise ValueError("xcresult实际运行设备与明确模拟器目标不一致")
    if "** TEST SUCCEEDED **" not in console or any(value in console for value in ("** TEST FAILED **", "** BUILD FAILED **")):
        raise ValueError("控制台没有一致的最终xcodebuild成功结论")
    if console.count(PROBE_MARKER) != 2 or any(value in console for value in PROBE_PAYLOADS):
        raise ValueError("模板控制台探针缺失或表达式/结果泄露")
    return {"mode": mode, "passed": len(expected), "suites": len({s.split('/')[0] for s in expected}),
            "explicitExclusions": len(EXCLUDED_NONMEDIA) if mode == "nonmedia" else 0,
            "externalPreconditionsNotRun": len(EXTERNAL_PRECONDITIONS),
            "notSelectedFromFull": len(selected_cases("full") - expected), "stageAccepted": False}


def main(argv):
    if argv and argv[0] == "destination" and len(argv) == 3:
        print(simulator_id(argv[1], json.loads(Path(argv[2]).read_text())))
    elif argv and argv[0] == "verify" and len(argv) == 7:
        mode, summary, tree, console, status, device = argv[1:]
        result = verify(mode, json.loads(Path(summary).read_text()), json.loads(Path(tree).read_text()),
                        Path(console).read_text(), int(status), device)
        print(json.dumps(result, ensure_ascii=False))
        print("仅本模式自动回归通过；不代表S8阶段、物理设备或发布验收通过。")
    else:
        raise ValueError("用法：destination DEST INVENTORY，或verify MODE SUMMARY TREE LOG STATUS DEVICE")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (ValueError, KeyError, OSError) as error:
        print(f"S8门槛拒绝：{error}", file=sys.stderr)
        raise SystemExit(1)
