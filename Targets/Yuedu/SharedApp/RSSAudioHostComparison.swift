#if DEBUG && targetEnvironment(simulator)
import AVFoundation
import CryptoKit
import Foundation
import SwiftUI
import UIKit

/// 两个宿主调用完全相同的App侧播放器代码和同一个Caches输入文件；不触碰RSS/用户库或网络。
@MainActor
enum RSSAudioHostComparison {
    enum Host: String, Codable, Sendable { case xctest, standalone }
    enum Failure: Error { case configuration, invalidInput, reportExists, wrongHost, inactive }

    struct Report: Codable, Sendable {
        var host: Host
        var frameworkLoaded: Bool
        var bundleIdentifierSHA256: String
        var containerPathSHA256: String
        var inputSHA256: String
        var inputPathSHA256: String
        var inputBytes: Int
        var applicationState: Int
        var readyWithinDeadline: Bool
        var readyStatusAtDeadline: Int
        var advancedWithinDeadline: Bool
        var cancelled: Bool
        var elapsedMs: Int
        var playerStatus: Int
        var itemStatus: Int
        var hasError: Bool
        var position: Double?
        var duration: Double?
        var rate: Float
        var timeControl: Int
        var timebaseRate: Double?
        var effectiveRate: Double?
        var likelyToKeepUp: Bool
        var bufferEmpty: Bool
        var outputSuppressed: Bool?
        var muted: Bool
        var volume: Float
        var sourceClockOverridden: Bool
        var category: String
        var mode: String
        var sampleRate: Double
        var outputTypes: [String]
    }

    private static var standaloneStarted = false

    static var frameworkLoaded: Bool {
        NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
    }

    static func standaloneRequest() -> (directory: URL, report: URL)? {
        guard let raw = ProcessInfo.processInfo.environment["RSS_AUDIO_HOST_RUN_ID"],
              let id = UUID(uuidString: raw), id.uuidString.lowercased() == raw.lowercased() else { return nil }
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("readerfork-audio-host-\(id.uuidString.lowercased())", isDirectory: true)
        return (directory, directory.appendingPathComponent("standalone.json"))
    }

    static func runStandaloneIfRequested() async {
        guard RSSPoCTestHost.isEnabled,
              ProcessInfo.processInfo.arguments.contains("-rss-audio-host-comparison"),
              !standaloneStarted, let request = standaloneRequest() else { return }
        standaloneStarted = true
        do { _ = try await run(host: .standalone, directory: request.directory) }
        catch { print("S8_AUDIO_HOST_ERROR host=standalone reportComplete=false") }
    }

    static func run(host: Host, directory: URL) async throws -> Report {
        guard RSSPoCTestHost.isEnabled, (host == .xctest) == frameworkLoaded else { throw Failure.wrongHost }
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .resolvingSymlinksInPath().standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let prefix = "readerfork-audio-host-"
        guard resolvedDirectory.deletingLastPathComponent() == cacheRoot,
              resolvedDirectory.lastPathComponent.hasPrefix(prefix) else { throw Failure.configuration }
        let runID = String(resolvedDirectory.lastPathComponent.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: runID), uuid.uuidString.lowercased() == runID.lowercased() else {
            throw Failure.configuration
        }
        if UIApplication.shared.applicationState != .active {
            let active = Signal()
            let token = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                object: nil, queue: .main) { _ in MainActor.assumeIsolated { active.finish(true) } }
            defer { NotificationCenter.default.removeObserver(token) }
            if UIApplication.shared.applicationState == .active { active.finish(true) }
            // 等待真实前台事件，不把此启动前置延迟计入音频ready/clock截止。
            guard await active.wait(seconds: 5) else { throw Failure.inactive }
        }

