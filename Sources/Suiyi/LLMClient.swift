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
        guard let url = URL(string: base), let scheme = url.scheme?.lowercased(), url.host != nil else { return nil }
        // 0.2.1.k.01: the key and the text never travel unencrypted: https only, plain http only
        // to this Mac (e.g. a local Ollama).
        if scheme == "https" { return url }
        if scheme == "http", let host = url.host?.lowercased(), ["localhost", "127.0.0.1", "::1"].contains(host) {
            return url
        }
        return nil
    }
}

/// 0.2.1.k.01: requests carrying the API key and the selected text never follow a redirect to
/// another URL; the configured endpoint must answer directly.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    static let shared = NoRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
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
            return L("还没有设置 API Key。请点菜单栏图标 → 设置… 填写并保存。",
                     "No API key yet. Click the menu bar icon → Settings… and save one.",
                     "API キーが未設定です。メニューバーのアイコン → 設定… で保存してください。", "API 키가 아직 없습니다. 메뉴 막대 아이콘 → 설정…에서 저장하세요.")
        case .badURL(let value):
            return L("Base URL 无效：\(value)（只接受 https；http 仅限本机地址）", "Invalid Base URL: \(value) (https only; http only for this Mac)", "Base URL が無効です：\(value)（https のみ。http はこの Mac のアドレスに限ります）", "잘못된 Base URL: \(value) (https만 가능, http는 이 Mac 주소만 가능)")
        case .http(let code, let body):
            let snippet = String(body.trimmed.prefix(160))
            let detail = snippet.isEmpty ? "HTTP \(code)" : "HTTP \(code)：\(snippet)"
            guard let hint = Self.hint(forStatus: code) else { return detail }
            return "\(hint)（\(detail)）"
        case .api(let message):
            return L("服务返回错误：\(message)", "The service returned an error: \(message)", "サービスがエラーを返しました：\(message)", "서비스가 오류를 반환했습니다: \(message)")
        case .emptyResponse:
            return L("服务没有返回任何内容。", "The service returned nothing.", "サービスから応答がありませんでした。", "서비스가 아무것도 반환하지 않았습니다.")
        }
    }

    static func hint(forStatus code: Int) -> String? {
        switch code {
        case 400: return L("请求被服务拒绝，请检查模型名称和参数。", "The request was rejected. Check the model name and parameters.", "リクエストが拒否されました。モデル名とパラメータを確認してください。", "요청이 거부되었습니다. 모델 이름과 매개변수를 확인하세요.")
        case 401, 403: return L("API Key 无效或没有权限，请在设置里检查。", "The API key is invalid or lacks permission. Check it in Settings.", "API キーが無効か権限がありません。設定で確認してください。", "API 키가 잘못되었거나 권한이 없습니다. 설정에서 확인하세요.")
        case 402: return L("账户余额不足，请到模型服务商处充值。", "Insufficient balance. Top up with your model provider.", "残高不足です。モデル提供元でチャージしてください。", "잔액이 부족합니다. 모델 제공업체에서 충전하세요.")
        case 404: return L("接口地址或模型不存在，请检查 Base URL 和模型名称。", "Endpoint or model not found. Check the Base URL and model name.", "エンドポイントまたはモデルが見つかりません。Base URL とモデル名を確認してください。", "엔드포인트나 모델을 찾을 수 없습니다. Base URL과 모델 이름을 확인하세요.")
        case 408, 504: return L("服务响应超时，请稍后再试。", "The service timed out. Try again later.", "サービスがタイムアウトしました。しばらくしてから再試行してください。", "서비스 응답 시간이 초과되었습니다. 잠시 후 다시 시도하세요.")
        case 429: return L("请求太频繁或额度已用完，请稍后再试。", "Too many requests or quota used up. Try again later.", "リクエストが多すぎるか、上限に達しました。しばらくしてから再試行してください。", "요청이 너무 많거나 사용량을 모두 소진했습니다. 잠시 후 다시 시도하세요.")
        case 500...599: return L("模型服务暂时不可用，请稍后再试。", "The model service is temporarily unavailable. Try again later.", "モデルサービスが一時的に利用できません。しばらくしてから再試行してください。", "모델 서비스를 일시적으로 사용할 수 없습니다. 잠시 후 다시 시도하세요.")
        default: return nil
        }
    }

    /// A short Chinese message for any error thrown while calling the model.
    static func userMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return L("网络未连接，请检查网络后重试。", "You are offline. Check your connection and try again.", "ネットワークに接続されていません。接続を確認して再試行してください。", "오프라인 상태입니다. 연결을 확인한 후 다시 시도하세요.")
            case .timedOut:
                return L("请求超时，请检查网络，或稍后再试。", "The request timed out. Check your connection or try again later.", "リクエストがタイムアウトしました。接続を確認するか、しばらくしてから再試行してください。", "요청 시간이 초과되었습니다. 연결을 확인하거나 잠시 후 다시 시도하세요.")
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return L("连不上接口地址，请检查设置里的 Base URL。", "Cannot reach the endpoint. Check the Base URL in Settings.", "エンドポイントに接続できません。設定の Base URL を確認してください。", "엔드포인트에 연결할 수 없습니다. 설정에서 Base URL을 확인하세요.")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return L("与接口建立安全连接失败，请检查 Base URL 是否正确。", "Secure connection failed. Check that the Base URL is correct.", "安全な接続に失敗しました。Base URL が正しいか確認してください。", "보안 연결에 실패했습니다. Base URL이 올바른지 확인하세요.")
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
        let (bytes, response) = try await URLSession.shared.bytes(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse else {
            throw LLMError.api(L("无效的响应", "Invalid response", "無効な応答", "잘못된 응답"))
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
        let (data, response) = try await URLSession.shared.data(for: request, delegate: NoRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw LLMError.api(L("无效的响应", "Invalid response", "無効な応答", "잘못된 응답")) }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw LLMError.http(http.statusCode, describeErrorBody(body))
        }
        guard let chunk = try? JSONDecoder().decode(ChatChunk.self, from: data) else {
            throw LLMError.api(L("无法解析返回内容：", "Could not parse the response: ", "応答を解析できません：", "응답을 해석할 수 없습니다: ") + String(body.prefix(200)))
        }
        if let message = chunk.error?.message, !message.isEmpty { throw LLMError.api(message) }
        let reply = chunk.choices?.first?.message?.content?.trimmed ?? ""
        return reply.isEmpty ? L("（空回复）", "(empty reply)", "（空の応答）", "(빈 응답)") : reply
    }
}
