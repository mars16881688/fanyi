import Foundation
import Testing
@testable import Suiyi

@Suite("LLMConfig.endpoint")
struct EndpointTests {
    @Test("Appends /chat/completions and strips trailing slashes")
    func appendsPath() {
        let config = LLMConfig(baseURL: " https://api.deepseek.com/v1/// ", apiKey: "k", model: "m")
        #expect(config.endpoint?.absoluteString == "https://api.deepseek.com/v1/chat/completions")
    }

    @Test("Keeps a full endpoint as is")
    func keepsFullEndpoint() {
        let config = LLMConfig(baseURL: "http://localhost:11434/v1/chat/completions", apiKey: "k", model: "m")
        #expect(config.endpoint?.absoluteString == "http://localhost:11434/v1/chat/completions")
    }

    @Test("Rejects non-HTTP schemes and garbage", arguments: ["ftp://example.com", "not a url", ""])
    func rejects(base: String) {
        #expect(LLMConfig(baseURL: base, apiKey: "k", model: "m").endpoint == nil)
    }
}

@Suite("Error messages")
struct ErrorMessageTests {
    @Test("Common HTTP statuses get a Chinese hint", arguments: [400, 401, 402, 403, 404, 429, 500, 503])
    func hints(status: Int) {
        #expect(LLMError.hint(forStatus: status) != nil)
        let text = LLMError.http(status, "detail").errorDescription ?? ""
        #expect(text.contains("HTTP \(status)"))
        #expect(text.contains("detail"))
    }

    @Test("Unknown statuses fall back to the raw detail")
    func unknownStatus() {
        #expect(LLMError.hint(forStatus: 418) == nil)
        #expect(LLMError.http(418, "").errorDescription == "HTTP 418")
    }

    @Test("Long error bodies are truncated")
    func truncates() {
        let text = LLMError.http(500, String(repeating: "x", count: 1000)).errorDescription ?? ""
        #expect(text.count < 260)
    }

    @Test("Network errors become readable Chinese")
    func networkErrors() {
        let offline = LLMError.userMessage(for: URLError(.notConnectedToInternet))
        #expect(offline.contains("网络未连接"))
        let timeout = LLMError.userMessage(for: URLError(.timedOut))
        #expect(timeout.contains("超时"))
        let host = LLMError.userMessage(for: URLError(.cannotFindHost))
        #expect(host.contains("Base URL"))
        #expect(LLMError.userMessage(for: LLMError.missingKey).contains("API Key"))
    }

    @Test("JSON error bodies yield error.message")
    func describesJSONBody() {
        let body = #"{"error":{"message":"Insufficient Balance"}}"#
        #expect(LLMClient.describeErrorBody(body) == "Insufficient Balance")
        #expect(LLMClient.describeErrorBody("  plain text  ") == "plain text")
    }

    @Test("Requests without a key fail before any network call")
    func missingKey() async {
        await #expect(throws: LLMError.self) {
            try await LLMClient.ping(config: LLMConfig(baseURL: AppSettings.defaultBaseURL, apiKey: "  ", model: "m"))
        }
    }
}

@Suite("SSEParser")
struct SSEParserTests {
    @Test("Content deltas")
    func delta() {
        let line = #"data: {"choices":[{"delta":{"content":"你好"}}]}"#
        #expect(SSEParser.parse(line) == .delta("你好"))
    }

    @Test("Done marker, comments and blank lines")
    func controlLines() {
        #expect(SSEParser.parse("data: [DONE]") == .done)
        #expect(SSEParser.parse(": keep-alive") == .ignore)
        #expect(SSEParser.parse("   ") == .ignore)
        #expect(SSEParser.parse(#"data: {"choices":[{"delta":{}}]}"#) == .ignore)
        #expect(SSEParser.parse("data: {broken") == .ignore)
    }

    @Test("In-stream API errors")
    func failure() {
        #expect(SSEParser.parse(#"data: {"error":{"message":"rate limited"}}"#) == .failure("rate limited"))
    }

    @Test("Non-SSE lines are kept for the plain-JSON fallback")
    func nonEvent() {
        #expect(SSEParser.parse(#"{"choices":[]}"#) == .nonEvent(#"{"choices":[]}"#))
    }
}
