import SwiftUI

@main
struct MotemStudioApp: App {
    @StateObject private var l10n = LocalizationManager.shared
    @StateObject private var bridge = MCPBridgeServer.shared
    @StateObject private var godot = GodotPreviewController.shared

    init() {
        // Sandbox layout and the MCP bridge are both deferred to the
        // first agent terminal session — see `AgentTerminalView.start()`.
        // Doing them eagerly here triggers a wave of TCC prompts
        // (firewall, Documents / Downloads / Music) on first launch
        // before the user has a chance to opt into anything.
        //
        // The arrow-key monitor is wired up here, however: the user
        // expects keyboard navigation to work from the moment the
        // library appears, and the install is free until the first key
        // press lands.
        ArrowKeyMonitor.shared.ensureInstalled()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 720)
                .environment(\.locale, l10n.currentLocale)
                .environmentObject(l10n)
                .environmentObject(bridge)
                .environmentObject(godot)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(\.locale, l10n.currentLocale)
                .environmentObject(l10n)
                .environmentObject(bridge)
                .environmentObject(godot)
        }
    }
}
