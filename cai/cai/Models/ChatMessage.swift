import Foundation

// A single chat turn. `role` is one of "system", "user", "assistant" (OpenRouter/OpenAI roles).
struct ChatMessage {
    var role: String
    var content: String

    static let roleUser = "user"
    static let roleAssistant = "assistant"
    static let roleSystem = "system"

    var isUser: Bool { return role == ChatMessage.roleUser }

    // API payload shape
    func toAPIDict() -> [String: Any] {
        return ["role": role, "content": content]
    }

    // Persistence
    func toDict() -> [String: Any] {
        return ["role": role, "content": content]
    }

    static func from(dict: [String: Any]) -> ChatMessage? {
        guard let role = dict["role"] as? String,
              let content = dict["content"] as? String else { return nil }
        return ChatMessage(role: role, content: content)
    }
}
