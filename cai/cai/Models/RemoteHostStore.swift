import Foundation

// Persists RemoteHost configs as individual JSON files under ~/Documents/hosts/,
// mirroring ConversationStore. Passwords live in the Keychain (keyed by host id),
// never in these files.
class RemoteHostStore {
    static let shared = RemoteHostStore()

    private let dir: String = {
        let docs = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return (docs as NSString).appendingPathComponent("hosts")
    }()

    private init() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: nil)
    }

    private func path(for id: String) -> String {
        return (dir as NSString).appendingPathComponent(id + ".json")
    }

    // All hosts, newest-created first.
    func all() -> [RemoteHost] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        var result: [RemoteHost] = []
        for name in names where name.hasSuffix(".json") {
            let full = (dir as NSString).appendingPathComponent(name)
            guard let data = fm.contents(atPath: full),
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any],
                  let host = RemoteHost.from(dict: dict) else { continue }
            result.append(host)
        }
        result.sort { $0.createdAt > $1.createdAt }
        return result
    }

    func save(_ host: RemoteHost) {
        guard let data = try? JSONSerialization.data(withJSONObject: host.toDict()) else { return }
        _ = (data as NSData).write(toFile: path(for: host.id), atomically: true)
    }

    // Removes the config file AND its Keychain password.
    func delete(_ host: RemoteHost) {
        try? FileManager.default.removeItem(atPath: path(for: host.id))
        Keychain.deletePassword(for: host.id)
    }
}
