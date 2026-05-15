import Foundation

enum AgentBinaryLocator {

    /// Resolve the absolute path to the requested agent CLI on the user's
    /// machine, or `nil` if it is not installed.
    static func locate(_ agent: Agent) -> URL? {
        let name = agent.executableName
        if let path = whichViaLoginShell(name),
           FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let fallbacks = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(NSHomeDirectory())/.volta/bin/\(name)",
        ]
        return fallbacks.lazy.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    /// macOS GUI processes are launched by launchd and do not load
    /// `~/.zshrc` or `~/.bash_profile`, so the inherited PATH excludes
    /// nvm/volta/Homebrew installs. The `-i` flag is critical: a
    /// non-interactive login shell loads `.zprofile` but skips `.zshrc`,
    /// where most users put their PATH additions (npm prefix, fnm, etc.).
    /// `-ilc` matches what the spawn command uses for the actual session.
    private static func whichViaLoginShell(_ bin: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-ilc", "command -v \(bin)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }
}