        let file = directory.appendingPathComponent("sample.m4a")
        let output = directory.appendingPathComponent(host.rawValue + ".json")
        let input = try await Task.detached(priority: .utility) {
            try SourcePerfTrace.span("rss.audio.host.input", "main=\(Thread.isMainThread)") {
                guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.reportExists }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.intValue > 0, size.intValue <= 1_048_576 else {
                    throw Failure.invalidInput
                }
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                guard data.count == size.intValue else { throw Failure.invalidInput }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                let pathDigest = SHA256.hash(data: Data(file.resolvingSymlinksInPath().path.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                return (digest, pathDigest, data.count)
            }
        }.value

        let started = ContinuousClock.now
        let previous = try await Task.detached {
            let session = AVAudioSession.sharedInstance()
            let previous = (session.category, session.mode, session.categoryOptions)
            try session.setCategory(.playback)
            try session.setActive(true)
            return previous
        }.value
        let item = AVPlayerItem(asset: AVURLAsset(url: file))
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        let ready = Signal()
        let observation = item.observe(\.status, options: [.initial, .new]) { value, _ in
            guard value.status != .unknown else { return }
            Task { @MainActor in ready.finish(true) }
        }
        defer { observation.invalidate() }
        let readyInTime = await ready.wait(seconds: 10)
        let readyStatus = item.status.rawValue
        let moved = Signal()
        let token = player.addBoundaryTimeObserver(
            forTimes: [NSValue(time: CMTime(seconds: 0.2, preferredTimescale: 600))], queue: .main) {
                MainActor.assumeIsolated { moved.finish(true) }
            }
        defer { player.removeTimeObserver(token) }
        // 与原本地对照一致：截止后仍请求播放，记录相同最终时钟；不延长等待/替换时钟。
        player.play()
        let advanced = await moved.wait(seconds: 8)
        let session = AVAudioSession.sharedInstance()
        let suppressed: Bool?
        if #available(iOS 26.0, *) { suppressed = player.audioOutputSuppressedDueToNonMixableAudioRoute }
        else { suppressed = nil }
        func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }
        let elapsed = started.duration(to: .now).components
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        let bundleHash = SHA256.hash(data: Data(bundleIdentifier.utf8)).map { String(format: "%02x", $0) }.joined()
        let containerHash = SHA256.hash(data: Data(NSHomeDirectory().utf8)).map { String(format: "%02x", $0) }.joined()
        let report = Report(host: host, frameworkLoaded: frameworkLoaded,
            bundleIdentifierSHA256: bundleHash, containerPathSHA256: containerHash,
            inputSHA256: input.0, inputPathSHA256: input.1, inputBytes: input.2,
            applicationState: UIApplication.shared.applicationState.rawValue,
            readyWithinDeadline: readyInTime && readyStatus == AVPlayerItem.Status.readyToPlay.rawValue,
            readyStatusAtDeadline: readyStatus, advancedWithinDeadline: advanced, cancelled: Task.isCancelled,
            elapsedMs: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
            playerStatus: player.status.rawValue, itemStatus: item.status.rawValue,
            hasError: item.error != nil || player.error != nil, position: finite(player.currentTime().seconds),
            duration: finite(item.duration.seconds), rate: player.rate, timeControl: player.timeControlStatus.rawValue,
            timebaseRate: item.timebase.flatMap { finite(CMTimebaseGetRate($0)) },
            effectiveRate: item.timebase.flatMap { finite(CMTimebaseGetEffectiveRate($0)) },
            likelyToKeepUp: item.isPlaybackLikelyToKeepUp, bufferEmpty: item.isPlaybackBufferEmpty,
            outputSuppressed: suppressed, muted: player.isMuted, volume: player.volume,
            sourceClockOverridden: player.sourceClock != nil, category: session.category.rawValue,
            mode: session.mode.rawValue, sampleRate: session.sampleRate,
            outputTypes: session.currentRoute.outputs.map(\.portType.rawValue))
        player.pause()
        player.replaceCurrentItem(with: nil)
        try await Task.detached {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false)
            try session.setCategory(previous.0, mode: previous.1, options: previous.2)
        }.value
        try await Task.detached(priority: .utility) {
            try SourcePerfTrace.span("rss.audio.host.report", "main=\(Thread.isMainThread)") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(report).write(to: output, options: .atomic)
            }
        }.value
        print("S8_AUDIO_HOST_RESULT host=\(host.rawValue) frameworkLoaded=\(report.frameworkLoaded) ready=\(report.readyWithinDeadline) advanced=\(report.advancedWithinDeadline)")
        return report
    }

    @MainActor
    private struct ProbeView: View {
        @Environment(\.scenePhase) private var scenePhase
        @State private var started = false

        var body: some View {
            Color.clear.task(id: scenePhase) {
                guard scenePhase == .active, !started else { return }
                started = true
                await RSSAudioHostComparison.runStandaloneIfRequested()
            }
            .accessibilityIdentifier("rss-audio-host-comparison")
        }
    }

    static func probeView() -> some View { ProbeView() }

    /// 等待真实KVO/播放边界；sleep仅是10s/8s硬截止，不用于等状态稳定。
    @MainActor
    private final class Signal {
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?
        private var deadline: Task<Void, Never>?

        func finish(_ value: Bool) {
            guard result == nil else { return }
            result = value
            deadline?.cancel(); deadline = nil
            continuation?.resume(returning: value); continuation = nil
        }

        func wait(seconds: UInt64) async -> Bool {
            await withTaskCancellationHandler {
                if let result { return result }
                return await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    deadline = Task { [weak self] in
                        do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
                        catch is CancellationError { return }
                        catch { preconditionFailure("Unexpected diagnostic deadline failure") }
                        self?.finish(false)
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(false) }
            }
        }
    }
}

#Preview("S8 isolated audio diagnostic") { RSSAudioHostComparison.probeView() }
#endif
