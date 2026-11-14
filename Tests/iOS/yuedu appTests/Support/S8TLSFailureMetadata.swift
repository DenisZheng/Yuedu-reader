import Foundation

/// TLS审阅只取系统错误内已存在的白名单SSL码；不输出userInfo，不重新求值trust或发出证书链请求。
enum S8TLSFailureMetadata {
    static func sslCode(_ error: NSError) -> String {
        var current: NSError? = error
        for _ in 0..<3 {
            guard let value = current else { break }
            for key in ["_kCFStreamErrorCodeKey", "kCFStreamErrorCodeKey"] {
                if let number = value.userInfo[key] as? NSNumber {
                    let code = number.intValue
                    if number.doubleValue == Double(code), [-9807, -9812, -9813, -9814, -9815].contains(code) {
                        return String(code)
                    }
                }
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "other"
    }
}
