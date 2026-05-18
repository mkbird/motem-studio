import Foundation
import SwiftUI

#if canImport(SwiftGodotKit)
import SwiftGodot
import SwiftGodotKit
#endif

/// Single owner of the in-process Godot engine.
///
/// Constraints honored from the iOS deskrobot deployment (see project
/// CLAUDE.md "AI 游戏创作系统"):
///
/// - **Process-level singleton**: `GodotApp` can be created exactly once
///   per app lifetime; its `--path` is locked after the first `start()`.
/// - **`_active` directory mode**: every preview rsyncs the source project
///   into a fixed directory and the engine reloads resources from there.
/// - **Reload sequence**: `unloadCurrentScene` → `ResourceLoader.load
///   (cacheMode: .ignoreDeep)` → `changeSceneToPacked` to dodge resource
///   and script caches.
@MainActor
final class GodotPreviewController: ObservableObject {

    static let shared = GodotPreviewController()

    enum State: Equatable {
        case idle
        case running(projectDir: URL)
        case failed(reason: String)
    }

    /// Default scene path used by the AI-generated game template.
    static let defaultScenePath = "res://scenes/main.tscn"

    @Published private(set) var state: State = .idle

    #if canImport(SwiftGodotKit)
    /// Booted lazily on the first `preview()` call. Initialising the
    /// embedded Godot engine triggers CoreAudio / display / file walks
    /// that fire a wave of TCC prompts (Documents / Downloads / Music /
    /// firewall / etc.) — none of which a terminal-only user should ever
    /// have to answer. We hold the engine in an Optional and the
    /// `GodotPreviewPane` keeps its embedded view *unmounted* until this
    /// is non-nil, then keeps it mounted for the rest of the app's
    /// lifetime (re-mounting crashes macOS's embedded display server).
    @Published private(set) var godotApp: GodotApp?
    #endif

    /// Absolute path most recently surfaced to the engine; nil until
    /// the first preview succeeds.
    @Published private(set) var currentProjectDir: URL? {
        didSet {
            // Keep the sandbox CLAUDE.md in sync so the local claude
            // knows whether it should default to editing the current
            // preview vs. spinning up a new game. AgentSandbox reads
            // back through its own mirrored cache so this stays a
            // simple imperative write.
            AgentSandbox.currentPreviewDir = currentProjectDir
            AgentSandbox.refreshPromptFiles()
            MacFaceDetector.shared.invalidateBridgeCache()
            ControlModePreference.shared.syncCamera()
        }
    }

    /// Mirrors `SceneTree.paused`. The preview pane uses this to flip
    /// the pause / resume icon and to overlay the PAUSED panel.
    @Published private(set) var paused: Bool = false

    /// Toggle Godot's `SceneTree.paused`. iOS calls this through the
    /// same path (`applyGamePaused` in GodotGameView). When the user
    /// brings up the pause panel the engine stops ticking but the
    /// scene tree stays loaded, so resuming is instantaneous and
    /// rerun is just a normal child-swap via the reload token.
    func setPaused(_ value: Bool) {
        paused = value
        #if canImport(SwiftGodotKit)
        if let sceneTree = Engine.getMainLoop() as? SceneTree {
            sceneTree.paused = value
        }
        #endif
        // Release the camera while paused; bring it back online on
        // resume so the player has live input the moment they tap
        // "continue".
        ControlModePreference.shared.syncCamera()
    }

    /// Re-sync the current project into `_active` and ask the host
    /// scene to reload its child. Identical effect to clicking the
    /// game in the library again — restarts the game from the
    /// beginning while leaving the embedded engine + host scene
    /// untouched.
    func rerun() async {
        guard let dir = currentProjectDir else { return }
        // Clear input state before unpausing, otherwise
        // `MacFaceDetector` reads the previous PLAYING run's leftover
        // `gameplay_active = true` and re-arms the camera before the
        // restarted game's START screen even appears.
        resetGameplayActiveFlag()
        setPaused(false)
        _ = await preview(projectDir: dir)
    }

