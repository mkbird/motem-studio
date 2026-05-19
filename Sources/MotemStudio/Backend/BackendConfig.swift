import Foundation

/// Connection settings for the deskrobot-backend API the macOS app
/// talks to. Mirrors `RobotConfig` on iOS so the same backend instance
/// serves both clients without divergent URL conventions.
///
/// The default host matches the iOS app's compiled-in value; the user
/// can override at runtime through the Settings panel and the value
/// persists in `UserDefaults`.
enum BackendConfig {

    /// Compile-time fallback when the user hasn't set anything yet.
    /// Keep in sync with `deskrobot-ios/RobotConfig.swift` so a fresh
    /// install of Motem Studio talks to the same dev backend the
    /// iPhone hits.
    static let defaultHost = "172.18.5.244"
    static let defaultPort = 8000

    private static let hostKey = "BackendHost"

    static var serverHost: String {
        get {
            let stored = UserDefaults.standard.string(forKey: hostKey) ?? ""
            return stored.isEmpty ? defaultHost : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == defaultHost {
                UserDefaults.standard.removeObject(forKey: hostKey)
            } else {
                UserDefaults.standard.set(trimmed, forKey: hostKey)
            }
        }
    }

    static var serverPort: Int { defaultPort }

    static var baseURL: URL {
        // Debug + Release both target HTTP for the LAN backend. When
        // the team moves to a TLS-fronted production host this should
        // become an `#if DEBUG` ladder matching iOS.
        URL(string: "http://\(serverHost):\(serverPort)")!
    }

    static func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: hostKey)
    }
}
