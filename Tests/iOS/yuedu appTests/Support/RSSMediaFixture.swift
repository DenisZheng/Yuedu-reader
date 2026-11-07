import CryptoSwift
import Foundation

/// 用既有合成视频构造AES-128 HLS；key/IV仅用于这个测试，不含真实账号或受版权保护媒体。
enum RSSMediaFixture {
    static func encryptedHLS(directory: URL) throws -> [String: VideoStillFixtureServer.Response] {
        let key = Array(UInt8(0)...UInt8(15))
        let iv = [UInt8](repeating: 0, count: 16)
        let cookie = ["cookie": "fixture_session=synthetic"]
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-TARGETDURATION:4
        #EXT-X-MEDIA-SEQUENCE:0
        #EXT-X-PLAYLIST-TYPE:VOD
        #EXT-X-KEY:METHOD=AES-128,URI="key",IV=0x00000000000000000000000000000000
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.000000,
        0.m4s
        #EXTINF:4.000000,
        1.m4s
        #EXTINF:2.000000,
        2.m4s
        #EXT-X-ENDLIST
        """
        var routes: [String: VideoStillFixtureServer.Response] = [
            "/secure/encrypted.m3u8": .init(body: Data(playlist.utf8), type: "application/vnd.apple.mpegurl", requiredHeaders: cookie),
            "/secure/key": .init(body: Data(key), type: "application/octet-stream", requiredHeaders: cookie)
        ]
        for (input, output) in [("video-still-hls-init.mp4", "init.mp4"), ("video-still-hls-0.m4s", "0.m4s"), ("video-still-hls-1.m4s", "1.m4s"), ("video-still-hls-2.m4s", "2.m4s")] {
            let plain = try Data(contentsOf: directory.appendingPathComponent(input))
            let cipher = try AES(key: key, blockMode: CBC(iv: iv), padding: .pkcs7).encrypt(Array(plain))
            routes["/secure/" + output] = .init(body: Data(cipher), type: output.hasSuffix("mp4") ? "video/mp4" : "video/iso.segment", requiredHeaders: cookie)
        }
        return routes
    }
}
