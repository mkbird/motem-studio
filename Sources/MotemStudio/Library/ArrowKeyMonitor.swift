import AppKit
import Foundation

/// Global ↑/↓ interceptor for the game library.
///
/// SwiftTerm's terminal view claims first-responder status as soon as
/// it mounts. SwiftUI's `.focusable() + .onKeyPress` therefore never
/// see arrow keys — AppKit dispatches them straight to the PTY. We
/// install one window-local `NSEvent` monitor at app launch and gate it
/// on whether the user's mouse is currently inside the sidebar. That
/// hover signal is provided by `GameLibrarySidebar` via `setHovered`.
@MainActor
final class ArrowKeyMonitor {

    static let shared = ArrowKeyMonitor()

    private(set) var hovered: Bool = false
    var navigate: ((Int) -> Void)?

    private var token: Any?

    private init() {}

    /// Idempotent install. Safe to call from `App.init`.
    func ensureInstalled() {
        guard token == nil else { return }
        log("install monitor")
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    func setHovered(_ value: Bool) {
        hovered = value
        if value {
            // Drop the terminal's keyboard focus the moment the mouse
            // enters the sidebar. With no first responder, SwiftTerm
            // can't receive keyDown — our monitor is the only path
            // arrow keys take. When the user moves back to the
            // terminal they have to click into it to type, which
            // matches macOS-native sidebar-vs-editor behaviour.
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 126 || event.keyCode == 125 else {
            return event
        }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifierKeys: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        if !mods.intersection(modifierKeys).isEmpty {
            log("modifier present → passthrough kc=\(event.keyCode)")
            return event
        }
        guard hovered else {
            log("not hovering sidebar → passthrough kc=\(event.keyCode)")
            return event
        }
        let step = event.keyCode == 126 ? -1 : 1
        log("intercept kc=\(event.keyCode) step=\(step)")
        navigate?(step)
        return nil
    }

    // MARK: - Debug log

    private static let logURL = URL(fileURLWithPath: "/tmp/motem-arrow.log")

    private func log(_ message: String) {
        let line = "[\(Date())] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: Self.logURL) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: Self.logURL)
        }
    }
}