    /// Synchronously write `gameplay_active = false` to the InputBridge
    /// autoload via SwiftGodot. Used by scene-swap entry points
    /// (`preview` / `rerun`) so that `MacFaceDetector` sees a clean
    /// post-swap state on its next reconcile tick and doesn't bring
    /// the camera up off the previous game's leftover flag.
    private func resetGameplayActiveFlag() {
        #if canImport(SwiftGodotKit)
        guard let app = godotApp else { return }
        app.runOnGodotThread {
            MainActor.assumeIsolated {
                if let bridge = MacOSInputAdapter.locateInputBridge() {
                    bridge.set(property: "gameplay_active", value: Variant(false))
                }
            }
        }
        #endif
    }

    private init() {
        // Intentionally empty. Everything below — stub project, engine
        // creation — is deferred to `ensureEngineBooted()` so we do not
        // pay the permission tax for users who never preview a game.
    }

    var activeDirectoryPath: String { ActiveDirectorySync.activeURL.path }

    #if canImport(SwiftGodotKit)
    /// Idempotent. First call creates `_active/` and boots Godot.
    private func ensureEngineBooted() {
        guard godotApp == nil else { return }
        ActiveDirectorySync.ensureStubProject()
        godotApp = GodotApp(
            packFile: "",
            godotPackPath: ActiveDirectorySync.activeURL.path,
            displayDriver: "embedded"
        )
    }
    #endif

    // MARK: - Public ops

    /// Mirror `projectDir` into `_active` and reload the engine's scene.
    func preview(projectDir: URL) async -> BridgeResult {
        // Clear the cross-platform input contract BEFORE unpausing, so
        // `MacFaceDetector.reconcileWithGameState`'s next poll sees a
        // fresh `gameplay_active = false` instead of the previous game's
        // leftover `true` (which would re-arm the camera before the
        // new game has even shown its START screen).
        resetGameplayActiveFlag()
        // Pause state is engine-wide (`SceneTree.paused`), so the next
        // game would inherit it from whatever the user did to the
        // previous one. Always start a fresh game unpaused.
        if paused { setPaused(false) }
        do {
            try ActiveDirectorySync.syncProjectToActive(srcDir: projectDir)
        } catch {
            let message = error.localizedDescription
            state = .failed(reason: message)
            return .failure(message)
        }

        currentProjectDir = projectDir

        #if canImport(SwiftGodotKit)
        // First preview triggers a one-time engine boot. Subsequent
        // previews are scene reloads through the same engine instance.
        ensureEngineBooted()
        return await reload(announcedProjectDir: projectDir)
        #else
        let message = "SwiftGodotKit not integrated"
        state = .failed(reason: message)
        return .failure(message)
        #endif
    }

    func reload() async -> BridgeResult {
        // Mirror the agent's latest edits from the source project into
        // _active. Without this, the on-disk files Godot reads are stale.
        if let dir = currentProjectDir {
            do {
                try ActiveDirectorySync.syncProjectToActive(srcDir: dir)
            } catch {
                let message = error.localizedDescription
                state = .failed(reason: message)
                return .failure(message)
            }
        }
        return await reload(announcedProjectDir: nil)
    }

    private func reload(announcedProjectDir: URL?) async -> BridgeResult {
        // No engine-level scene change: migueldeicaza's libgodot macOS
        // embedded display server crashes (SIGSEGV) in both
        // `DisplayServerEmbedded::cursor_set_shape` (during
        // `_flush_scene_change`) and `set_mouse_mode`. Instead, we drop
        // a fresh token into `_active/__motem_host__/reload_token.txt`
        // and let the host GDScript swap its child node on its next
        // polling tick. Host stays as `current_scene` forever, so
        // `_flush_scene_change` is never triggered.
        ActiveDirectorySync.touchReloadToken()
        // InputBridge node persists at `/root/InputBridge` (host
        // autoload), but the cached weak reference belongs to the
        // previous frame's lookup — force a re-resolve next pump tick.
        MacOSInputAdapter.shared.invalidateBridgeCache()
        if let dir = announcedProjectDir { state = .running(projectDir: dir) }
        // Engine is now fully booted. Re-sync the camera here rather
        // than from `currentProjectDir.didSet` — starting AVCapture
        // during `Main::setup2()` races with the embedded display
        // server init and SIGABRTs.
        ControlModePreference.shared.syncCamera()
        return .success(statusPayload())
    }

