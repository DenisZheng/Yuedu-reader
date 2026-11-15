import Combine
import Foundation
import StoreKit

// 仅保留 Storefront 的地区可用性查询；不读取交易、商品、收据或会员权益。
// 移除收费体系不改变既有公共书库的地区支持策略。

/// Mainland China uses source discovery only. Unknown storefronts are available;
/// a transient nil StoreKit answer preserves a previously known country, so a
/// cold launch in CHN cannot flash the libraries before StoreKit responds.
@MainActor
final class PublicLibraryAvailability: ObservableObject {
    static let shared = PublicLibraryAvailability()
    static let countryKey = "publicLibrary.lastStorefrontCountry"
    @Published private(set) var countryCode: String?
    var isAvailable: Bool { countryCode != "CHN" }
    private let defaults: UserDefaults
    private let readCountryCode: @MainActor () async -> String?
    private var isStarted = false

    init(
        defaults: UserDefaults = .standard,
        readCountryCode: @escaping @MainActor () async -> String? = { await Storefront.current?.countryCode }
    ) {
        self.defaults = defaults
        self.readCountryCode = readCountryCode
        countryCode = defaults.string(forKey: Self.countryKey)
    }

    /// Follows the App Store storefront from now on: reads it once here, and again
    /// on every `refresh()`. Until this runs, `refresh()` does nothing, so a pinned
    /// country (`-debug-storefront-country` in UI tests) is never overwritten.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        Task { await refresh() }
    }

    /// Reads the storefront again. Call when the app becomes active: the storefront
    /// changes only in Settings, so the app is always away while it changes.
    ///
    /// In place of iterating `Storefront.updates`, as `SubscriptionStore` does. Each
    /// read of the storefront makes StoreKit announce a change, and the sequence reads
    /// it again for every announcement: on the iOS 17.5 simulator that fed itself
    /// about 500 times a second from launch (measured 2026-11-10, a plain
    /// `simctl launch`, no Xcode StoreKit configuration) until the system SIGKILLed the
    /// app 106–128 seconds in (launchd exit 30, `0x4aaaa`, no crash report).
    func refresh() async {
        guard isStarted else { return }
        receive(countryCode: await readCountryCode())
    }

    func receive(countryCode: String?) {
        guard let countryCode else { return }
        self.countryCode = countryCode
        defaults.set(countryCode, forKey: Self.countryKey)
    }
}
