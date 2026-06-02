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
            // The downloaded zip's meta.json `input_mode` can lag behind
            // the backend's authoritative `ai_games.input_mode` (the value
            // the sidebar badge shows). Stamp the library value in before
            // previewing so play-time camera logic — which reads the
            // loaded game's meta — matches what the user sees in the list.
            // Must run before `preview()` (whose state transition kicks
            // off `syncCamera`) and before `markSnapshot` so the corrected
            // meta is part of the clean baseline.
            stampInputModeFromLibrary(into: target, gameId: gameId)
            let result = await GodotPreviewController.shared.preview(projectDir: target)
            switch result {
            case .success:
                NSLog("[GameLoader] preview OK")
                store.markActive(gameId)
                // What we just unpacked is byte-equivalent to what the
                // backend has, so the Publish button should start
                // disabled. It re-enables only after the user actually
                // edits the project.
                PublishController.shared.markSnapshot(dir: target)
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
        let resolvedDir: URL
        if fm.fileExists(atPath: gameDir.appendingPathComponent("project.godot").path) {
            resolvedDir = gameDir
        } else {
            // If a single subdirectory wraps the project, descend.
            let children = (try? fm.contentsOfDirectory(at: gameDir, includingPropertiesForKeys: nil)) ?? []
            if children.count == 1, children[0].hasDirectoryPath,
               fm.fileExists(atPath: children[0].appendingPathComponent("project.godot").path) {
                resolvedDir = children[0]
            } else {
                throw LoaderError.missingProject
            }
        }

        // Stamp the canonical game_id into the local meta.json so a
        // later re-publish from Motem Studio updates this same row on
        // the backend instead of creating a brand-new `mac_*` game.
        // The backend's zip does NOT carry `game_id` in meta.json, but
        // the directory name we just unpacked into is authoritative
        // (see `gameDirectory(for:)`).
        injectGameId(into: resolvedDir, gameId: gameId)
        return resolvedDir
    }

    /// Idempotent: overwrite the downloaded meta.json's `input_mode` with
    /// the authoritative value from the library list (`GameSummary`,
    /// sourced from `ai_games.input_mode` in the backend DB — the same
    /// field the sidebar badge renders). The zip's on-disk `input_mode`
    /// is frequently stale (`touch` / missing) even for body-pose games,
    /// which would otherwise leave the front camera off during play.
    /// No-op when the game isn't in the list or meta.json is unreadable.
    private static func stampInputModeFromLibrary(into projectDir: URL, gameId: String) {
        guard let summary = GameLibraryStore.shared.games.first(where: { $0.gameId == gameId }),
              let mode = summary.inputMode, !mode.isEmpty else { return }
        let metaURL = projectDir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if (dict["input_mode"] as? String) == mode { return }
        dict["input_mode"] = mode
        if let out = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? out.write(to: metaURL, options: .atomic)
        }
    }

    /// Idempotent: read meta.json, set `game_id` if missing or stale,
    /// write back only if changed. No-op when meta.json is missing or
    /// unparseable — `PublishController.writeMeta` has a sibling
    /// fallback that derives the id from the project directory name.
    private static func injectGameId(into projectDir: URL, gameId: String) {
        let metaURL = projectDir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if (dict["game_id"] as? String) == gameId { return }
        dict["game_id"] = gameId
        if let out = try? JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? out.write(to: metaURL, options: .atomic)
        }
    }
}
