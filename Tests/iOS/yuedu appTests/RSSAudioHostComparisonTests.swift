import AVFoundation
import CryptoKit
import Foundation
import XCTest
import UIKit
@testable import yuedu_app

#if DEBUG && targetEnvironment(simulator)
@MainActor
final class RSSAudioHostComparisonTests: XCTestCase {
    func testSameAppPlayerAndM4AInputUnderXCTestHost() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("此对照只运行于iOS模拟器，不在物理设备运行")
        #endif
        try XCTSkipUnless(RSSPoCTestHost.isEnabled, "要求隔离宿主，禁止执行用户源或启动普通App服务")
        let environment = ProcessInfo.processInfo.environment
        guard let rawID = environment["RSS_AUDIO_HOST_RUN_ID"] ?? environment["TEST_RUNNER_RSS_AUDIO_HOST_RUN_ID"],
              let runID = UUID(uuidString: rawID) else { throw RSSAudioHostComparison.Failure.configuration }
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = cacheRoot.appendingPathComponent("readerfork-audio-host-\(runID.uuidString.lowercased())", isDirectory: true)
        let fixture = VideoStillFixtures.directory().appendingPathComponent("video-still-audio-only.m4a")
        let input = directory.appendingPathComponent("sample.m4a")
        let xctestReport = directory.appendingPathComponent("xctest.json")
        try await Task.detached(priority: .utility) {
            try SourcePerfTrace.span("rss.audio.host.fixture", "main=\(Thread.isMainThread)") {
                if FileManager.default.fileExists(atPath: directory.path) {
                    // 交错A/B中standalone先行的轮次：宿主脚本已按同一路径规则预置同一fixture。
                    // 只接受逐字节相同的输入且本宿主报告尚不存在；不静默改用其他数据。
                    guard !FileManager.default.fileExists(atPath: xctestReport.path) else {
                        throw RSSAudioHostComparison.Failure.reportExists
                    }
                    let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 1_048_576,
                          let existing = try? Data(contentsOf: input, options: .mappedIfSafe),
                          let original = try? Data(contentsOf: fixture, options: .mappedIfSafe),
                          existing == original else {
                        throw RSSAudioHostComparison.Failure.invalidInput
                    }
                } else {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: fixture, to: input)
                    let attributes = try FileManager.default.attributesOfItem(atPath: input.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 1_048_576 else {
                        throw RSSAudioHostComparison.Failure.invalidInput
                    }
                }
            }
        }.value
        let report = try await RSSAudioHostComparison.run(host: .xctest, directory: directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(report)
        let attachment = XCTAttachment(data: encoded, uniformTypeIdentifier: "public.json")
        attachment.name = "s8-audio-host-xctest"
        attachment.lifetime = .keepAlways
        add(attachment)
        try await Task.detached(priority: .utility) {
            try SourcePerfTrace.span("rss.audio.host.report", "main=\(Thread.isMainThread)") {
                try encoded.write(to: xctestReport, options: .atomic)
            }
        }.value
        XCTAssertEqual(report.host, .xctest)
        XCTAssertTrue(report.frameworkLoaded)
        XCTAssertEqual(report.applicationState, UIApplication.State.active.rawValue)
        XCTAssertFalse(report.cancelled)
        XCTAssertGreaterThan(report.inputBytes, 0)
        print("S8_AUDIO_HOST_RUN id=\(runID.uuidString.lowercased())")
        print("S8_AUDIO_HOST_RESULT host=xctest frameworkLoaded=\(report.frameworkLoaded) bundleHash=\(report.bundleIdentifierSHA256) containerHash=\(report.containerPathSHA256) inputHash=\(report.inputSHA256) inputPathHash=\(report.inputPathSHA256) inputBytes=\(report.inputBytes) appState=\(report.applicationState) readyDeadline=\(report.readyWithinDeadline) readyStatusAtDeadline=\(report.readyStatusAtDeadline) advanced=\(report.advancedWithinDeadline) elapsedMs=\(report.elapsedMs) playerStatus=\(report.playerStatus) itemStatus=\(report.itemStatus) hasError=\(report.hasError) position=\(report.position.map { String(format: "%.3f", $0) } ?? "unavailable") duration=\(report.duration.map { String(format: "%.3f", $0) } ?? "unavailable") rate=\(report.rate) timeControl=\(report.timeControl) timebaseRate=\(report.timebaseRate.map { String($0) } ?? "unavailable") effectiveRate=\(report.effectiveRate.map { String($0) } ?? "unavailable") likely=\(report.likelyToKeepUp) bufferEmpty=\(report.bufferEmpty) outputSuppressed=\(report.outputSuppressed.map { String($0) } ?? "unavailable") muted=\(report.muted) volume=\(report.volume) sourceClockOverridden=\(report.sourceClockOverridden) category=\(report.category) mode=\(report.mode) sampleRate=\(report.sampleRate) outputs=\(report.outputTypes)")
    }
}
#endif
