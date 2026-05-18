import AppKit
import Foundation

/// Owns the "Publish" flow.
///
/// The macOS sheet mirrors the iPhone app's publish modal: the user picks
/// a title, an optional cover image, and a visibility tier. The
/// controller then:
///
/// 1. Writes those fields into `meta.json` so the zip is self-describing
///    even if the backend ever processes it offline.
/// 2. Zips the project and POSTs `/api/games`. Backend creates the row
///    and broadcasts `game_ready` to the user's iPhone.
/// 3. PATCHes `/api/games/{id}/visibility` so the backend honours the
///    chosen tier explicitly (zip-derived defaults vary by version).
/// 4. Uploads the cover via `POST /api/games/{id}/cover` if the user
///    picked one.
@MainActor
final class PublishController: ObservableObject {

    static let shared = PublishController()

    /// User-chosen visibility. Wire-format strings match the backend
    /// schema and the iOS app exactly so a game published from macOS is
    /// indistinguishable from one published on iPhone.
    enum Visibility: String, CaseIterable, Identifiable, Codable {
        case publicRemixable = "public_remixable"
        case publicViewOnly = "public_view_only"
        case privateOnly = "private"

        var id: String { rawValue }
    }

    /// Control style the published game expects on the player's device.
    /// Backend + iPhone both honour the same two literals — adding a
    /// macOS-only mode would silently break iPhone runtime, so users
    /// pick one of these even when the natural-language prompt to the
    /// local claude implied something more nuanced.
    enum InputMode: String, CaseIterable, Identifiable, Codable {
        case touch = "touch"
        case bodyPose = "body_pose"

        var id: String { rawValue }
    }

    enum State: Equatable {
        case idle
        case packaging
        case uploading
        case finalizing
        case success(gameId: String, message: String)
        case failed(reason: String)
    }

    @Published private(set) var state: State = .idle

    /// True when the currently-watched project has content the user
    /// hasn't published yet. The toolbar Publish button gates on this
    /// so an unchanged project shows a disabled button — re-uploading
    /// an identical zip is wasted work and confuses the iPhone (it'd
    /// just download the same game again).
    @Published private(set) var hasPendingChanges: Bool = false

    private var watchedDir: URL?
    private var pollingTimer: Timer?
    private static let snapshotsKey = "publishedFingerprints"

    private init() {}

    func reset() {
        state = .idle
    }

    // MARK: - Change tracking

