import Foundation
import SwiftUI

/// Owns the macOS-side authentication state with deskrobot-backend.
///
/// Tokens live in the Keychain (`KeychainHelper`); the user id /
/// display fields stay in `UserDefaults` for fast cold-start gating
/// without a Keychain prompt. JWT expiry is checked at boot so a
/// stale token doesn't leave us in a half-authenticated state.
@MainActor
final class AuthManager: ObservableObject {

    static let shared = AuthManager()

    @Published private(set) var isLoggedIn = false
    @Published private(set) var accessToken: String = ""
    @Published private(set) var userId: String = ""
    @Published private(set) var displayName: String = ""

    @Published var isWorking = false
    @Published var errorMessage: String?

    private static let accessTokenKey = "auth.accessToken"
    private static let refreshTokenKey = "auth.refreshToken"
    private static let userIdKey = "auth.userId"
    private static let displayNameKey = "auth.displayName"
    private static let deviceIdKey = "auth.deviceId"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        loadSavedCredentials()
    }

    // MARK: - Public ops

    func login(email: String, password: String) async {
        await runAuth(path: "/api/auth/login", body: [
            "email": email,
            "password": password,
            "device_id": deviceId(),
            "device_name": deviceName(),
        ])
    }

    func register(email: String, password: String, displayName: String) async {
        // Register endpoint returns user info; we immediately follow up
        // with a login to obtain access + refresh tokens.
        let registered = await postRaw(
            path: "/api/auth/register",
            body: [
                "email": email,
                "password": password,
                "display_name": displayName,
            ]
        )
        if registered == .success {
            await login(email: email, password: password)
        }
    }

    func logout() {
        KeychainHelper.delete(Self.accessTokenKey)
        KeychainHelper.delete(Self.refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userIdKey)
        UserDefaults.standard.removeObject(forKey: Self.displayNameKey)
        accessToken = ""
        userId = ""
        displayName = ""
        isLoggedIn = false
        errorMessage = nil
    }

    /// Called by `APIClient` when the backend returns 401 — the token
    /// is no longer valid, drop session state so the UI sends the user
    /// back to login.
    func handleUnauthorized() {
        guard isLoggedIn else { return }
        logout()
        errorMessage = L10n.string("auth.error.sessionExpired")
    }

    // MARK: - Persistence

    private func loadSavedCredentials() {
        guard let token = KeychainHelper.get(Self.accessTokenKey),
              !token.isEmpty,
              !isJWTExpired(token),
              let uid = UserDefaults.standard.string(forKey: Self.userIdKey),
              !uid.isEmpty else {
            return
        }
        accessToken = token
        userId = uid
        displayName = UserDefaults.standard.string(forKey: Self.displayNameKey) ?? ""
        isLoggedIn = true
        triggerPostLoginSync()
    }

    /// Kick off the template-bundle pull so the agent CLIs see an
    /// up-to-date scaffold before the user starts a session. Fire-and-
    /// forget; user can author against the cached `.template/` if the
    /// network call is slow or fails.
    private func triggerPostLoginSync() {
        Task { await TemplateBundleSync.shared.sync() }
    }

    // MARK: - Network

    private enum AuthOutcome { case success, failure }

    private struct LoginResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let user: UserPayload?

        struct UserPayload: Decodable {
            let id: String
            let email: String?
            let display_name: String?
        }
    }

    private func runAuth(path: String, body: [String: String]) async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        guard let url = URL(string: path, relativeTo: BackendConfig.baseURL) else {
            errorMessage = L10n.string("auth.error.badURL")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "Accept-Language")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = L10n.string("auth.error.network")
                return
            }
            if !(200..<300).contains(http.statusCode) {
                errorMessage = humanError(from: data, status: http.statusCode)
                return
            }
            let decoded = try JSONDecoder().decode(LoginResponse.self, from: data)
            apply(decoded)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Lightweight POST that doesn't unpack tokens (used by /register
    /// which only returns the new user shape — we follow with /login).
    private func postRaw(path: String, body: [String: String]) async -> AuthOutcome {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        guard let url = URL(string: path, relativeTo: BackendConfig.baseURL) else {
            errorMessage = L10n.string("auth.error.badURL")
            return .failure
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "Accept-Language")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                errorMessage = L10n.string("auth.error.network")
                return .failure
            }
            if !(200..<300).contains(http.statusCode) {
                errorMessage = humanError(from: data, status: http.statusCode)
                return .failure
            }
            return .success
        } catch {
            errorMessage = error.localizedDescription
            return .failure
        }
    }

    private func apply(_ payload: LoginResponse) {
        KeychainHelper.save(payload.access_token, for: Self.accessTokenKey)
        if let refresh = payload.refresh_token, !refresh.isEmpty {
            KeychainHelper.save(refresh, for: Self.refreshTokenKey)
        }
        accessToken = payload.access_token
        if let user = payload.user {
            userId = user.id
            displayName = user.display_name ?? user.email ?? ""
            UserDefaults.standard.set(user.id, forKey: Self.userIdKey)
            UserDefaults.standard.set(displayName, forKey: Self.displayNameKey)
        }
        isLoggedIn = true
        triggerPostLoginSync()
    }

    // MARK: - Helpers

    private func deviceId() -> String {
        if let stored = UserDefaults.standard.string(forKey: Self.deviceIdKey), !stored.isEmpty {
            return stored
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: Self.deviceIdKey)
        return fresh
    }

    private func deviceName() -> String {
        Host.current().localizedName ?? "Mac"
    }

    /// JWT format: header.payload.signature, base64url, no padding.
    /// `exp` is unix seconds.
    private func isJWTExpired(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return true }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return true
        }
        return Date().timeIntervalSince1970 > exp
    }

    private func humanError(from data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let detail = json["detail"] as? String {
            return detail
        }
        return L10n.string("auth.error.httpStatus", status)
    }
}
