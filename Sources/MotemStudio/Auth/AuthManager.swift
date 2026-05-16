import Foundation
import SwiftUI

/// Owns the macOS-side authentication state with deskrobot-backend.
///
/// Persistence
/// - `access_token` + `refresh_token` live in the macOS Keychain
///   (`KeychainHelper`), scoped to this app.
/// - `user.id` and `display_name` are mirrored to `UserDefaults` for a
///   fast cold-start guard that doesn't need a Keychain prompt.
///
/// Cold-start flow
/// 1. Valid access token → restore session synchronously and let the
///    UI render the workspace immediately. A background task backfills
///    `user.id` from `/api/auth/me` if it's missing (e.g., users on a
///    pre-refresh-token build whose Keychain is from before we started
///    persisting user info) and kicks off `TemplateBundleSync`.
/// 2. Access token expired but refresh token present → bootstrap an
///    async `/api/auth/refresh` round-trip, then `/me`. The UI sits on
///    a "restoring session" placeholder until that resolves rather
///    than flashing the login form.
/// 3. No refresh token (or refresh failed) → fall through to login.
///
/// Active-session 401 → try a silent refresh; only force a logout if
/// the refresh round-trip also fails.
@MainActor
final class AuthManager: ObservableObject {

    static let shared = AuthManager()

    /// Temporary kill-switch for the login gate. When true, a cold start
    /// without a Keychain token still drops the user straight into the
    /// workspace as a synthetic "local" guest. Backend-driven features
    /// (template sync, library, publish) become no-ops since the token
    /// is empty — terminals and the Godot preview pane still work.
    /// Flip this back to `false` before shipping a production build.
    static let bypassAuthForLocalUse = true

    @Published private(set) var isLoggedIn = false
    @Published private(set) var isBootstrapping = false
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

    // MARK: - Public auth ops

    func login(email: String, password: String) async {
        isWorking = true; errorMessage = nil
        defer { isWorking = false }
        guard let tokens = await postTokenEndpoint(
            path: "/api/auth/login",
            body: [
                "email": email,
                "password": password,
                "device_id": deviceId(),
                "device_name": deviceName(),
            ]
        ) else { return }
        await applyTokens(tokens)
    }

    func register(email: String, password: String, displayName: String) async {
        isWorking = true; errorMessage = nil
        let registered = await postRaw(
            path: "/api/auth/register",
            body: [
                "email": email,
                "password": password,
                "display_name": displayName,
            ]
        )
        isWorking = false
        if registered {
            await login(email: email, password: password)
        }
    }

    func logout() {
        KeychainHelper.delete(Self.accessTokenKey)
        KeychainHelper.delete(Self.refreshTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.userIdKey)
        UserDefaults.standard.removeObject(forKey: Self.displayNameKey)
        TemplateBundleSync.shared.clearCache()
        accessToken = ""
        userId = ""
        displayName = ""
        isLoggedIn = false
        isBootstrapping = false
        errorMessage = nil
        if Self.bypassAuthForLocalUse {
            enterGuestMode()
        }
    }

    /// Called by `APIClient` when the backend rejects a request with
    /// 401. We first try a silent refresh — if the refresh token is
    /// still valid the user keeps their workspace, with no visible
    /// glitch. Only if refresh fails do we drop them back to login.
    func handleUnauthorized() {
        guard isLoggedIn else { return }
        Task { @MainActor in
            if let refresh = KeychainHelper.get(Self.refreshTokenKey),
               !refresh.isEmpty,
               await self.tryRefresh(refreshToken: refresh) {
                return
            }
            self.logout()
            self.errorMessage = L10n.string("auth.error.sessionExpired")
        }
    }

    // MARK: - Cold-start restore

