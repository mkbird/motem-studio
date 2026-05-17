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

    /// Games the user owns (any visibility). Used as the "Mine" section
    /// of the sidebar.
    var myGames: [GameSummary] {
        games.filter { $0.isOwner ?? false }
    }

    /// `public_remixable` games owned by someone else. Used as the
    /// "Remixable" section of the sidebar — clicking one will eventually
    /// kick off a remix flow that clones it to the user's account.
    var remixableGames: [GameSummary] {
        games.filter { !($0.isOwner ?? false) && $0.isPublicRemixable }
    }

    private init() {}

    /// Pull "mine" (owned + favorited by the signed-in user) and
    /// "explore" (every public game in the system) in parallel, then
    /// keep only entries the user can actually act on inside Motem
    /// Studio: their own games (owned regardless of visibility) plus
    /// any `public_remixable` game from anyone. View-only public games
    /// and favorited-but-not-mine private games are filtered out — the
    /// sidebar is a launchpad for things the user can edit or remix,
    /// not a marketplace browser.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        errorMessage = nil
        defer { isRefreshing = false }

        async let mineTask = fetchList(path: "/api/games/mine")
        async let exploreTask = fetchList(path: "/api/games/explore")
        let mine = await mineTask
        let explore = await exploreTask

        if let mineError = mine.error, let exploreError = explore.error {
            errorMessage = mineError.localizedDescription
            NSLog("[Library] both mine and explore failed: %@ / %@",
                  String(describing: mineError),
                  String(describing: exploreError))
            return
        }

        var merged: [String: GameSummary] = [:]
        // /mine wins on conflict — it carries the user's view_type + flags.
        for game in explore.games { merged[game.gameId] = game }
        for game in mine.games { merged[game.gameId] = game }

        // Preserve the backend's order (newest first per /mine and
        // /explore conventions). The computed `myGames` /
        // `remixableGames` properties filter without reordering, so
        // each section comes out newest-first naturally.
        var orderedIds: [String] = []
        var seen = Set<String>()
        for game in mine.games where !seen.contains(game.gameId) {
            orderedIds.append(game.gameId)
            seen.insert(game.gameId)
        }
        for game in explore.games where !seen.contains(game.gameId) {
            orderedIds.append(game.gameId)
            seen.insert(game.gameId)
        }
        let ordered = orderedIds.compactMap { merged[$0] }
        games = ordered.filter { game in
            (game.isOwner ?? false) || game.isPublicRemixable
        }
    }

    private struct FetchResult {
        let games: [GameSummary]
        let error: Error?
    }

    private func fetchList(path: String) async -> FetchResult {
        do {
            let response: GameListResponse = try await APIClient.shared.get(path)
            return FetchResult(games: response.games, error: nil)
        } catch {
            NSLog("[Library] %@ failed: %@", path, String(describing: error))
            return FetchResult(games: [], error: error)
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

    /// Server-authoritative delete. Mirrors the iPhone flow:
    ///   1. `DELETE /api/games/{id}` (backend wipes files + DB + caches
    ///      + the iPhone signed in to the same account loses access on
    ///      its next list refresh).
    ///   2. Drop the local cached extraction under `sandbox/library/`
    ///      so the macOS side stays in sync.
    ///   3. If the deleted game is the one currently being previewed,
    ///      unload the Godot scene and clear `activeGameId`.
    ///   4. Refresh the list so deletions made elsewhere (e.g. iPhone
    ///      delete fired right before this call) are reconciled too.
    func delete(gameId: String) async throws {
        try await APIClient.shared.delete("/api/games/\(gameId)")

        let localDir = AgentSandbox.directory
            .appendingPathComponent("library", isDirectory: true)
            .appendingPathComponent(gameId, isDirectory: true)
        try? FileManager.default.removeItem(at: localDir)

        if activeGameId == gameId {
            activeGameId = nil
            _ = await GodotPreviewController.shared.stop()
        }

        await refresh()
    }
}
