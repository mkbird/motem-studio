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
        }
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
        return .success(statusPayload())
    }

    /// Unload the current scene without destroying the engine instance —
    /// Godot does not support re-creating GodotApp after destruction
    /// inside the same process.
    func stop() async -> BridgeResult {
        #if canImport(SwiftGodotKit)
        // Nothing to stop if the engine was never booted.
        guard godotApp != nil else {
            state = .idle
            return .success(statusPayload())
        }
        if let sceneTree = Engine.getMainLoop() as? SceneTree {
            sceneTree.unloadCurrentScene()
        }
        currentProjectDir = nil
        state = .idle
        return .success(statusPayload())
        #else
        return .failure("SwiftGodotKit not integrated")
        #endif
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
