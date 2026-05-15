import Foundation

enum TerminalEnvironment {

    /// Build the environment passed to the PTY-spawned agent process.
    /// Agent CLIs are responsible for their own auth and config.
    static func build(workingDirectory: URL, appLanguage: AppLanguage) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]

        let inherit = [
            "HOME", "USER", "LOGNAME", "SHELL",
            "TMPDIR", "SSH_AUTH_SOCK",
            "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
        ]
        for key in inherit {
            if let value = parent[key] { env[key] = value }
        }

        let shell = parent["SHELL"] ?? "/bin/zsh"

        env["PATH"] = resolvedPath(shell: shell)
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["FORCE_COLOR"] = "1"

        switch appLanguage {
        case .system:
            if let value = parent["LANG"] { env["LANG"] = value }
            if let value = parent["LC_ALL"] { env["LC_ALL"] = value }
        case .chinese:
            env["LANG"] = "zh_CN.UTF-8"
            env["LC_ALL"] = "zh_CN.UTF-8"
        case .english:
            env["LANG"] = "en_US.UTF-8"
            env["LC_ALL"] = "en_US.UTF-8"
        }

        env["PWD"] = workingDirectory.path

        // Expose the MCP bridge socket so any tool the agent runs (or
        // the helper binary itself) can locate the main app.
        env["MOTEM_MCP_SOCKET"] = MCPConfigInjector.socketURL.path

        return env
    }

    private static func resolvedPath(shell: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // -ilc, not -lc: most users put PATH additions (npm prefix, fnm,
        // nvm) in `.zshrc`, which a non-interactive login shell skips.
        process.arguments = ["-ilc", "echo $PATH"]
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
        let result = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (result?.isEmpty == false) ? result : nil
    }

}
