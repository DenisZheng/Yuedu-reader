import AVFoundation
import Foundation
import XCTest
@testable import yuedu_app

/// 与既有m4a使用相同原生会话/ready/播放边界，对照无压缩PCM；不混入S6批准的模拟器选择集。
@MainActor
final class S8AudioClockDiagnosticsTests: XCTestCase {
    func testLocalPCMReadyAndClockWithoutCompressedDecoder() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("此诊断只在模拟器隔离宿主执行，不在物理设备运行")
        #endif
        try XCTSkipUnless(RSSPoCTestHost.isEnabled, "仅隔离宿主运行音频时钟诊断")
        let url = URL.temporaryDirectory.appendingPathComponent("S8PCM-" + UUID().uuidString + ".wav")
        try await Task.detached(priority: .utility) { try Self.pcmData().write(to: url, options: .atomic) }.value
        defer { do { try FileManager.default.removeItem(at: url) } catch { XCTFail("清理本用例PCM文件失败") } }
        let timeline = AudioTestTimeline()
        let previous = try await Task.detached {
            let session = AVAudioSession.sharedInstance()
            let previous = (session.category, session.mode, session.categoryOptions)
            timeline.record("PCM setCategory begin")
            try session.setCategory(.playback)
            try session.setActive(true)
            timeline.record("PCM setActive returned")
            return previous
        }.value
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        var state: String?
        defer {
            let attachment = XCTAttachment(string: timeline.snapshot + "\nBEFORE TEARDOWN " + (state ?? RSSMediaPoCTests.audioState(player: player, item: item)))
            attachment.name = "s8-local-pcm-state"
            attachment.lifetime = .keepAlways
            add(attachment)
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        let ready = expectation(description: "本地PCM ready")
        let observation = item.observe(\.status, options: [.initial, .new]) { value, _ in
            timeline.record("PCM status=\(value.status.rawValue) hasError=\(value.error != nil)")
            if value.status != .unknown { ready.fulfill() }
        }
        defer { observation.invalidate() }
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertEqual(item.status, .readyToPlay)
        let advanced = expectation(description: "PCM真实时钟越过0.2秒")
        let token = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: 0.2, preferredTimescale: 600))], queue: .main) {
            timeline.record("PCM 0.2 boundary")
            advanced.fulfill()
        }
        defer { player.removeTimeObserver(token) }
        timeline.record("PCM play() called")
        player.play()
        await fulfillment(of: [advanced], timeout: 8)
        XCTAssertGreaterThan(player.currentTime().seconds, 0.2)
        state = RSSMediaPoCTests.audioState(player: player, item: item)
        timeline.record("PCM clock wait returned")
        player.pause()
        player.replaceCurrentItem(with: nil)
        try await Task.detached {
            let session = AVAudioSession.sharedInstance()
            try session.setActive(false)
            try session.setCategory(previous.0, mode: previous.1, options: previous.2)
        }.value
    }

    /// 自建1秒、44100Hz、单声道16位PCM正弦；非静音数据，不设置播放器音量或替换sourceClock。
    nonisolated private static func pcmData() -> Data {
        let rate = 44_100
        let bytes = UInt32(rate * 2)
        var data = Data()
        func little<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); little(bytes + 36)
        data.append(contentsOf: "WAVEfmt ".utf8); little(UInt32(16))
        little(UInt16(1)); little(UInt16(1)); little(UInt32(rate)); little(UInt32(rate * 2))
        little(UInt16(2)); little(UInt16(16)); data.append(contentsOf: "data".utf8); little(bytes)
        for index in 0..<rate {
            let sample = Int16((sin(Double(index) * 2 * .pi * 440 / Double(rate)) * 4_096).rounded())
            little(sample)
        }
        return data
    }
}
