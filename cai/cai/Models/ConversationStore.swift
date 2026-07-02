import Foundation

// Persists conversations as individual JSON files under ~/Documents/conversations/.
// Kept deliberately simple (no index file): the list is rebuilt by scanning the directory.
class ConversationStore {
    static let shared = ConversationStore()

    // NSSearchPath resolved once (per CLAUDE.md: keep path lookups as a stored let).
    private let dir: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return (docs as NSString).appendingPathComponent("conversations")
    }()

    private init() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
    }

    private func path(for id: String) -> String {
        return (dir as NSString).appendingPathComponent(id + ".json")
    }

    // All conversations, newest-updated first.
    func all() -> [Conversation] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var result: [Conversation] = []
        for name in names where name.hasSuffix(".json") {
            let full = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: full),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any],
                  let convo = Conversation.from(dict: dict) else { continue }
            result.append(convo)
        }
        result.sort { $0.updatedAt > $1.updatedAt }
        return result
    }

    func save(_ conversation: Conversation) {
        conversation.updatedAt = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: conversation.toDict()) else { return }
        _ = (data as NSData).write(toFile: path(for: conversation.id), atomically: true)
    }

    func delete(_ conversation: Conversation) {
        try? FileManager.default.removeItem(atPath: path(for: conversation.id))
    }
}
