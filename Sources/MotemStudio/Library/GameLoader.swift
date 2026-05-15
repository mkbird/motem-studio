import Foundation

/// Downloads a game zip from the backend, extracts it under the
/// sandbox, and hands the resulting directory off to
/// `GodotPreviewController.preview()`.
///
/// Each library game lives at `sandbox/library/<game_id>/` so it
/// never clobbers whatever the user is authoring in the sandbox root
/// (the cwd claude / codex / gemini work in). Switching between a
/// library game and a locally-authored one is just two different
/// `project_dir` arguments to `godot_preview`.
@MainActor
enum GameLoader {

    enum LoaderError: Error, LocalizedError {
        case downloadFailed(Error)
        case unzipFailed(exitCode: Int32, stderr: String)
        case missingProject

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let err):
                return "Download failed: \(err.localizedDescription)"
            case .unzipFailed(let code, let stderr):
                return "Unzip failed (\(code)): \(stderr)"
            case .missingProject:
                return "Downloaded zip has no project.godot"
            }
        }
    }

    private static var libraryRoot: URL {
        AgentSandbox.directory.appendingPathComponent("library", isDirectory: true)
    }

    private static func gameDirectory(for gameId: String) -> URL {
        libraryRoot.appendingPathComponent(gameId, isDirectory: true)
    }

    /// Download `game_id` (idempotent — re-uses the cached folder when
    /// `content_modified_at` hasn't changed), preview it through the
    /// embedded engine, and mark it active on the library store.
    static func load(gameId: String) async throws {
        let store = GameLibraryStore.shared
        store.setLoading(gameId)
        defer { store.setLoading(nil) }

        NSLog("[GameLoader] load start id=%@", gameId)
        do {
            let target = try await downloadAndExtract(gameId: gameId)
            NSLog("[GameLoader] extracted to %@", target.path)
            let result = await GodotPreviewController.shared.preview(projectDir: target)
            switch result {
            case .success:
                NSLog("[GameLoader] preview OK")
                store.markActive(gameId)
            case .failure(let message):
                NSLog("[GameLoader] preview FAILED: %@", message)
                throw LoaderError.downloadFailed(NSError(
                    domain: "GameLoader",
                    code: 0,
                    userInfo: [NSLocalizedDescriptionKey: message]
                ))
            }
        } catch {
            NSLog("[GameLoader] load FAILED: %@", String(describing: error))
            throw error
        }
    }

    // MARK: - Private

    private static func downloadAndExtract(gameId: String) async throws -> URL {
        let zipData: Data
        do {
            zipData = try await APIClient.shared.getData("/api/games/\(gameId)/download")
        } catch {
            throw LoaderError.downloadFailed(error)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: libraryRoot, withIntermediateDirectories: true)
        let gameDir = gameDirectory(for: gameId)
        if fm.fileExists(atPath: gameDir.path) {
            try? fm.removeItem(at: gameDir)
        }
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)

        let tmpZip = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motem-game-\(gameId)-\(UUID().uuidString).zip")
        try zipData.write(to: tmpZip)
        defer { try? fm.removeItem(at: tmpZip) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-o", tmpZip.path, "-d", gameDir.path]
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
            throw LoaderError.unzipFailed(exitCode: process.terminationStatus, stderr: stderr)
        }

        // The backend serves `games/{id}.zip` whose top level is the
        // game files themselves (no wrapping directory). Verify the
        // shape so a broken upload surfaces instead of silently
        // showing an empty preview.
        if !fm.fileExists(atPath: gameDir.appendingPathComponent("project.godot").path) {
            // If a single subdirectory wraps the project, descend.
            let children = (try? fm.contentsOfDirectory(at: gameDir, includingPropertiesForKeys: nil)) ?? []
            if children.count == 1, children[0].hasDirectoryPath,
               fm.fileExists(atPath: children[0].appendingPathComponent("project.godot").path) {
                return children[0]
            }
            throw LoaderError.missingProject
        }
        return gameDir
    }
}
