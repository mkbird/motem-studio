import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var l10n: LocalizationManager
    @AppStorage("DefaultAgent") private var defaultAgent: Agent = .claude

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(
                    get: { l10n.language },
                    set: { l10n.setLanguage($0) }
                )) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                } label: {
                    T("settings.language.label")
                }
                .pickerStyle(.inline)

                T("settings.language.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(selection: $defaultAgent) {
                    ForEach(Agent.allCases) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                } label: {
                    T("settings.agent.label")
                }
                .pickerStyle(.inline)

                T("settings.agent.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
