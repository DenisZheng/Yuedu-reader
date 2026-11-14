import Foundation
import Testing

@Suite("S8 bounded TLS error metadata")
struct S8TLSFailureMetadataTests {
    @Test("读取已存在的嵌套SSL过期码，不需要网络或trust重新求值")
    func expiredCertificateCode() {
        let ssl = NSError(domain: "kCFErrorDomainCFNetwork", code: -1202,
                          userInfo: ["_kCFStreamErrorCodeKey": -9814])
        let error = NSError(domain: NSURLErrorDomain, code: -1202, userInfo: [NSUnderlyingErrorKey: ssl])
        #expect(S8TLSFailureMetadata.sslCode(error) == "-9814")
    }

    @Test("未知数值/字符串/任意错误文案不会进入诊断结果")
    func rejectsUnapprovedPayload() {
        for payload in [987654321 as Any, -9814.25, Double.nan, "fixture-private-error", ["body": "fixture-private-body"]] {
            let error = NSError(domain: "fixture-private-domain", code: 42,
                userInfo: ["_kCFStreamErrorCodeKey": payload, NSLocalizedDescriptionKey: "fixture-private-message"])
            #expect(S8TLSFailureMetadata.sslCode(error) == "other")
        }
    }

    @Test("错误链最多根和两层underlying，不做无界遍历")
    func boundsErrorChain() {
        var error = NSError(domain: "kCFErrorDomainCFNetwork", code: -1202,
                            userInfo: ["_kCFStreamErrorCodeKey": -9814])
        for _ in 0..<3 { error = NSError(domain: NSURLErrorDomain, code: -1202, userInfo: [NSUnderlyingErrorKey: error]) }
        #expect(S8TLSFailureMetadata.sslCode(error) == "other")
    }
}
