import Foundation

// App settings backed by UserDefaults: the OpenRouter API key and the default model id.
enum Settings {
    private static let keyAPIKey = "openrouter_api_key"
    private static let keyDefaultModel = "default_model"
    private static let keySystemPrompt = "system_prompt"

    // A free model so users aren't billed by default. Editable in Settings.
    static let fallbackModel = "openrouter/free"

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

    static var hasAPIKey: Bool {
        return !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
