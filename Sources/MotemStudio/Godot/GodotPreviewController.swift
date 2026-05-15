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
    /// Created eagerly at app launch with a stub project pinned to
    /// `_active`. The engine is a process-level singleton on macOS;
    /// keeping the app instance stable from start to finish prevents
    /// SwiftUI from re-mounting `NSGodotAppView` (which crashes the
    /// embedded display server's cursor handling).
    let godotApp: GodotApp
    #endif

    /// Absolute path most recently surfaced to the engine; nil until
    /// the first preview succeeds.
    @Published private(set) var currentProjectDir: URL?

    private init() {
        ActiveDirectorySync.ensureStubProject()
        #if canImport(SwiftGodotKit)
        self.godotApp = GodotApp(
            packFile: "",
            godotPackPath: ActiveDirectorySync.activeURL.path,
            displayDriver: "embedded"
        )
        #endif
    }

    var activeDirectoryPath: String { ActiveDirectorySync.activeURL.path }

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
        // The engine was booted on app launch with the stub project.
        // Switching to the new project is just a scene reload — same
        // path the agent will call again for godot_reload.
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
        if let dir = announcedProjectDir { state = .running(projectDir: dir) }
        return .success(statusPayload())
    }

    /// Unload the current scene without destroying the engine instance —
    /// Godot does not support re-creating GodotApp after destruction
    /// inside the same process.
    func stop() async -> BridgeResult {
        #if canImport(SwiftGodotKit)
        if let sceneTree = Engine.getMainLoop() as? SceneTree {
            sceneTree.unloadCurrentScene()
        }
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
        payload["booted"] = (godotApp.instance != nil)
        #else
        payload["booted"] = false
        #endif
        return payload
    }
}
