import Foundation

// A saved SSH connection target. The password is NOT stored here — it lives in the
// Keychain keyed by this host's id (see Keychain). Persisted as JSON by RemoteHostStore,
// using the same manual toDict()/from(dict:) convention as the chat models.
class RemoteHost {
    let id: String
    var label: String
    var username: String
    var host: String
    var port: UInt16
    var createdAt: Double

    init(id: String = UUID().uuidString,
         label: String = "",
         username: String,
         host: String,
         port: UInt16 = 22,
         createdAt: Double = Date().timeIntervalSince1970) {
        self.id = id
        self.label = label
        self.username = username
        self.host = host
        self.port = port
        self.createdAt = createdAt
    }

    var connectionString: String {
        return "\(username)@\(host):\(port)"
    }

    // A human label, falling back to user@host:port when none was given.
    var displayName: String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? connectionString : trimmed
    }

    // MARK: - Persistence

    func toDict() -> [String: Any] {
        return [
            "id": id,
            "label": label,
            "username": username,
            "host": host,
            "port": Int(port),
            "createdAt": createdAt
        ]
    }

    static func from(dict: [String: Any]) -> RemoteHost? {
        guard let id = dict["id"] as? String,
              let username = dict["username"] as? String,
              let host = dict["host"] as? String else { return nil }
        let label = dict["label"] as? String ?? ""
        // Numeric fields via NSNumber (as? Double/Int is unreliable on the iOS 6 Swift runtime).
        let port = UInt16(truncatingIfNeeded: (dict["port"] as? NSNumber)?.intValue ?? 22)
        let created = (dict["createdAt"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970
        return RemoteHost(id: id, label: label, username: username, host: host,
                          port: port, createdAt: created)
    }
}
