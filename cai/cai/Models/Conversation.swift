import Foundation

// One saved conversation: an ordered list of messages plus metadata. Persisted as a single
// JSON file by ConversationStore.
class Conversation {
    let id: String
    var title: String
    var model: String
    var messages: [ChatMessage]
    var createdAt: Double
    var updatedAt: Double

    init(id: String = UUID().uuidString,
         title: String = "New Chat",
         model: String,
         messages: [ChatMessage] = [],
         createdAt: Double = Date().timeIntervalSince1970,
         updatedAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.title = title
        self.model = model
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var lastMessagePreview: String {
        guard let last = messages.last else { return "No messages yet" }
        let text = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "…" : text
    }

    // Derive a short title from the first user message (called after the first send).
    func deriveTitleIfNeeded() {
        guard title == "New Chat" || title.isEmpty else { return }
        if let firstUser = messages.first(where: { $0.isUser }) {
            let trimmed = firstUser.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return }
            title = trimmed.count > 40 ? String(trimmed.prefix(40)) + "…" : trimmed
        }
    }

    // MARK: - Persistence

    func toDict() -> [String: Any] {
        return [
            "id": id,
            "title": title,
            "model": model,
            "createdAt": createdAt,
            "updatedAt": updatedAt,
            "messages": messages.map { $0.toDict() }
        ]
    }

    static func from(dict: [String: Any]) -> Conversation? {
        guard let id = dict["id"] as? String,
              let title = dict["title"] as? String,
              let model = dict["model"] as? String else { return nil }
        // Numeric fields: use NSNumber (as? Double is unreliable on the iOS 6 Swift runtime).
        let created = (dict["createdAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
        let updated = (dict["updatedAt"] as? NSNumber)?.doubleValue ?? created
        let rawMessages = dict["messages"] as? [[String: Any]] ?? []
        let messages = rawMessages.compactMap { ChatMessage.from(dict: $0) }
        return Conversation(id: id, title: title, model: model, messages: messages,
                            createdAt: created, updatedAt: updated)
    }
}