    private func loadSavedCredentials() {
        let access = KeychainHelper.get(Self.accessTokenKey) ?? ""
        let savedUserId = UserDefaults.standard.string(forKey: Self.userIdKey) ?? ""
        let savedDisplay = UserDefaults.standard.string(forKey: Self.displayNameKey) ?? ""

        if !access.isEmpty, !isJWTExpired(access) {
            // Fast path: render the workspace immediately. Backfill
            // missing user info + start template sync off the main path.
            self.accessToken = access
            self.userId = savedUserId
            self.displayName = savedDisplay
            self.isLoggedIn = true
            Task { @MainActor in
                if self.userId.isEmpty {
                    _ = await self.fetchAndStoreUser()
                }
                self.triggerPostLoginSync()
            }
            return
        }

        // Access token gone or expired — fall back to refresh.
        if let refresh = KeychainHelper.get(Self.refreshTokenKey),
           !refresh.isEmpty {
            isBootstrapping = true
            Task { @MainActor in
                _ = await self.tryRefresh(refreshToken: refresh)
                if !self.isLoggedIn, Self.bypassAuthForLocalUse {
                    self.enterGuestMode()
                }
                self.isBootstrapping = false
            }
            return
        }

        if Self.bypassAuthForLocalUse {
            enterGuestMode()
        }
    }

    /// Bypass-mode session: no token, no backend identity, but the UI
    /// gate is open so the user can drive the terminal + Godot pane.
    /// `triggerPostLoginSync` is skipped because `accessToken` is empty.
    private func enterGuestMode() {
        accessToken = ""
        userId = "local"
        displayName = "Local"
        isLoggedIn = true
    }

    // MARK: - Internals

    private func applyTokens(_ tokens: TokenResponse) async {
        KeychainHelper.save(tokens.access_token, for: Self.accessTokenKey)
        KeychainHelper.save(tokens.refresh_token, for: Self.refreshTokenKey)
        accessToken = tokens.access_token
        _ = await fetchAndStoreUser()
        isLoggedIn = true
        triggerPostLoginSync()
    }

    @discardableResult
    private func tryRefresh(refreshToken: String) async -> Bool {
        guard let url = URL(string: "/api/auth/refresh", relativeTo: BackendConfig.baseURL) else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "Accept-Language")
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["refresh_token": refreshToken]
        )

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode else {
                return false
            }
            let tokens = try JSONDecoder().decode(TokenResponse.self, from: data)
            await applyTokens(tokens)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func fetchAndStoreUser() async -> Bool {
        guard !accessToken.isEmpty,
              let url = URL(string: "/api/auth/me", relativeTo: BackendConfig.baseURL) else {
            return false
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Locale.current.identifier, forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode else {
                return false
            }
            let user = try JSONDecoder().decode(UserPayload.self, from: data)
            userId = user.id
            displayName = user.display_name ?? user.email ?? ""
            UserDefaults.standard.set(user.id, forKey: Self.userIdKey)
            UserDefaults.standard.set(displayName, forKey: Self.displayNameKey)
            return true
        } catch {
            return false
        }
    }

    private func postTokenEndpoint(path: String, body: [String: String]) async -> TokenResponse? {
        guard let url = URL(string: path, relativeTo: BackendConfig.baseURL) else {
            errorMessage = L10n.string("auth.error.badURL")
            return nil
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
                return nil
            }
            guard 200..<300 ~= http.statusCode else {
                errorMessage = humanError(from: data, status: http.statusCode)
                return nil
            }
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Lightweight POST that doesn't unpack tokens. Used for `/register`
    /// where we follow up with `/login` to obtain the token pair.
    private func postRaw(path: String, body: [String: String]) async -> Bool {
        guard let url = URL(string: path, relativeTo: BackendConfig.baseURL) else {
            errorMessage = L10n.string("auth.error.badURL")
            return false
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
                return false
            }
            if !(200..<300 ~= http.statusCode) {
                errorMessage = humanError(from: data, status: http.statusCode)
                return false
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func triggerPostLoginSync() {
        guard !accessToken.isEmpty else { return }
        Task { await TemplateBundleSync.shared.sync() }
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

    // MARK: - Decode shapes

    /// Mirrors backend's `TokenResponse` schema.
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
    }

    /// Mirrors a subset of `UserResponse` — only the fields we display
    /// + persist locally.
    private struct UserPayload: Decodable {
        let id: String
        let email: String?
        let display_name: String?
    }
}
