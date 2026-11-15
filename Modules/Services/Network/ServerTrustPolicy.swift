import CryptoKit
import Foundation
import os
import Security

/// 按操作员确认的兼容策略接受所有服务器证书，包括过期、自签名及主机名不匹配的证书。
/// 此策略作用于App可控制的URLSession/WKWebView，身份验证被削弱，不能保护凭据免受中间人攻击。
enum ServerTrustPolicy {
    static func answer(_ challenge: URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else {
            return (.performDefaultHandling, nil)
        }
        auditOnce(trust, host: space.host)
        return (.useCredential, URLCredential(trust: trust))
    }

    /// 只限制源站的最高TLS版本；当前证书决策不降低TLS 1.2下限。
    static func capAtTLS12(_ configuration: URLSessionConfiguration) {
        configuration.tlsMaximumSupportedProtocolVersion = .TLSv12
    }

    private static let auditedHosts = OSAllocatedUnfairLock(initialState: Set<String>())

    /// 仅检查服务器已经提供的链，不下载证书或撤销信息，不在主线程或delegate队列等待。
    private static func auditOnce(_ trust: SecTrust, host: String) {
        guard auditedHosts.withLock({ $0.insert(host).inserted }),
              let chain = SecTrustCopyCertificateChain(trust) else { return }
        nonisolated(unsafe) let certificates = chain
        DispatchQueue.global(qos: .utility).async {
            var copy: SecTrust?
            let status = SecTrustCreateWithCertificates(certificates, SecPolicyCreateSSL(true, host as CFString), &copy)
            guard status == errSecSuccess, let copy else {
                AppLogger.network("TLS证书诊断无法构造校验链", context: ["status": Int(status)], level: .warning)
                return
            }
            SecTrustSetNetworkFetchAllowed(copy, false)
            var error: CFError?
            guard !SecTrustEvaluateWithError(copy, &error) else { return }
            let digest = SHA256.hash(data: Data(host.lowercased().utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            AppLogger.network("TLS兼容策略接受了系统不信任的证书", context: [
                "hostDigest": digest,
                "errorCode": error.map { CFErrorGetCode($0) } ?? 0
            ], level: .warning)
        }
    }
}

final class ServerTrustSessionDelegate: NSObject, URLSessionDelegate, Sendable {
    static let shared = ServerTrustSessionDelegate()

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = ServerTrustPolicy.answer(challenge)
        completionHandler(disposition, credential)
    }
}

extension URLSession {
    static let trusting = trusting(.default)

    /// 证书按App兼容策略处理，协议版本仍保留TLS 1.2或更高下限。
    static func trusting(_ configuration: URLSessionConfiguration) -> URLSession {
        if configuration.tlsMinimumSupportedProtocolVersion.rawValue < tls_protocol_version_t.TLSv12.rawValue {
            configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        }
        return URLSession(configuration: configuration, delegate: ServerTrustSessionDelegate.shared, delegateQueue: nil)
    }

    static let sourceSites = sourceSites(.default)

    static func sourceSites(_ configuration: URLSessionConfiguration) -> URLSession {
        ServerTrustPolicy.capAtTLS12(configuration)
        return trusting(configuration)
    }
}
