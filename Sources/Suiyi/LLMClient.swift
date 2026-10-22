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
            let snippet = String(body.trimmed.prefix(160))
            let detail = snippet.isEmpty ? "HTTP \(code)" : "HTTP \(code)：\(snippet)"
            guard let hint = Self.hint(forStatus: code) else { return detail }
            return "\(hint)（\(detail)）"
        case .api(let message):
            return "服务返回错误：\(message)"
        case .emptyResponse:
            return "服务没有返回任何内容。"
        }
    }

    static func hint(forStatus code: Int) -> String? {
        switch code {
        case 400: return "请求被服务拒绝，请检查模型名称和参数。"
        case 401, 403: return "API Key 无效或没有权限，请在设置里检查。"
        case 402: return "账户余额不足，请到模型服务商处充值。"
        case 404: return "接口地址或模型不存在，请检查 Base URL 和模型名称。"
        case 408, 504: return "服务响应超时，请稍后再试。"
        case 429: return "请求太频繁或额度已用完，请稍后再试。"
        case 500...599: return "模型服务暂时不可用，请稍后再试。"
        default: return nil
        }
    }

    /// A short Chinese message for any error thrown while calling the model.
    static func userMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "网络未连接，请检查网络后重试。"
            case .timedOut:
                return "请求超时，请检查网络，或稍后再试。"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "连不上接口地址，请检查设置里的 Base URL。"
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "与接口建立安全连接失败，请检查 Base URL 是否正确。"
            default:
                break
            }
        }
        return error.localizedDescription
    }
}

/// One line of a Server-Sent Events stream from an OpenAI-compatible API.
enum SSEEvent: Equatable {
    case ignore             // blank line, comment, or an unparsable data line
    case done               // data: [DONE]
    case delta(String)      // a piece of content
    case failure(String)    // an error object inside the stream
    case nonEvent(String)   // not SSE at all (servers that ignore stream:true)
}

enum SSEParser {
    static func parse(_ line: String) -> SSEEvent {
        let trimmedLine = line.trimmingCharacters(in: .whitespaces)
        if trimmedLine.isEmpty || trimmedLine.hasPrefix(":") { return .ignore }
        guard trimmedLine.hasPrefix("data:") else { return .nonEvent(line) }
        let payload = trimmedLine.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data) else { return .ignore }
        if let message = chunk.error?.message, !message.isEmpty { return .failure(message) }
        if let piece = chunk.choices?.first?.delta?.content, !piece.isEmpty { return .delta(piece) }
        return .ignore
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

struct ChatChunk: Decodable {
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
    static func describeErrorBody(_ body: String) -> String {
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

        streamLoop: for try await line in bytes.lines {
            try Task.checkCancellation()
            switch SSEParser.parse(line) {
            case .ignore:
                continue
            case .done:
                break streamLoop
            case .failure(let message):
                throw LLMError.api(message)
            case .delta(let piece):
                receivedAny = true
                await onDelta(piece)
            case .nonEvent(let raw):
                if nonEventBody.count < 200_000 { nonEventBody += raw + "\n" }
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
