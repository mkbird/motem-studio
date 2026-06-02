import Foundation
import SwiftUI

/// Persistent user choice for how the game-being-authored is meant to be
/// controlled on the player's device. Lives on `UserDefaults` so it
/// survives relaunch and is the single source the rest of the app
/// reads (`AgentSandbox` to inform the local claude, `PublishController`
/// to stamp `meta.json` on upload, `ControlModeBar` to render the
/// toggle).
///
/// The two cases mirror the backend's `meta.json` schema verbatim so a
/// macOS-authored game looks identical to an iPhone-authored one:
///   - `touch`     — tap input only; iPhone keeps the camera off
///   - `body_pose` — body / face controls; iPhone opens the front
///                   camera and feeds `/root/InputBridge`
@MainActor
final class ControlModePreference: ObservableObject {

    static let shared = ControlModePreference()

    private static let storageKey = "Motem.controlMode"

    @Published private(set) var inputMode: PublishController.InputMode

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.storageKey) ?? ""
        self.inputMode = PublishController.InputMode(rawValue: raw) ?? .touch
    }

    func set(_ mode: PublishController.InputMode) {
        guard mode != inputMode else { return }
        inputMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.storageKey)
        // Rewrite the sandbox CLAUDE.md so the local claude sees the
        // new preference on its next prompt. Without this the AI would
        // keep writing `input_mode` based on the previous user choice
        // (or whatever it inferred from the conversation).
        AgentSandbox.refreshPromptFiles()
        syncCamera()
    }

    /// Bring `MacFaceDetector` in line with whether the *loaded game* is
    /// a body-pose game, and whether it is currently running / not paused.
    ///
    /// Whether the camera powers on is a PLAY-TIME decision driven by the
    /// loaded game's own `input_mode` (`meta.json`) — NOT this toolbar
    /// `inputMode` pick, which only expresses AUTHORING intent (what the
    /// local agent should generate / what Publish stamps). A body-pose
    /// game powers the front camera; a touch game never does, whatever the
    /// toolbar says. The one exception is a brand-new project still being
    /// authored that has not declared `input_mode` yet: there we fall back
    /// to the toolbar pick so the in-progress preview stays testable.
    func syncCamera() {
        let controller = GodotPreviewController.shared
        // Starting AVCaptureSession DURING Godot's `Main::setup2()` races
        // with the embedded display server / Metal init and SIGABRTs the
        // process. Only watch once the engine is fully booted; the
        // controller calls `syncCamera()` again the moment it transitions
        // to `.running`.
        let engineRunning: Bool
        if case .running = controller.state { engineRunning = true } else { engineRunning = false }
        // PLAY-TIME source of truth: the loaded game's declared input_mode.
        // Fall back to the authoring toolbar pick only when the game has
        // not declared one yet (no meta / no field).
        let gameMode = controller.currentGameInputMode
        let gameIsBodyPose = gameMode != nil
            ? (gameMode == PublishController.InputMode.bodyPose.rawValue)
            : (inputMode == .bodyPose)
        let wantsCamera = engineRunning
            && gameIsBodyPose
            && (controller.currentProjectDir != nil)
            && !controller.paused
        if wantsCamera {
            MacFaceDetector.shared.startWatching()
        } else {
            MacFaceDetector.shared.stopWatching()
        }
    }
}
