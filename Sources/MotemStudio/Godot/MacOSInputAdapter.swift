import AppKit
import Foundation
import SwiftUI

#if canImport(SwiftGodotKit)
import SwiftGodot
import SwiftGodotKit
#endif

/// Bridges macOS keyboard / mouse / trackpad input into Godot's
/// `/root/InputBridge` autoload so AI-generated games written for the
/// iOS body-pose contract can run unmodified on macOS.
///
/// Contract (mirrors `deskrobot-ios/GodotGameView.swift::startInputPump`):
///
/// | InputBridge property | macOS source                                      |
/// |----------------------|---------------------------------------------------|
/// | body_lean_x          | A/D and ←/→  (±1 when pressed, 0 when released)   |
/// | body_lean_y          | W/S and ↑/↓                                       |
/// | is_reaching_out      | left mouse button held                            |
/// | is_ducking           | shift held                                        |
/// | is_hands_up          | space held                                        |
/// | body_detected        | constant `true`                                   |
/// | face_position        | mouse position normalised inside the preview pane |
/// | face_detected        | constant `true`                                   |
/// | hand_gesture         | digit keys 1–7 select none/fist/thumbsUp/peace/   |
/// |                      | ok/heart/wave (defaults to none)                  |
/// | hand_position        | same as face_position                             |
///
/// The pane's screen frame is updated from `GodotPreviewPane` via a
/// `GeometryReader` so coordinate normalisation always matches the
/// actual viewport the user sees, not the underlying 1194×834 design
/// resolution (Godot's `stretch_mode=canvas_items` handles the design
/// scaling separately).
@MainActor
final class MacOSInputAdapter: ObservableObject {

    static let shared = MacOSInputAdapter()

    /// Pump frequency mirrors the iOS face-detection pump (30 Hz).
    private static let pumpHz: Double = 30.0

    /// Hand gestures recognised on the iOS side. macOS users cycle
    /// through them with the number keys; default is `none`.
    private static let gestures: [UInt16: String] = [
        Keycode.one:   "none",
        Keycode.two:   "fist",
        Keycode.three: "thumbsUp",
        Keycode.four:  "peace",
        Keycode.five:  "ok",
        Keycode.six:   "heart",
        Keycode.seven: "wave",
    ]

    // MARK: - State (main actor only)

    /// Frame of `GodotPreviewPane` in SwiftUI's `.global` coordinate
    /// space (top-left origin = window content top-left). Updated by
    /// `GodotPreviewPane.geometryChanged()` on every layout pass.
    var paneWindowFrame: CGRect = .zero

    private(set) var isRunning = false

    private var pumpTimer: Foundation.Timer?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var flagsMonitor: Any?

    private var pressedKeys = Set<UInt16>()
    /// Cached normalised mouse position, top-left origin. Defaults to
    /// the centre so games that read `face_position` before the user
    /// moves the mouse don't think the player is in a corner.
    private var mouseNorm = CGPoint(x: 0.5, y: 0.5)
    private var leftMouseDown = false
    private var currentGesture: String = "none"

