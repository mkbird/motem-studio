import SwiftUI

/// Left-hand list of every game owned by the signed-in user. Click a
/// row → `GameLoader` downloads the zip, unpacks it under
/// `sandbox/library/`, and hands the directory to the embedded engine
/// preview.
struct GameLibrarySidebar: View {
    @ObservedObject private var store = GameLibraryStore.shared
    @ObservedObject private var auth = AuthManager.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let message = store.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }

            if store.games.isEmpty && !store.isRefreshing {
                emptyState
            } else {
                gamesList
            }
        }
        .frame(minWidth: 220, idealWidth: 260)
        .background(Color(NSColor.windowBackgroundColor))
        .task {
            await store.refresh()
        }
    }

    private var header: some View {
        HStack {
            T("library.title")
                .font(.headline)
            Spacer()
            Button(action: { Task { await store.refresh() } }) {
                if store.isRefreshing {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help(L10n.string("library.refresh"))
            .disabled(store.isRefreshing)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.secondary)
            T("library.empty.title")
                .font(.callout)
                .foregroundStyle(.secondary)
            T("library.empty.subtitle")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gamesList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(store.games) { game in
                    row(for: game)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func row(for game: GameSummary) -> some View {
        Button(action: {
            NSLog("[Sidebar] click game=%@", game.gameId)
            Task {
                do {
                    try await GameLoader.load(gameId: game.gameId)
                } catch {
                    NSLog("[Sidebar] load error: %@", String(describing: error))
                    GameLibraryStore.shared.setError(error.localizedDescription)
                }
            }
        }) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Text(game.icon ?? "🎮")
                        .font(.system(size: 20))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(game.displayTitle)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let mode = game.inputMode {
                            Text(mode)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.12)))
                        }
                        Text(game.gameId.prefix(14))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if store.loadingGameId == game.gameId {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else if store.activeGameId == game.gameId {
                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(store.activeGameId == game.gameId
                          ? Color.accentColor.opacity(0.18)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.loadingGameId != nil)
    }
}
