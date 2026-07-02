import Foundation

// OpenRouter chat-completions client. Streams assistant tokens via Server-Sent Events over the
// libcurl/OpenSSL transport (iOS 6 Secure Transport can't negotiate OpenRouter's GCM ciphers).
enum OpenRouterAPI {
    static let endpoint = "https://openrouter.ai/api/v1/chat/completions"

    // Streams a reply. onDelta is called on the MAIN thread with each new text fragment.
    // onDone is called on the MAIN thread once, with nil on success or an error string on failure.
    static func streamChat(messages: [ChatMessage],
                           model: String,
                           apiKey: String,
                           onDelta: @escaping (String) -> Void,
                           onDone: @escaping (String?) -> Void) {

        let payload: [String: Any] = [
            "model": model,
            "messages": messages.map { $0.toAPIDict() },
            "stream": true
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: bodyData, encoding: .utf8) else {
            onDone("Failed to encode request."); return
        }

        let headers = [
            "Authorization: Bearer \(apiKey)",
            "Content-Type: application/json",
            "Accept: text/event-stream",
            "HTTP-Referer: https://github.com/cai",
            "X-Title: cai"
        ]

        let parser = SSEParser()

        CurlFetcher.postJSONStream(
            url: endpoint,
            body: body,
            headers: headers,
            onChunk: { data in
                // Runs on a background (curl) thread. Parse SSE frames, hop deltas to main.
                let deltas = parser.consume(data)
                if deltas.isEmpty { return }
                DispatchQueue.main.async {
                    for d in deltas { onDelta(d) }
                }
            },
            completion: { status, data in
                // Main thread (delivered by CurlFetcher).
                if status == 200 {
                    onDone(nil)
                } else {
                    onDone(errorMessage(status: status, body: data))
                }
            }
        )
    }

    // Extract a human-readable error from a non-200 response body.
    private static func errorMessage(status: Int, body: Data?) -> String {
        if status == 0 { return "Network error — could not reach OpenRouter." }
        if let data = body,
           let obj = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any],
           let err = dict["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return "OpenRouter error (\(status)): \(msg)"
        }
        if status == 401 { return "Unauthorized (401) — check your API key in Settings." }
        return "OpenRouter returned HTTP \(status)."
    }
}

// Incremental SSE parser. Buffers bytes across chunks (a frame can be split mid-line), splits on
// newlines, and returns the `delta.content` string(s) from each complete `data:` frame.
final class SSEParser {
    private var buffer = ""

    func consume(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        buffer += text

        var out: [String] = []
        // Process only complete lines; keep the trailing partial line in the buffer.
        while let range = buffer.range(of: "\n") {
            let line = String(buffer[buffer.startIndex..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)

            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix(":") { continue }              // SSE comment / keep-alive
            guard trimmed.hasPrefix("data:") else { continue }

            let payload = String(trimmed.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { continue }
            if let delta = SSEParser.contentDelta(fromJSON: payload) { out.append(delta) }
        }
        return out
    }

    private static func contentDelta(fromJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any],
              let choices = dict["choices"] as? [[String: Any]],
              let first = choices.first,
              let delta = first["delta"] as? [String: Any],
              let content = delta["content"] as? String else { return nil }
        return content
    }
}