    #if canImport(SwiftGodotKit)
    /// Cached `/root/InputBridge` node so we don't re-walk the scene
    /// tree on every pump. Cleared by `invalidateBridgeCache()` whenever
    /// the host scene swaps its loaded child (each `godot_preview` /
    /// `godot_reload`).
    private weak var cachedBridge: SwiftGodot.Node?
    #endif

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        installMonitors()
        installPump()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        pumpTimer?.invalidate()
        pumpTimer = nil
        [keyMonitor, mouseMonitor, flagsMonitor].forEach { token in
            if let token { NSEvent.removeMonitor(token) }
        }
        keyMonitor = nil
        mouseMonitor = nil
        flagsMonitor = nil
        pressedKeys.removeAll()
        leftMouseDown = false
        currentGesture = "none"
        isRunning = false
    }

    // MARK: - Monitors

    private func installMonitors() {
        // Local monitors only fire while the app is active. Returning
        // the event back keeps normal SwiftUI / SwiftTerm focus
        // handling intact — we are an observer, not an interceptor.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            self?.handleKey(event)
            return event
        }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlags(event)
            return event
        }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        ]) { [weak self] event in
            self?.handleMouse(event)
            return event
        }
    }

    private func handleKey(_ event: NSEvent) {
        // Skip auto-repeat — we already track the held state.
        if event.isARepeat { return }
        if event.type == .keyDown {
            pressedKeys.insert(event.keyCode)
            if let gesture = Self.gestures[event.keyCode] {
                currentGesture = gesture
            }
        } else if event.type == .keyUp {
            pressedKeys.remove(event.keyCode)
        }
    }

    private func handleFlags(_ event: NSEvent) {
        // Shift is a modifier — track via flagsChanged so we don't
        // miss the up edge that .keyUp never fires for modifiers.
        let shiftDown = event.modifierFlags.contains(.shift)
        if shiftDown {
            pressedKeys.insert(Keycode.shift)
        } else {
            pressedKeys.remove(Keycode.shift)
        }
    }

    private func handleMouse(_ event: NSEvent) {
        if event.type == .leftMouseDown { leftMouseDown = true }
        if event.type == .leftMouseUp { leftMouseDown = false }
        recomputeMouseNorm()
    }

    private func recomputeMouseNorm() {
        guard paneWindowFrame.width > 0, paneWindowFrame.height > 0,
              let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else { return }
        // NSEvent gives the mouse location in window coordinates with
        // an AppKit bottom-left origin. SwiftUI's `.global` frame uses
        // a top-left origin. Flip Y against the content view height to
        // line the two up before subtracting the pane's origin.
        let mouseInWindow = window.mouseLocationOutsideOfEventStream
        let contentHeight = contentView.bounds.height
        let mouseTopLeftY = contentHeight - mouseInWindow.y
        let xInPane = (mouseInWindow.x - paneWindowFrame.minX) / paneWindowFrame.width
        let yInPane = (mouseTopLeftY - paneWindowFrame.minY) / paneWindowFrame.height
        mouseNorm = CGPoint(
            x: max(0, min(1, xInPane)),
            y: max(0, min(1, yInPane))
        )
    }

    // MARK: - Pump

    private func installPump() {
        // Use Foundation.Timer (not DispatchSourceTimer) so it auto-
        // ties to RunLoop.main and pauses when the app sleeps.
        let timer = Foundation.Timer.scheduledTimer(
            withTimeInterval: 1.0 / Self.pumpHz,
            repeats: true
        ) { [weak self] _ in
            // Timer fires on the main thread RunLoop, which is the
            // same actor we live on; hop explicitly to keep the
            // compiler happy under strict concurrency.
            Task { @MainActor in
                self?.pump()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pumpTimer = timer
    }

    private func pump() {
        #if canImport(SwiftGodotKit)
        guard let app = GodotPreviewController.shared.godotApp,
              app.instance != nil else { return }

        // Snapshot every value while we're on the main actor; the
        // Godot-thread closure then sees a simple value capture.
        let leanX = currentLean(positive: Keycode.d, negative: Keycode.a,
                                altPositive: Keycode.rightArrow, altNegative: Keycode.leftArrow)
        let leanY = currentLean(positive: Keycode.s, negative: Keycode.w,
                                altPositive: Keycode.downArrow, altNegative: Keycode.upArrow)
        let isReachingOut = leftMouseDown
        let isDucking = pressedKeys.contains(Keycode.shift)
        let isHandsUp = pressedKeys.contains(Keycode.space)
        let gesture = currentGesture
        let mouseX = Float(mouseNorm.x)
        let mouseY = Float(mouseNorm.y)

        // SwiftGodotKit drives Godot iteration on the main thread, so
        // `runOnGodotThread` actually invokes us back on the same actor
        // we already live on. `assumeIsolated` lets us touch
        // `@MainActor` state inside without an async hop.
        app.runOnGodotThread {
            MainActor.assumeIsolated {
                let bridge: SwiftGodot.Node
                if let cached = self.cachedBridge {
                    bridge = cached
                } else if let found = Self.locateInputBridge() {
                    self.cachedBridge = found
                    bridge = found
                } else {
                    return // No InputBridge in the current scene tree.
                }

                // When the live front-camera tracker is running, it
                // owns the face/body fields — clobbering them from
                // the keyboard would flicker the player position
                // between camera tracking and last keystroke at 30 Hz.
                // We still drive the gesture + hand_position pair
                // because the camera path doesn't compute those.
                let cameraOwnsFace = MacFaceDetector.shared.isActive
                if !cameraOwnsFace {
                    bridge.set(property: "body_lean_x", value: Variant(leanX))
                    bridge.set(property: "body_lean_y", value: Variant(leanY))
                    bridge.set(property: "body_detected", value: Variant(true))
                    bridge.set(property: "face_position", value: Variant(Vector2(x: mouseX, y: mouseY)))
                    bridge.set(property: "face_detected", value: Variant(true))
                }
                bridge.set(property: "is_reaching_out", value: Variant(isReachingOut))
                bridge.set(property: "is_ducking", value: Variant(isDucking))
                bridge.set(property: "is_hands_up", value: Variant(isHandsUp))
                bridge.set(property: "hand_gesture", value: Variant(gesture))
                bridge.set(property: "hand_position", value: Variant(Vector2(x: mouseX, y: mouseY)))
            }
        }
        #endif
    }

    #if canImport(SwiftGodotKit)
    /// `/root/InputBridge` is always available — `ActiveDirectorySync`
    /// registers the host's `input_bridge.gd` as an engine autoload so
    /// it stays valid across host child swaps. Any AI-generated game
    /// that targets the same contract reads the same node.
    static func locateInputBridge() -> SwiftGodot.Node? {
        guard let sceneTree = Engine.getMainLoop() as? SceneTree,
              let root = sceneTree.root else { return nil }
        return root.getNodeOrNull(path: "InputBridge")
    }
    #endif

    /// Forget the cached InputBridge reference. Call after the host
    /// scene swaps its child node (every `godot_preview` /
    /// `godot_reload`) — the new game's InputBridge node is a
    /// different instance even if the path is the same.
    func invalidateBridgeCache() {
        #if canImport(SwiftGodotKit)
        cachedBridge = nil
        #endif
    }

    private func currentLean(positive: UInt16, negative: UInt16,
                             altPositive: UInt16, altNegative: UInt16) -> Float {
        let pos = pressedKeys.contains(positive) || pressedKeys.contains(altPositive)
        let neg = pressedKeys.contains(negative) || pressedKeys.contains(altNegative)
        return (pos ? 1 : 0) - (neg ? 1 : 0)
    }
}

// MARK: - macOS virtual key codes (kVK_*)

/// Minimal subset of Apple's virtual key codes (Carbon `kVK_*` constants).
/// We hold our own table so the adapter does not pull in HIToolbox.
private enum Keycode {
    static let a:           UInt16 = 0x00
    static let s:           UInt16 = 0x01
    static let d:           UInt16 = 0x02
    static let w:           UInt16 = 0x0D
    static let one:         UInt16 = 0x12
    static let two:         UInt16 = 0x13
    static let three:       UInt16 = 0x14
    static let four:        UInt16 = 0x15
    static let six:         UInt16 = 0x16
    static let five:        UInt16 = 0x17
    static let seven:       UInt16 = 0x1A
    static let space:       UInt16 = 0x31
    static let shift:       UInt16 = 0x38
    static let leftArrow:   UInt16 = 0x7B
    static let rightArrow:  UInt16 = 0x7C
    static let downArrow:   UInt16 = 0x7D
    static let upArrow:     UInt16 = 0x7E
}
