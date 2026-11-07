import Foundation

// 仅用于 macOS 上的诊断子集测试：所有测试都必须传入自己创建的目录。
// 若意外触及共享实例的 App 存储路径，立即失败，不回退到用户真实数据。
enum StorageLocations {
    static var diagnostics: URL {
        preconditionFailure("宿主测试必须使用显式的临时诊断目录")
    }
}

// 宿主测试不验证本地化 UI；生产本地化入口仍由 App 提供。
func localized(_ key: String) -> String { key }
