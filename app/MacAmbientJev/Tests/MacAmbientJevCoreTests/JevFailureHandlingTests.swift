import Foundation
import Testing
@testable import MacAmbientJevCore

private actor CountingStatusTransport: JevHTTPTransport {
    private(set) var calls = 0
    private(set) var lastRequest: URLRequest?
    private let status: Int
    private let body: Data

    init(status: Int, body: String) {
        self.status = status
        self.body = Data(body.utf8)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        lastRequest = request
        return (body, HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!)
    }
}

@Test
func jevErrorsDoNotExposeAPIKeyOrProviderText() async throws {
    let key = "sk-secret-LEAKCHECK"
    for (status, body) in [(401, "{\"error\":\"bad key \(key)\"}"), (200, "not json \(key)"),
                           (200, "{\"answers\":{\"content_priority\":{\"type\":\"choice\",\"choice\":\"\(key)\",\"confidence\":1}}}")] {
        let transport = CountingStatusTransport(status: status, body: body)
        let client = JevClient(apiKey: key, transport: transport)
        do {
            _ = try await client.classifyPriority(text: "えー")
            Issue.record("expected failure for status \(status)")
        } catch {
            let rendered = "\(error) \(error.localizedDescription) \(String(reflecting: error))"
            let url = await transport.lastRequest?.url?.absoluteString ?? ""
            #expect(!url.contains(key))
            #expect(!rendered.contains(key), "error leaks provider-echoed text: \(rendered)")
        }
    }
}
