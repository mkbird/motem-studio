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

    /// Bring `MacFaceDetector` in line with the current pick + whether
    /// a body-pose game is currently loaded and not paused. The camera
    /// pre-warms at game load (rather than waiting for the player to
    /// tap "start") so the AVCaptureSession's ~200-300 ms boot overlaps
    /// with reading the START screen — by tap time, `face_position` is
    /// already flowing into `/root/InputBridge` and there's no
    /// perceived input gap. Pause and game-unload still release it.
    func syncCamera() {
        let controller = GodotPreviewController.shared
        // Starting AVCaptureSession DURING Godot's `Main::setup2()` races
        // with the embedded display server / Metal init and SIGABRTs the
        // process. Only pre-warm once the engine is fully booted; the
        // controller calls `syncCamera()` again the moment it transitions
        // to `.running`, so the camera still goes up before the player
        // can tap "start".
        let engineRunning: Bool
        if case .running = controller.state { engineRunning = true } else { engineRunning = false }
        let wantsCamera = engineRunning
            && (inputMode == .bodyPose)
            && (controller.currentProjectDir != nil)
            && !controller.paused
        if wantsCamera {
            MacFaceDetector.shared.startWatching()
        } else {
            MacFaceDetector.shared.stopWatching()
        }
    }
}
