import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject var l10n: LocalizationManager
    @ObservedObject private var auth = AuthManager.shared
    @AppStorage("DefaultAgent") private var defaultAgent: Agent = .claude
    @State private var showingLogoutConfirmation = false

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(accountName)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    T("settings.account.label")
                }

                Button(role: .destructive) {
                    showingLogoutConfirmation = true
                } label: {
                    T("settings.account.logout")
                }
                .disabled(!auth.isLoggedIn)
            }

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
        .alert(L10n.string("settings.account.logout.confirm.title"), isPresented: $showingLogoutConfirmation) {
            Button(L10n.string("settings.account.logout.cancel"), role: .cancel) {}
            Button(L10n.string("settings.account.logout.confirm"), role: .destructive) {
                auth.logout()
            }
        } message: {
            Text(L10n.string("settings.account.logout.confirm.message"))
        }
    }

    private var accountName: String {
        if !auth.displayName.isEmpty { return auth.displayName }
        if !auth.userId.isEmpty { return auth.userId }
        return L10n.string("settings.account.notSignedIn")
    }
}
