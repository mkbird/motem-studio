import SwiftUI

@main
struct MotemStudioApp: App {
    @StateObject private var l10n = LocalizationManager.shared
    @StateObject private var bridge = MCPBridgeServer.shared
    @StateObject private var godot = GodotPreviewController.shared

    init() {
        // Start the unix-socket MCP bridge as soon as the app process
        // exists so any agent terminal spawned afterward can connect.
        MCPBridgeServer.shared.start()
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