    /// User-triggered stop. Equivalent to the iPhone app's
    /// `AppState.stopGame()`: hide the engine pane (state → .idle),
    /// forget the current project, release the front camera, and
    /// de-activate the library row. Called both from the preview
    /// pane's Stop button and from agents that invoke the
    /// `godot_stop` MCP tool.
    ///
    /// CRITICAL: do NOT call `SceneTree.unloadCurrentScene()` here.
    /// The Motem host scene must stay as `current_scene` for the
    /// lifetime of the process — that scene polls
    /// `_active/__motem_host__/reload_token.txt` to swap its child
    /// when the user picks the next game. Unloading the host leaves
    /// no one to read the token, and the next preview shows a white
    /// frame because the engine's `current_scene` is dead. The pane's
    /// overlay layer hides the engine visually while `state == .idle`,
    /// which is enough.
    func stop() async -> BridgeResult {
        #if canImport(SwiftGodotKit)
        currentProjectDir = nil
        state = .idle
        GameLibraryStore.shared.clearActive()
        ControlModePreference.shared.syncCamera()
        return .success(statusPayload())
        #else
        return .failure("SwiftGodotKit not integrated")
        #endif
    }

    /// Capture the current Godot viewport directly from the GPU and
    /// write it to `~/Downloads/`. Reading from the engine texture
    /// dodges the Screen Recording permission entirely and the PNG
    /// only contains what the player sees — never Motem Studio's
    /// chrome. Same source the iPhone app reads from when it screencaps.
    func screenshot() throws -> URL {
        #if canImport(SwiftGodotKit)
        guard godotApp != nil else {
            throw ScreenshotError.engineNotRunning
        }
        guard let sceneTree = Engine.getMainLoop() as? SceneTree,
              let viewport = sceneTree.root else {
            throw ScreenshotError.viewportMissing
        }
        guard let image = viewport.getTexture()?.getImage() else {
            throw ScreenshotError.captureFailed
        }
        let bytes = Array(image.savePngToBuffer())
        let data = Data(bytes)

        let fm = FileManager.default
        let downloads = (try? fm.url(
            for: .downloadsDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Downloads", isDirectory: true)

        let stamp = Self.filenameDateFormatter.string(from: Date())
        let title = currentProjectDir?.lastPathComponent ?? "game"
        let safeTitle = title.replacingOccurrences(of: "/", with: "_")
        let url = downloads.appendingPathComponent("MotemStudio_\(safeTitle)_\(stamp).png")
        try data.write(to: url, options: .atomic)
        return url
        #else
        throw ScreenshotError.engineNotRunning
        #endif
    }

    private static let filenameDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd-HHmmss"
        return df
    }()

    enum ScreenshotError: LocalizedError {
        case engineNotRunning
        case viewportMissing
        case captureFailed

        var errorDescription: String? {
            switch self {
            case .engineNotRunning: return "Godot engine isn't running"
            case .viewportMissing:  return "Viewport unavailable"
            case .captureFailed:    return "Could not read viewport texture"
            }
        }
    }

    func statusPayload() -> [String: Any] {
        var payload: [String: Any] = [
            "active_dir": ActiveDirectorySync.activeURL.path,
        ]
        switch state {
        case .idle:
            payload["state"] = "idle"
        case .running(let dir):
            payload["state"] = "running"
            payload["project_dir"] = dir.path
        case .failed(let reason):
            payload["state"] = "failed"
            payload["error"] = reason
        }
        #if canImport(SwiftGodotKit)
        payload["booted"] = (godotApp?.instance != nil)
        #else
        payload["booted"] = false
        #endif
        return payload
    }
}
