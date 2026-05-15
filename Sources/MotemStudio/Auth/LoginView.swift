import SwiftUI

/// Sign-in / sign-up panel. Rendered as the root view while
/// `AuthManager.isLoggedIn` is `false` so no MCP / engine plumbing runs
/// before a user identity exists.
struct LoginView: View {
    @ObservedObject private var auth = AuthManager.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var serverHost = BackendConfig.serverHost
    @State private var showHostField = false

    enum Mode {
        case signIn, signUp
    }

    var body: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()

            VStack(spacing: 20) {
                header

                VStack(spacing: 14) {
                    if mode == .signUp {
                        TextField(L10n.string("auth.field.displayName"), text: $displayName)
                            .textFieldStyle(.roundedBorder)
                    }
                    TextField(L10n.string("auth.field.email"), text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
                    SecureField(L10n.string("auth.field.password"), text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(mode == .signIn ? .password : .newPassword)

                    if showHostField {
                        TextField(L10n.string("auth.field.serverHost"), text: $serverHost)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: serverHost) { newValue in
                                BackendConfig.serverHost = newValue
                            }
                    }
                }
                .frame(maxWidth: 360)

                if let message = auth.errorMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }

                primaryButton

                HStack(spacing: 16) {
                    Button(action: toggleMode) {
                        Text(L10n.string(mode == .signIn ? "auth.toggle.toSignUp" : "auth.toggle.toSignIn"))
                            .font(.callout)
                    }
                    .buttonStyle(.link)
                    Button(action: { showHostField.toggle() }) {
                        Text(L10n.string(showHostField ? "auth.server.hide" : "auth.server.show"))
                            .font(.callout)
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(NSColor.controlBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 18, y: 4)
            )
            .frame(maxWidth: 460)
            .padding(40)
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 36))
                .foregroundStyle(.tint)
            T("auth.brand.name")
                .font(.title2.weight(.semibold))
            T(mode == .signIn ? "auth.signIn.subtitle" : "auth.signUp.subtitle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var primaryButton: some View {
        Button(action: submit) {
            HStack {
                if auth.isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
                T(mode == .signIn ? "auth.button.signIn" : "auth.button.signUp")
                    .font(.body.weight(.medium))
            }
            .frame(maxWidth: 220, minHeight: 28)
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(!canSubmit || auth.isWorking)
    }

    private var canSubmit: Bool {
        let emailOK = email.contains("@") && email.count > 3
        let passOK = password.count >= 6
        let nameOK = mode == .signIn || !displayName.trimmingCharacters(in: .whitespaces).isEmpty
        return emailOK && passOK && nameOK
    }

    private func toggleMode() {
        mode = (mode == .signIn) ? .signUp : .signIn
        auth.errorMessage = nil
    }

    private func submit() {
        Task {
            switch mode {
            case .signIn:
                await auth.login(email: email, password: password)
            case .signUp:
                await auth.register(email: email, password: password, displayName: displayName)
            }
        }
    }
}
