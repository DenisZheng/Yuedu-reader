import Combine
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Auto Read Controller

/// 自動閱讀 — a mode, not a transport.
///
/// Modelled on legado's `AutoPager` (`legado-E/.../page/AutoPager.kt`), which all
/// three forks implement identically. Two things about it are easy to get wrong,
/// and the previous version got both:
///
/// 自动阅读在翻页模式下逐步揭示下一页，等宿主确认页面落地后才重置揭页。
/// 仿真／覆盖／滑动的普通转场动画不叠加到自动阅读；滚动模式只连续移动正文。
/// 速度以每页秒数计算，两种模式使用相同的阅读速度。
///
/// Driven by `CADisplayLink` rather than a `Timer`, because the reveal advances
/// every frame rather than once per page.
@MainActor
final class AutoReadController: NSObject, ObservableObject {

    /// legado's slider: 1–120 seconds for one page, default 10. Bigger is slower.
    nonisolated static let secondsPerPageRange: ClosedRange<Double> = 1...120
    nonisolated static let defaultSecondsPerPage: Double = 10

    private static let defaultsKey = "yd_auto_read_seconds_per_page"
    /// The old 0.5×–5× multiplier. Read once, converted, then left alone — a
    /// stored `2.0` is ambiguous between the two scales, so the new value needs a
    /// key of its own rather than a reinterpretation of the old one.
    private static let legacyMultiplierDefaultsKey = "yd_auto_read_speed"
    /// What 1× used to mean.
    private static let legacyBaseInterval: Double = 4.0

    /// Also a Crashlytics key, like `tts_playing`: a stall report says whether the pages
    /// were turning by themselves.
    ///
    /// Keeps the screen on for as long as the mode runs (legado sets `screenTimeOut = -1`).
    /// Every way out — 退出, the reader closing — passes through here.
    @Published private(set) var isActive = false {
        didSet {
            CrashContext.setKey("auto_read", isActive)
            ScreenAwakeController.shared.setHeld(isActive, .autoRead, by: self)
        }
    }
    /// Held, not stopped: the menu is open, or a gesture is in flight. legado
    /// pauses on exactly these and resumes without losing the reveal's position.
    @Published private(set) var isPaused = false
    /// Survives leaving the reader.
    @Published private(set) var secondsPerPage: Double
    /// How far the next page has been revealed, 0…1. Only meaningful in 翻頁 mode.
    ///
    /// Deliberately **not** `@Published`. It changes every frame, and publishing it
    /// would re-evaluate the whole reader body sixty times a second for a value
    /// only one CALayer cares about. The reveal view is driven directly through
    /// `onProgressChanged`; SwiftUI only hears about the low-frequency facts
    /// (`isActive`, which page).
    private(set) var progress: Double = 0

    /// Pushed straight at the reveal layer, bypassing SwiftUI.
    var onProgressChanged: ((Double) -> Void)?

    /// 请求无动画翻页。false 表示书末并退出；true 要求宿主随后回报真实落地或拒绝。
    var onAdvancePage: (() -> Bool)?
    /// 捲動 mode: move the content down by this fraction of one viewport.
    /// `false` means the end of the book.
    var onScrollByFraction: ((Double) -> Bool)?
    /// Asked every frame, because the reader can switch modes underneath us.
    var usesContinuousScroll: () -> Bool = { false }

    /// 宿主确认前保持揭页完整，避免显示刚读过的旧页。
    private(set) var isAwaitingPageTurn = false
    private var travelledWhileAwaiting: Double = 0

    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?

    var secondsText: String { Self.secondsText(secondsPerPage) }

    override init() {
        secondsPerPage = Self.loadPersistedSecondsPerPage()
        super.init()
    }

    // MARK: - Mode

    func enter() {
        guard !isActive else { return }
        isActive = true
        isPaused = false
        endAwaitingPageTurn()
        setProgress(0)
        startDisplayLink()
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        isPaused = false
        endAwaitingPageTurn()
        setProgress(0)
        stopDisplayLink()
    }

    func toggleMode() {
        if isActive { exit() } else { enter() }
    }

    /// Leaves the mode without the caller having to know whether it was on.
    func stopForReaderExit() {
        isActive = false
        isPaused = false
        endAwaitingPageTurn()
        setProgress(0)
        stopDisplayLink()
    }

    // MARK: - Pause

    /// Holds the reveal where it is. Paused time is not credited to progress:
    /// `resume` restarts the clock rather than catching up.
    func pause() {
        guard isActive, !isPaused else { return }
        isPaused = true
        lastTimestamp = nil
        displayLink?.isPaused = true
    }

    func resume() {
        guard isActive, isPaused else { return }
        isPaused = false
        lastTimestamp = nil
        displayLink?.isPaused = false
    }

    /// A manual page turn or a chapter change invalidates the reveal — the page
    /// underneath is no longer the one being revealed over. legado does this from
    /// `ReadView.onPageChange`; the difference is that it resets on *every* page
    /// change including its own, which is the per-page drift `advance` avoids by
    /// subtracting. So this is for turns the mode did not ask for, only.
    func resetReveal() {
        guard isActive else { return }
        endAwaitingPageTurn()
        setProgress(0)
        lastTimestamp = nil
    }

