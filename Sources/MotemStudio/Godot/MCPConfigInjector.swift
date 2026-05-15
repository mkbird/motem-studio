import Foundation

/// Writes `.mcp.json` in the agent's working directory so the CLI spawns
/// `motem-mcp-bridge` and the AI gains access to `godot_preview` /
/// `godot_reload` / `godot_stop` / `godot_status`.
///
/// The injector preserves any other `mcpServers` entries the user has set
/// (e.g. their own dev tools); only the `motem-studio` slot is owned by us.
enum MCPConfigInjector {

    /// Slot name used in `.mcp.json` -> `mcpServers`.
    static let slot = "motem-studio"

    /// Path the main app binds its unix socket to.
    static var socketURL: URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MotemStudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("bridge.sock")
    }

    /// Locate the `motem-mcp-bridge` helper binary that ships in the app
    /// bundle. Falls back to a sibling path so debug builds run from
    /// `build/Build/Products/Debug/` also work.
    static func resolveBridgeBinary() -> URL? {
        let bundleResource = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/motem-mcp-bridge")
        if FileManager.default.isExecutableFile(atPath: bundleResource.path) {
            return bundleResource
        }
        let sibling = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("motem-mcp-bridge")
        if FileManager.default.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        return nil
    }

    /// Merge or write the motem-studio entry into `<workingDir>/.mcp.json`.
    ///
    /// - Preserves existing top-level keys.
    /// - Preserves other `mcpServers.*` entries.
    /// - Overwrites only the `motem-studio` slot.
    @discardableResult
    static func inject(into workingDir: URL) -> Bool {
        guard let bridge = resolveBridgeBinary() else {
            NSLog("[MCPConfigInjector] motem-mcp-bridge not found in bundle, skipping inject")
            return false
        }

        let configURL = workingDir.appendingPathComponent(".mcp.json")
        var root: [String: Any] = [:]

        if let data = try? Data(contentsOf: configURL),
           let object = try? JSONSerialization.jsonObject(with: data),
           let dict = object as? [String: Any] {
            root = dict
        }

        var servers = (root["mcpServers"] as? [String: Any]) ?? [:]
        servers[slot] = [
            "command": bridge.path,
            "args": [String](),
            "env": [
                "MOTEM_MCP_SOCKET": socketURL.path,
                "MOTEM_WORKDIR": workingDir.path,
            ],
        ]
        root["mcpServers"] = servers

        do {
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: configURL, options: .atomic)
            return true
        } catch {
            NSLog("[MCPConfigInjector] failed to write .mcp.json: \(error)")
            return false
        }
    }

    /// Remove the motem-studio slot only. Used when the user disables
    /// preview from Settings, so we don't pollute the project with a
    /// stale entry pointing at a binary that might no longer exist.
    @discardableResult
    static func removeSlot(from workingDir: URL) -> Bool {
        let configURL = workingDir.appendingPathComponent(".mcp.json")
        guard let data = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              var root = object as? [String: Any] else {
            return false
        }
        guard var servers = root["mcpServers"] as? [String: Any], servers[slot] != nil else {
            return false
        }
        servers.removeValue(forKey: slot)
        if servers.isEmpty {
            root.removeValue(forKey: "mcpServers")
        } else {
            root["mcpServers"] = servers
        }
        do {
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: configURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
