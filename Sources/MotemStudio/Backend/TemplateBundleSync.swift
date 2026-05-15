import Foundation

/// Pulls `_template/` + `_template_slowpath/CLAUDE.md` from the backend
/// into `AgentSandbox.templateDirectory`, then re-renders the sandbox-
/// owned `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` so the merged content
/// (Motem prompt + backend template guide) reaches every agent CLI.
///
/// Triggered post-login (and at cold start when a stored token is
/// already valid) by `AuthManager`. Idempotent and ETag-aware — if the
/// backend reports no change, no files are touched.
@MainActor
final class TemplateBundleSync: ObservableObject {

    static let shared = TemplateBundleSync()

    @Published private(set) var isWorking = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastSyncedAt: Date?

    private static let etagKey = "TemplateBundle.etag"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Fetch the latest template bundle. Safe to call repeatedly —
    /// only one fetch runs at a time, and a 304 response from the
    /// backend skips all disk work.
    func sync() async {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }

        let url = BackendConfig.baseURL.appendingPathComponent("/api/games/template-bundle")
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let storedEtag = UserDefaults.standard.string(forKey: Self.etagKey),
           !storedEtag.isEmpty {
            request.setValue(storedEtag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Bad response"
                return
            }
            switch http.statusCode {
            case 304:
                lastSyncedAt = Date()
                return
            case 200..<300:
                let etag = http.value(forHTTPHeaderField: "ETag") ?? ""
                try unpack(data: data, etag: etag)
                if !etag.isEmpty {
                    UserDefaults.standard.set(etag, forKey: Self.etagKey)
                }
                lastSyncedAt = Date()
            default:
                lastError = "HTTP \(http.statusCode)"
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Forget the cached ETag so the next `sync()` always pulls a fresh
    /// bundle. Use after logout or when the user explicitly resets.
    func clearCache() {
        UserDefaults.standard.removeObject(forKey: Self.etagKey)
        let dir = AgentSandbox.templateDirectory
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Plumbing

    private func unpack(data: Data, etag: String) throws {
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motem-template-\(UUID().uuidString).tar.gz")
        try data.write(to: tmp)
        defer { try? fm.removeItem(at: tmp) }

        let templateDir = AgentSandbox.templateDirectory
        if fm.fileExists(atPath: templateDir.path) {
            try? fm.removeItem(at: templateDir)
        }
        try fm.createDirectory(at: templateDir, withIntermediateDirectories: true)

        // `/usr/bin/tar` on macOS is bsdtar; it handles `tar.gz` via
        // the `-z` flag without a separate gunzip step.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tmp.path, "-C", templateDir.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw SyncError.tarFailed(exitCode: process.terminationStatus, stderr: stderr)
        }

        let backendClaudeMdURL = templateDir
            .appendingPathComponent("_template_slowpath/CLAUDE.md")
        let backendClaudeMd = (try? String(contentsOf: backendClaudeMdURL, encoding: .utf8)) ?? ""
        AgentSandbox.applyBackendTemplate(claudeMd: backendClaudeMd, etag: etag)
    }

    enum SyncError: Error, LocalizedError {
        case tarFailed(exitCode: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .tarFailed(let code, let stderr):
                return "tar exit \(code): \(stderr)"
            }
        }
    }
}
