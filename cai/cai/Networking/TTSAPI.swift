import Foundation

// OpenRouter text-to-speech client. POSTs to /api/v1/audio/speech and returns raw MP3 bytes.
//
// Unlike the chat endpoint, a successful response is a raw audio byte stream
// (Content-Type: audio/mpeg), NOT JSON. Errors arrive as a JSON body with a non-200 status.
// Requests go through CurlFetcher (libcurl/OpenSSL) because iOS 6 Secure Transport cannot
// negotiate OpenRouter's GCM ciphers.
enum TTSAPI {
    static let endpoint = "https://openrouter.ai/api/v1/audio/speech"

    // Synthesizes `text` to MP3. `completion` runs on the MAIN thread with either the audio
    // bytes or a human-readable error string (never both).
    static func synthesize(text: String,
                           model: String,
                           voice: String,
                           apiKey: String,
                           completion: @escaping (Data?, String?) -> Void) {

        var payload: [String: Any] = [
            "model": model,
            "input": text,
            // The API defaults to PCM; AVAudioPlayer needs a container format, so always ask
            // for mp3 explicitly.
            "response_format": "mp3"
        ]
        // Most providers reject a request with no voice, but a few define a default — so only
        // send the field when the user has actually set one.
        let trimmedVoice = voice.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedVoice.isEmpty { payload["voice"] = trimmedVoice }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: bodyData, encoding: .utf8) else {
            completion(nil, "Failed to encode request.")
            return
        }

        let headers = [
            "Authorization: Bearer \(apiKey)",
            "Content-Type: application/json",
            "HTTP-Referer: https://github.com/cai",
            "X-Title: cai"
        ]

        CurlFetcher.postJSON(url: endpoint, body: body, headers: headers, timeout: 60) { status, data in
            // Main thread (delivered by CurlFetcher).
            if status == 200, let data = data, data.count > 0 {
                completion(data, nil)
            } else {
                completion(nil, errorMessage(status: status, body: data))
            }
        }
    }

    // Extract a human-readable error from a non-200 response body.
    private static func errorMessage(status: Int, body: Data?) -> String {
        if status == 0 { return "Network error - could not reach OpenRouter." }
        if let data = body,
           let obj = try? JSONSerialization.jsonObject(with: data),
           let dict = obj as? [String: Any],
           let err = dict["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return "TTS error (\(status)): \(msg)"
        }
        if status == 200 { return "Empty audio response." }
        if status == 401 { return "Unauthorized (401) - check your API key in Settings." }
        if status == 404 { return "Not found (404) - check the voice model id in Settings." }
        return "OpenRouter returned HTTP \(status)."
    }
}
