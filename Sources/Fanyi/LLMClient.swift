import Foundation

struct ChatMessage: Encodable, Sendable {
    let role: String
    let content: String
}

struct LLMConfig: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String

    /// `{baseURL}/chat/completions`; a base URL that already ends in
    /// `/chat/completions` is used as is.
    var endpoint: URL? {
        var base = baseURL.trimmed
        while base.hasSuffix("/") { base.removeLast() }
        if !base.lowercased().hasSuffix("/chat/completions") {
            base += "/chat/completions"
        }
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return url
    }
}

enum LLMError: LocalizedError {
    case missingKey
    case badURL(String)
    case http(Int, String)
    case api(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "还没有设置 API Key。请点菜单栏图标 → 设置… 填写并保存。"
        case .badURL(let value):
            return "Base URL 无效：\(value)"
        case .http(let code, let body):
            let snippet = body.trimmed
            return snippet.isEmpty ? "HTTP \(code)" : "HTTP \(code)：\(snippet)"
        case .api(let message):
            return "服务返回错误：\(message)"
        case .emptyResponse:
            return "服务没有返回任何内容。"
        }
    }
}

private struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let stream: Bool
    let maxTokens: Int?

    enum CodingKeys: String, CodingKey {
        case model, messages, temperature, stream
        case maxTokens = "max_tokens"
    }
}

private struct ChatChunk: Decodable {
    struct Choice: Decodable {
        struct Content: Decodable {
            let content: String?
        }
        let delta: Content?
        let message: Content?
    }
    struct APIError: Decodable {
        let message: String?
    }
    let choices: [Choice]?
    let error: APIError?
}

/// Minimal OpenAI-compatible chat client (streaming via SSE).
enum LLMClient {
    private static func makeRequest(config: LLMConfig, messages: [ChatMessage], temperature: Double,
                                    stream: Bool, maxTokens: Int?) throws -> URLRequest {
        guard !config.apiKey.trimmed.isEmpty else { throw LLMError.missingKey }
        guard let url = config.endpoint else { throw LLMError.badURL(config.baseURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(config.apiKey.trimmed)", forHTTPHeaderField: "Authorization")
        let body = ChatRequest(model: config.model.trimmed, messages: messages,
                               temperature: temperature, stream: stream, maxTokens: maxTokens)
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// Extracts a readable message from an error body (JSON `error.message`
    /// if present, otherwise the first ~400 characters).
    private static func describeErrorBody(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data),
           let message = chunk.error?.message, !message.isEmpty {
            return message
        }
        return String(body.trimmed.prefix(400))
    }

    /// Streams the completion; `onDelta` is called on the main actor for each
    /// piece of content. Throws on HTTP/API errors and on cancellation.
    static func streamChat(config: LLMConfig, messages: [ChatMessage], temperature: Double,
                           onDelta: @escaping @MainActor @Sendable (String) -> Void) async throws {
        let request = try makeRequest(config: config, messages: messages, temperature: temperature,
                                      stream: true, maxTokens: nil)
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.api("无效的响应")
        }

        if !(200..<300).contains(http.statusCode) {
            var body = ""
            for try await line in bytes.lines {
                body += line + "\n"
                if body.count > 2000 { break }
            }
            throw LLMError.http(http.statusCode, describeErrorBody(body))
        }

        let decoder = JSONDecoder()
        var receivedAny = false
        var nonEventBody = ""   // for servers that ignore stream:true

        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.isEmpty || trimmedLine.hasPrefix(":") { continue }
            guard trimmedLine.hasPrefix("data:") else {
                if nonEventBody.count < 200_000 { nonEventBody += line + "\n" }
                continue
            }
            let payload = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? decoder.decode(ChatChunk.self, from: data) else { continue }
            if let message = chunk.error?.message, !message.isEmpty {
                throw LLMError.api(message)
            }
            if let piece = chunk.choices?.first?.delta?.content, !piece.isEmpty {
                receivedAny = true
                await onDelta(piece)
            }
        }
        try Task.checkCancellation()

        if !receivedAny {
            // Non-streaming fallback: a plain JSON completion body.
            if let data = nonEventBody.data(using: .utf8),
               let chunk = try? decoder.decode(ChatChunk.self, from: data) {
                if let message = chunk.error?.message, !message.isEmpty {
                    throw LLMError.api(message)
                }
                if let content = chunk.choices?.first?.message?.content, !content.isEmpty {
                    await onDelta(content)
                    return
                }
            }
            throw LLMError.emptyResponse
        }
    }

    /// Tiny non-streaming request used by "测试连接". Returns the reply text.
    static func ping(config: LLMConfig) async throws -> String {
        let request = try makeRequest(
            config: config,
            messages: [ChatMessage(role: "user", content: "Reply with the single word: OK")],
            temperature: 0,
            stream: false,
            maxTokens: 8
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LLMError.api("无效的响应") }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, describeErrorBody(body))
        }
        guard let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data) else {
            throw LLMError.api("无法解析返回内容：\(String(body.prefix(200)))")
        }
        if let message = chunk.error?.message, !message.isEmpty { throw LLMError.api(message) }
        let reply = chunk.choices?.first?.message?.content?.trimmed ?? ""
        return reply.isEmpty ? "(空回复)" : reply
    }
}
