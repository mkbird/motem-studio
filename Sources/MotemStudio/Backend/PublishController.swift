import Foundation

/// Owns the "Publish to iPhone" flow: zip the currently-previewed
/// project (meta.json auto-stubbed when missing), upload it to
/// `POST /api/games`, surface progress + result. On success the same
/// account's iPhone receives a `game_ready` push from the backend and
/// downloads the new game through the existing iOS pipeline.
@MainActor
final class PublishController: ObservableObject {

    static let shared = PublishController()

    enum State: Equatable {
        case idle
        case packaging
        case uploading
        case success(gameId: String, message: String)
        case failed(reason: String)
    }

    @Published private(set) var state: State = .idle

    private init() {}

    func reset() {
        state = .idle
    }

    /// Zip `projectDir`, POST to `/api/games`, refresh the library so
    /// the new row appears in the sidebar. Caller passes the directory
    /// `GodotPreviewController.currentProjectDir` is pointing at —
    /// typically the sandbox root for a claude-authored game or a
    /// library entry under `sandbox/library/<id>/` if the user is
    /// re-publishing a downloaded game.
    func publish(projectDir: URL) async {
        state = .packaging
        let zipURL: URL
        do {
            try ensureMetaJSON(in: projectDir)
            zipURL = try await makeZip(of: projectDir)
        } catch {
            state = .failed(reason: error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: zipURL) }

        state = .uploading
        do {
            let zipData = try Data(contentsOf: zipURL)
            let response: PublishResponse = try await APIClient.shared.uploadFile(
                "/api/games",
                fileData: zipData,
                fileName: "\(projectDir.lastPathComponent).zip",
                mimeType: "application/zip"
            )
            state = .success(
                gameId: response.gameId,
                message: "Uploaded — your iPhone will receive it shortly."
            )
            // The new row should show up in Mine's list straight away.
            Task { await GameLibraryStore.shared.refresh() }
        } catch {
            state = .failed(reason: error.localizedDescription)
        }
    }

    // MARK: - Zip + meta

    private func makeZip(of projectDir: URL) async throws -> URL {
        let zipPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motem-publish-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // `-r .` packs everything under `projectDir` at the root of
        // the archive (no wrapping directory) — backend's POST handler
        // expects `project.godot` + `meta.json` at the zip top level.
        process.arguments = ["-r", "-q", zipPath.path, "."]
        process.currentDirectoryURL = projectDir
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw PublishError.zipFailed(exitCode: process.terminationStatus, stderr: stderr)
        }
        return zipPath
    }

    /// Locally-authored games don't always have a `meta.json` — claude
    /// generates `project.godot` + scenes/ and stops. Backend's upload
    /// endpoint refuses a zip without meta, so we stub one in if the
    /// agent didn't write its own. Existing files are preserved.
    private func ensureMetaJSON(in projectDir: URL) throws {
        let metaURL = projectDir.appendingPathComponent("meta.json")
        if FileManager.default.fileExists(atPath: metaURL.path) {
            return
        }
        let title = projectDir.lastPathComponent
        let payload: [String: Any] = [
            "title": title,
            "title_i18n": ["en": title, "zh-Hans": title],
            "description_i18n": ["en": "", "zh-Hans": ""],
            "icon": "🎮",
            "input_mode": "touch",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: metaURL, options: .atomic)
    }

    // MARK: - Types

    private struct PublishResponse: Decodable {
        let gameId: String
        let titleI18n: [String: String]?
        let inputMode: String?

        enum CodingKeys: String, CodingKey {
            case gameId = "game_id"
            case titleI18n = "title_i18n"
            case inputMode = "input_mode"
        }
    }

    enum PublishError: Error, LocalizedError {
        case zipFailed(exitCode: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .zipFailed(let code, let stderr):
                return "zip exit \(code): \(stderr)"
            }
        }
    }
}
