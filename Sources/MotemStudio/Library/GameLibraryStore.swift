import Foundation

/// Owns the list of games the signed-in user has on the backend plus
/// the in-flight loading state for whichever entry is currently being
/// downloaded into the preview pane.
@MainActor
final class GameLibraryStore: ObservableObject {

    static let shared = GameLibraryStore()

    @Published private(set) var games: [GameSummary] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var loadingGameId: String?
    @Published private(set) var activeGameId: String?
    @Published private(set) var errorMessage: String?

    private init() {}

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        do {
            let response: GameListResponse = try await APIClient.shared.get("/api/games/mine")
            games = response.games
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setLoading(_ id: String?) {
        loadingGameId = id
    }

    func setError(_ message: String?) {
        errorMessage = message
    }

    func markActive(_ id: String) {
        activeGameId = id
    }

    /// Clear local state when the user signs out so the next account
    /// starts with a clean list.
    func reset() {
        games = []
        activeGameId = nil
        loadingGameId = nil
        errorMessage = nil
    }
}
