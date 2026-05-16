import Foundation

/// Where the auth tokens live on disk. Two backends keyed by build
/// configuration:
///
/// - **Release** → macOS Keychain (`KeychainHelper`). Production
///   builds are signed with a stable Developer ID; the Keychain ACL
///   keys off the team identifier, so updates flow through without
///   prompting the user.
///
/// - **Debug** → a plain JSON file at
///   `~/Library/Application Support/MotemStudio/auth.json` with mode
///   `0600`. Ad-hoc-signed dev builds generate a fresh signature on
///   every rebuild, which invalidates the Keychain ACL and triggers
///   a password prompt every launch. The file store sidesteps that.
///   Trade-off: tokens sit in plaintext in the user's home — fine for
///   a personal dev tool, NOT for shipped artifacts.
enum TokenStore {

    static func save(_ value: String, for key: String) {
        #if DEBUG
        FileTokenStore.save(value, for: key)
        #else
        KeychainHelper.save(value, for: key)
        #endif
    }

    static func get(_ key: String) -> String? {
        #if DEBUG
        return FileTokenStore.get(key)
        #else
        return KeychainHelper.get(key)
        #endif
    }

    static func delete(_ key: String) {
        #if DEBUG
        FileTokenStore.delete(key)
        #else
        KeychainHelper.delete(key)
        #endif
    }
}

/// Plaintext JSON-on-disk store used by Debug builds. The file is
/// created with `0600` so only the current user can read it, matching
/// Keychain's per-user scope (not its per-app encryption).
private enum FileTokenStore {

    private static let queue = DispatchQueue(label: "com.motem.studio.tokenstore")

    private static var fileURL: URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MotemStudio", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("auth.json")
    }

    static func save(_ value: String, for key: String) {
        queue.sync {
            var dict = readAll()
            dict[key] = value
            writeAll(dict)
        }
    }

    static func get(_ key: String) -> String? {
        queue.sync { readAll()[key] }
    }

    static func delete(_ key: String) {
        queue.sync {
            var dict = readAll()
            dict.removeValue(forKey: key)
            writeAll(dict)
        }
    }

    // MARK: - Disk

    private static func readAll() -> [String: String] {
        let url = fileURL
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private static func writeAll(_ dict: [String: String]) {
        let url = fileURL
        do {
            let data = try JSONSerialization.data(
                withJSONObject: dict,
                options: [.sortedKeys]
            )
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
        } catch {
            // No surface for storage errors — auth flow will simply
            // fall back to "not logged in" on the next read.
        }
    }
}
