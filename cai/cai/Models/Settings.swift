import Foundation

// App settings backed by UserDefaults: the OpenRouter API key and the default model id.
enum Settings {
    private static let keyAPIKey = "openrouter_api_key"
    private static let keyDefaultModel = "default_model"
    private static let keySystemPrompt = "system_prompt"
    private static let keyTTSModel = "tts_model"
    private static let keyTTSVoice = "tts_voice"

    // A free model so users aren't billed by default. Editable in Settings.
    static let fallbackModel = "openrouter/free"

    // Speech models do NOT appear in /api/v1/models, so the slug can't be discovered at
    // runtime and these defaults will go stale. Both are editable in Settings.
    // Confirmed working on device; ":free" so speaking a reply isn't billed by default.
    static let fallbackTTSModel = "deepgram/flux-tts:free"
    static let fallbackTTSVoice = "flux-bree-en"

    static var apiKey: String {
        get { UserDefaults.standard.string(forKey: keyAPIKey) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: keyAPIKey)
            UserDefaults.standard.synchronize()
        }
    }

    static var defaultModel: String {
        get {
            let m = UserDefaults.standard.string(forKey: keyDefaultModel) ?? ""
            return m.isEmpty ? fallbackModel : m
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyDefaultModel)
            UserDefaults.standard.synchronize()
        }
    }

    // Optional system prompt, prepended as a system message to every request when non-empty.
    static var systemPrompt: String {
        get { UserDefaults.standard.string(forKey: keySystemPrompt) ?? "" }
        set {
            UserDefaults.standard.set(newValue, forKey: keySystemPrompt)
            UserDefaults.standard.synchronize()
        }
    }

    // Model used to synthesize spoken replies.
    static var ttsModel: String {
        get {
            let m = UserDefaults.standard.string(forKey: keyTTSModel) ?? ""
            return m.isEmpty ? fallbackTTSModel : m
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyTTSModel)
            UserDefaults.standard.synchronize()
        }
    }

    // Voice name passed to the speech endpoint (provider-specific, e.g. "alloy").
    static var ttsVoice: String {
        get {
            let v = UserDefaults.standard.string(forKey: keyTTSVoice) ?? ""
            return v.isEmpty ? fallbackTTSVoice : v
        }
        set {
            UserDefaults.standard.set(newValue, forKey: keyTTSVoice)
            UserDefaults.standard.synchronize()
        }
    }

    static var hasAPIKey: Bool {
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