    private func setProgress(_ value: Double) {
        progress = value
        onProgressChanged?(value)
    }

    private func endAwaitingPageTurn() {
        isAwaitingPageTurn = false
        travelledWhileAwaiting = 0
    }

    // MARK: - Speed

    func setSecondsPerPage(_ newValue: Double) {
        let clamped = Self.clampedSecondsPerPage(newValue)
        guard clamped != secondsPerPage else { return }
        secondsPerPage = clamped
        UserDefaults.standard.set(clamped, forKey: Self.defaultsKey)
    }

    nonisolated static func clampedSecondsPerPage(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSecondsPerPage }
        return min(max(value.rounded(), secondsPerPageRange.lowerBound), secondsPerPageRange.upperBound)
    }

    /// "10s" — the readout legado's dialog shows next to the slider.
    nonisolated static func secondsText(_ value: Double) -> String {
        String(format: "%.0fs", clampedSecondsPerPage(value))
    }

    /// "約每 10 秒翻一頁"
    var intervalDescription: String {
        String(
            format: localized("AutoRead.Format.Interval"),
            String(format: "%.0f", secondsPerPage)
        )
    }

    private static func loadPersistedSecondsPerPage() -> Double {
        let defaults = UserDefaults.standard
        if let stored = defaults.object(forKey: defaultsKey) as? Double {
            return clampedSecondsPerPage(stored)
        }
        if let legacyMultiplier = defaults.object(forKey: legacyMultiplierDefaultsKey) as? Double,
           legacyMultiplier.isFinite,
           legacyMultiplier > 0 {
            let converted = clampedSecondsPerPage(legacyBaseInterval / legacyMultiplier)
            defaults.set(converted, forKey: defaultsKey)
            return converted
        }
        return defaultSecondsPerPage
    }

    // MARK: - Frame driver

    private func startDisplayLink() {
        stopDisplayLink()
        lastTimestamp = nil
        let link = DisplayLinkProxy.displayLink(
            target: self,
            selector: #selector(handleDisplayLink(_:))
        )
        // .common so the reveal keeps moving while a gesture is tracking.
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        lastTimestamp = nil
    }

    @objc private func handleDisplayLink(_ link: CADisplayLink) {
        guard isActive, !isPaused else { return }
        guard let previous = lastTimestamp else {
            lastTimestamp = link.timestamp
            return
        }
        lastTimestamp = link.timestamp
        step(elapsed: link.timestamp - previous)
    }

    /// 显示帧与隔离回归共用同一推进入口。
    func step(elapsed: TimeInterval) {
        guard isActive, !isPaused else { return }
        guard elapsed > 0, elapsed.isFinite else { return }
        let fraction = Self.fraction(ofPageIn: elapsed, secondsPerPage: secondsPerPage)

        if usesContinuousScroll() {
            // 切到滚动模式后没有揭页，结束之前分页模式遗留的等待。
            endAwaitingPageTurn()
            if onScrollByFraction?(fraction) == false { exit() }
            return
        }

        if isAwaitingPageTurn {
            travelledWhileAwaiting = min(1, travelledWhileAwaiting + fraction)
            return
        }

        let advance = Self.advance(progress: progress, by: fraction)
        guard advance.pageTurns > 0 else {
            setProgress(advance.progress)
            return
        }
        setProgress(1)
        isAwaitingPageTurn = true
        travelledWhileAwaiting = min(1, advance.progress + Double(advance.pageTurns - 1))
        let advanced = SourcePerfTrace.span("reader.autoRead.advance", thresholdMs: 5) {
            onAdvancePage?() == true
        }
        if !advanced { exit() }
    }

    /// 页面真正落地或请求被拒绝后才重置揭页，并计入期间已看到的阅读时间。
    func pageTurnResolved() {
        guard isActive, isAwaitingPageTurn else { return }
        let travelled = travelledWhileAwaiting
        endAwaitingPageTurn()
        setProgress(travelled)
    }

    // MARK: - Frame arithmetic (pure, so it can be tested without a display link)

    /// legado's `height / readTime * elapsedTime`, expressed as a fraction of one
    /// page rather than in pixels — the pixels differ between the two modes but
    /// the fraction does not.
    nonisolated static func fraction(
        ofPageIn elapsed: TimeInterval,
        secondsPerPage: Double
    ) -> Double {
        elapsed / max(secondsPerPageRange.lowerBound, secondsPerPage)
    }

    struct Advance: Equatable {
        var progress: Double
        var pageTurns: Int
    }

    /// Subtracts a whole page rather than resetting to zero.
    ///
    /// legado-E zeroes here and so loses the overshoot — up to one frame of drift
    /// on every page. Its own KMP port subtracts instead; that is the version
    /// worth copying.
    nonisolated static func advance(progress: Double, by fraction: Double) -> Advance {
        guard fraction.isFinite, fraction > 0 else {
            return Advance(progress: progress, pageTurns: 0)
        }
        var value = progress + fraction
        var turns = 0
        while value >= 1 {
            value -= 1
            turns += 1
        }
        return Advance(progress: value, pageTurns: turns)
    }

    isolated deinit {
        displayLink?.invalidate()
    }
}
