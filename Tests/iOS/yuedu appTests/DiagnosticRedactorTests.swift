import Foundation
import Testing
@testable import yuedu_app

@Suite("DiagnosticRedactor")
struct DiagnosticRedactorTests {

    /// The load-bearing rule. `SourceAPIErrorLog` documents why: these book-source
    /// APIs carry the user's token in the query string.
    @Test("URL query strings are stripped")
    func queryStringsAreStripped() {
        let redacted = DiagnosticRedactor.redact("GET https://api.example.com/book?token=abc123&uid=9")
        #expect(!redacted.contains("abc123"))
        #expect(redacted.contains("https://api.example.com/book"))
    }

    @Test("credential-shaped key/value pairs are masked")
    func credentialPairsAreMasked() {
        let cases = [
            "Cookie: session=deadbeef",
            "authorization=Basic Zm9vOmJhcg==",
            "\"access_token\": \"ya29.longvalue\"",
            "password=hunter2",
            "api_key = k-9f8e7d",
        ]
        for line in cases {
            let redacted = DiagnosticRedactor.redact(line)
            #expect(redacted.contains("<redacted>"), "not redacted: \(line) -> \(redacted)")
        }
    }

    @Test("quoted JSON cookie values are masked in exported source context")
    func quotedJSONCookiesAreMasked() {
        let raw = #"context={"source":{"cookie":"session=deadbeef; user=42","name":"Example"}}"#

        let redacted = DiagnosticRedactor.redact(raw)

        #expect(!redacted.contains("deadbeef"))
        #expect(!redacted.contains("user=42"))
        #expect(redacted.contains(#""cookie":"<redacted>""#))
        #expect(redacted.contains(#""name":"Example""#))
    }

    @Test("bearer tokens are masked")
    func bearerTokensAreMasked() {
        let redacted = DiagnosticRedactor.redact("Authorization header sent as Bearer eyJhbGciOi.J9")
        #expect(!redacted.contains("eyJhbGciOi.J9"))
    }

    /// Redaction must not eat the content of the report. A hostname and a chapter
    /// index are usually the whole point of the log line.
    @Test("ordinary diagnostic text is left alone")
    func ordinaryTextSurvives() {
        let line = "[FlipTrace] pageForward from=(ch3,off100) to=(ch3,off200) host=www.example.com"
        #expect(DiagnosticRedactor.redact(line) == line)
    }
}
