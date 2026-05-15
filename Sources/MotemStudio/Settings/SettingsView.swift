import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label(L10n.string("settings.tab.general"), systemImage: "gearshape")
                }
        }
        .frame(width: 480, height: 320)
    }
}
