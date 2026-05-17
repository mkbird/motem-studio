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
    }
}