    /// Begin polling the given project directory for content changes.
    /// Idempotent; passing `nil` stops watching. Called by the preview
    /// pane on appear and whenever `currentProjectDir` switches.
    func beginWatching(projectDir: URL?) {
        pollingTimer?.invalidate()
        pollingTimer = nil
        watchedDir = projectDir

        guard let dir = projectDir else {
            hasPendingChanges = false
            return
        }
        refreshPendingState(dir: dir)
        // 2 s is a good trade — fast enough that the user sees the
        // button enable shortly after the agent writes files, slow
        // enough that walking the project dir doesn't burn the main
        // thread on busy hosts.
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let dir = self.watchedDir else { return }
                self.refreshPendingState(dir: dir)
            }
        }
    }

    private func refreshPendingState(dir: URL) {
        let current = currentFingerprint(of: dir)
        let stored = storedFingerprint(for: dir)
        // Never published → button enabled the moment the project has
        // any content; nothing to compare against.
        if stored == 0 {
            hasPendingChanges = (current > 0)
        } else {
            hasPendingChanges = (current > stored)
        }
    }

    private func currentFingerprint(of dir: URL) -> TimeInterval {
        var maxTime: TimeInterval = 0
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey]
            ) else { continue }
            if values.isDirectory == true { continue }
            if let mtime = values.contentModificationDate {
                maxTime = max(maxTime, mtime.timeIntervalSince1970)
            }
        }
        return maxTime
    }

    private func storedFingerprint(for dir: URL) -> TimeInterval {
        let dict = UserDefaults.standard.dictionary(forKey: Self.snapshotsKey) as? [String: TimeInterval] ?? [:]
        return dict[dir.path] ?? 0
    }

    private func recordPublished(dir: URL) {
        markSnapshot(dir: dir)
    }

    /// Record the current on-disk state as the baseline against which
    /// future edits are compared. `hasPendingChanges` flips to false
    /// immediately, and the Publish button stays disabled until the
    /// user edits a file. Called from two paths:
    ///   - publish success (we just shipped this version to backend)
    ///   - GameLoader after extracting a downloaded game (the project
    ///     on disk is byte-equivalent to what backend has)
    func markSnapshot(dir: URL) {
        let fp = currentFingerprint(of: dir)
        var dict = UserDefaults.standard.dictionary(forKey: Self.snapshotsKey) as? [String: TimeInterval] ?? [:]
        dict[dir.path] = fp
        UserDefaults.standard.set(dict, forKey: Self.snapshotsKey)
        if watchedDir?.path == dir.path {
            hasPendingChanges = false
        }
    }

    /// Drive the full publish pipeline. Caller passes the form values
    /// collected by `PublishSheet`; everything else is derived from the
    /// project directory.
    func publish(
        projectDir: URL,
        title: String,
        visibility: Visibility,
        inputMode: InputMode,
        coverImageURL: URL?
    ) async {
        // 1. Stage meta.json so the zip carries the user's choices.
        state = .packaging
        do {
            try writeMeta(in: projectDir, title: title, visibility: visibility, inputMode: inputMode)
        } catch {
            state = .failed(reason: error.localizedDescription)
            return
        }

        // 2. Pack.
        let zipURL: URL
        do {
            zipURL = try await makeZip(of: projectDir)
        } catch {
            state = .failed(reason: error.localizedDescription)
            return
        }
        defer { try? FileManager.default.removeItem(at: zipURL) }

        // 3. Upload zip → get game_id.
        state = .uploading
        let gameId: String
        do {
            let zipData = try Data(contentsOf: zipURL)
            let response: PublishResponse = try await APIClient.shared.uploadFile(
                "/api/games",
                fileData: zipData,
                fileName: "\(projectDir.lastPathComponent).zip",
                mimeType: "application/zip"
            )
            gameId = response.gameId
        } catch {
            state = .failed(reason: error.localizedDescription)
            return
        }

        // 4. Finalize: explicit visibility PATCH + optional cover upload.
        // Failures here do NOT roll back the upload — the game is on the
        // backend at this point; we surface a softer warning instead.
        state = .finalizing
        var trailingWarnings: [String] = []
        do {
            _ = try await APIClient.shared.patchJSON(
                "/api/games/\(gameId)/visibility",
                body: VisibilityPatch(visibility: visibility.rawValue),
                as: EmptyResponse.self
            )
        } catch {
            trailingWarnings.append("visibility: \(error.localizedDescription)")
        }

        if let coverURL = coverImageURL {
            do {
                let imageData = try encodeCoverJPEG(from: coverURL)
                _ = try await APIClient.shared.uploadFile(
                    "/api/games/\(gameId)/cover",
                    fileData: imageData,
                    fileName: "cover.jpg",
                    mimeType: "image/jpeg",
                    fieldName: "image",
                    as: EmptyResponse.self
                )
            } catch {
                trailingWarnings.append("cover: \(error.localizedDescription)")
            }
        }

        let successCopy: String
        if trailingWarnings.isEmpty {
            successCopy = L10n.string("publish.success")
        } else {
            successCopy = L10n.string("publish.success") + "  (" + trailingWarnings.joined(separator: "; ") + ")"
        }
        // Re-sync src/ → _active/ so the embedded preview reflects
        // exactly what we just uploaded. Without this the user can sit
        // looking at a "pre-edit" preview while iPhone has already
        // pulled the new build — `writeMeta` mutated `src/meta.json`
        // between the last `godot_reload` and the publish, so the
        // local engine's `_active/` copy is stale by at least the
        // meta diff. Reload uses the same path the agent's
        // `godot_reload` MCP tool does.
        _ = await GodotPreviewController.shared.reload()
        state = .success(gameId: gameId, message: successCopy)
        // Lock in the fingerprint AFTER all our writes (meta.json,
        // cover upload may rewrite local cover.png in future), so the
        // button disables right away and only re-enables on the next
        // genuine edit.
        recordPublished(dir: projectDir)
        Task { await GameLibraryStore.shared.refresh() }
    }

    // MARK: - Meta

    /// Merge user-supplied fields into `meta.json`, preserving anything
    /// the AI agent already wrote (description_i18n, icon). The user's
    /// sheet choices for title / visibility / input_mode always win
    /// because the sheet is the explicit user intent — the AI's
    /// inferred values are only a default that the sheet prefills.
    private func writeMeta(
        in projectDir: URL,
        title: String,
        visibility: Visibility,
        inputMode: InputMode
    ) throws {
        let metaURL = projectDir.appendingPathComponent("meta.json")
        var payload: [String: Any] = [:]
        if let existing = try? Data(contentsOf: metaURL),
           let parsed = try? JSONSerialization.jsonObject(with: existing) as? [String: Any] {
            payload = parsed
        }
        // Carry the canonical game_id forward so the backend updates
        // this row in place rather than minting a fresh `mac_*` on
        // every re-publish. `GameLoader` stamps `game_id` into meta
        // on download; this fallback rescues legacy library entries
        // whose local meta predates that fix — the directory name is
        // the game_id by construction (sandbox/library/<id>/).
        if (payload["game_id"] as? String)?.isEmpty ?? true {
            let libraryRoot = AgentSandbox.directory
                .appendingPathComponent("library", isDirectory: true)
                .standardizedFileURL.path
            let parentPath = projectDir.deletingLastPathComponent()
                .standardizedFileURL.path
            if parentPath == libraryRoot {
                payload["game_id"] = projectDir.lastPathComponent
            }
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveTitle = trimmedTitle.isEmpty ? projectDir.lastPathComponent : trimmedTitle
        payload["title"] = effectiveTitle
        payload["title_i18n"] = ["en": effectiveTitle, "zh-Hans": effectiveTitle]
        payload["visibility"] = visibility.rawValue
        payload["input_mode"] = inputMode.rawValue
        if payload["description_i18n"] == nil {
            payload["description_i18n"] = ["en": "", "zh-Hans": ""]
        }
        if payload["icon"] == nil {
            payload["icon"] = "🎮"
        }
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: metaURL, options: .atomic)
    }

    /// Read the input mode currently stored in `meta.json` (whatever the
    /// AI agent decided last), defaulting to `.touch` when the field is
    /// absent or unrecognised.
    func currentInputMode(in projectDir: URL) -> InputMode {
        let metaURL = projectDir.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = dict["input_mode"] as? String,
           let mode = InputMode(rawValue: raw) {
            return mode
        }
        return .touch
    }

    /// Read the title currently stored in `meta.json`, if any. Used by
    /// the sheet to prefill the title field. Returns nil when there's no
    /// meta file or the title is empty — the caller falls back to the
    /// project directory name.
    func currentTitle(in projectDir: URL) -> String? {
        let metaURL = projectDir.appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let i18n = dict["title_i18n"] as? [String: String] {
            if let zh = i18n["zh-Hans"], !zh.isEmpty { return zh }
            if let en = i18n["en"], !en.isEmpty { return en }
        }
        if let title = dict["title"] as? String, !title.isEmpty { return title }
        return nil
    }

    /// Look for a cover image already shipped with the project. AI
    /// agents sometimes generate one alongside `project.godot`, and a
    /// previously-published game will have its uploaded cover here.
    /// `icon.png` is intentionally skipped — that's the Godot project
    /// icon (256×256), not a card-shaped cover.
    func existingCoverURL(in projectDir: URL) -> URL? {
        let fm = FileManager.default
        let candidates = ["cover.png", "cover.jpg", "cover.jpeg", "cover.webp", "thumbnail.png"]
        for name in candidates {
            let url = projectDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Read the visibility currently stored in `meta.json`, defaulting
    /// to `.privateOnly` so the user has to opt in to publishing.
    func currentVisibility(in projectDir: URL) -> Visibility {
        let metaURL = projectDir.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = dict["visibility"] as? String,
           let v = Visibility(rawValue: raw) {
            return v
        }
        return .privateOnly
    }

    // MARK: - Zip + cover encoding

    private func makeZip(of projectDir: URL) async throws -> URL {
        let zipPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("motem-publish-\(UUID().uuidString).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        // `-r .` packs everything under `projectDir` at the root of
        // the archive (no wrapping directory) — backend's POST handler
        // expects `project.godot` + `meta.json` at the zip top level.
        //
        // Strip host-side scaffolding from the upload: the local CLI's
        // permission grants (`.claude/`), Motem's sandbox boundary
        // marker (`.git/`), the cached backend template mirror
        // (`.template/`), OMC / per-agent config dirs, the clipboard
        // image staging area, and Finder cruft. None of these belong in
        // a game zip — they leak into iPhone storage and bloat
        // transfer time, sometimes carrying user-specific state.
        process.arguments = [
            "-r", "-q", zipPath.path, ".",
            "-x",
            ".claude/*", ".claude",
            ".git/*", ".git",
            ".template/*", ".template",
            ".config/*", ".config",
            ".omc/*", ".omc",
            ".pastes/*", ".pastes",
            "*/.claude/*", "*/.git/*", "*/.template/*",
            "*/.config/*", "*/.omc/*",
            ".DS_Store", "*/.DS_Store",
        ]
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

    /// Resize → JPEG (q=0.85). Matches the iOS app's conversion so the
    /// backend's PIL pipeline sees consistent inputs from both clients.
    private func encodeCoverJPEG(from url: URL, maxDimension: CGFloat = 1280) throws -> Data {
        guard let image = NSImage(contentsOf: url) else {
            throw PublishError.coverUnreadable(path: url.path)
        }
        let scale = min(1.0, maxDimension / max(image.size.width, image.size.height))
        let target = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1.0
        )
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw PublishError.coverEncodeFailed
        }
        return data
    }

    // MARK: - Types

    private struct VisibilityPatch: Encodable {
        let visibility: String
    }

    private struct EmptyResponse: Decodable {}

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
        case coverUnreadable(path: String)
        case coverEncodeFailed

        var errorDescription: String? {
            switch self {
            case .zipFailed(let code, let stderr):
                return "zip exit \(code): \(stderr)"
            case .coverUnreadable(let path):
                return "cover unreadable: \(path)"
            case .coverEncodeFailed:
                return "cover encode failed"
            }
        }
    }
}
