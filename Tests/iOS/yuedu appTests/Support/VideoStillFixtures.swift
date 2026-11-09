import Foundation

/// VideoStill固定媒体：模拟器可读源码目录；真机只能读测试bundle中（Xcode扁平复制）的同名文件。
/// 两处都缺失时返回源码路径，让后续测试以“文件不存在”明确失败，而不是静默改用其他数据。
enum VideoStillFixtures {
    private final class Token {}
    static func directory(sourceFile: String = #filePath) -> URL {
        let source = URL(fileURLWithPath: sourceFile).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/VideoStill", isDirectory: true)
        if FileManager.default.fileExists(atPath: source.appendingPathComponent("video-still-landscape.mp4").path) { return source }
        if let bundled = Bundle(for: Token.self).resourceURL,
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("video-still-landscape.mp4").path) { return bundled }
        return source
    }
}
