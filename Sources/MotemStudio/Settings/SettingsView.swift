import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label(L10n.string("settings.tab.general"), systemImage: "gearshape")
                }
            PreviewSettingsView()
                .tabItem {
                    Label(L10n.string("settings.tab.preview"), systemImage: "play.rectangle")
                }
        }
        .frame(width: 540, height: 360)
    }
}
