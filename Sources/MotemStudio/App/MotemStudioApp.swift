import SwiftUI

@main
struct MotemStudioApp: App {
    @StateObject private var l10n = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
                .environment(\.locale, l10n.currentLocale)
                .environmentObject(l10n)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environment(\.locale, l10n.currentLocale)
                .environmentObject(l10n)
        }
    }
}
