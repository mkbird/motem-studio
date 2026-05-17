import SwiftUI

/// Left-hand list of every game owned by the signed-in user. Click a
/// row → `GameLoader` downloads the zip, unpacks it under
/// `sandbox/library/`, and hands the directory to the embedded engine
/// preview.
struct GameLibrarySidebar: View {
    @ObservedObject private var store = GameLibraryStore.shared
    @ObservedObject private var auth = AuthManager.shared
    @ObservedObject private var l10n = LocalizationManager.shared

    @AppStorage("library.mineCollapsed") private var mineCollapsed: Bool = false
    @AppStorage("library.remixableCollapsed") private var remixableCollapsed: Bool = false

    @State private var pendingDelete: GameSummary?
    @State private var deleteInFlight = false
    @State private var hovered: Bool = false

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
        .onHover { hovered = $0 }
        .background(arrowShortcuts)
        .task {
            await store.refresh()
        }
        .confirmationDialog(
            L10n.string("library.delete.confirm.title"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { game in
            Button(L10n.string("library.delete.confirm.button"), role: .destructive) {
                Task { await performDelete(game) }
            }
            Button(L10n.string("library.delete.cancel"), role: .cancel) {
                pendingDelete = nil
            }
        } message: { _ in
            Text(L10n.string("library.delete.confirm.message"))
        }
    }

    private func performDelete(_ game: GameSummary) async {
        deleteInFlight = true
        defer { deleteInFlight = false }
        do {
            try await store.delete(gameId: game.gameId)
        } catch {
            store.setError(L10n.string("library.delete.error", error.localizedDescription))
        }
        pendingDelete = nil
    }

    /// SwiftUI command-level shortcuts that fire only while the mouse
    /// is over the sidebar. Mounted as a hidden background view so
    /// AppKit's keyDown dispatch never reaches SwiftTerm — SwiftUI
    /// resolves the shortcut at the window-command layer first. When
    /// the user moves off the sidebar, the buttons disappear from the
    /// view tree, the shortcuts unregister, and arrow keys go back to
    /// feeding the terminal normally.
    @ViewBuilder
    private var arrowShortcuts: some View {
        if hovered {
            VStack(spacing: 0) {
                Button("") { navigate(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { navigate(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Arrow-key navigation
    //
    // SwiftTerm's `LocalProcessTerminalView` claims first-responder
    // status the moment it appears, so any in-pane SwiftUI `.focusable()`
    // / `.onKeyPress` modifier is starved of key events. We install a
    // window-local NSEvent monitor that intercepts ↑/↓ at the AppKit
    // layer, checks whether the current first responder is the terminal
    // (in which case the user is typing into the agent CLI and we must
    // let it through), and otherwise routes the event to library
    // navigation.

    /// Flattened list of rows in the order they appear on screen.
    /// Collapsed sections are skipped so the arrow keys never jump to
    /// hidden rows.
    private var flattenedGames: [GameSummary] {
        var list: [GameSummary] = []
        if !mineCollapsed { list.append(contentsOf: store.myGames) }
        if !remixableCollapsed { list.append(contentsOf: store.remixableGames) }
        return list
    }

    private func navigate(by step: Int) {
        let games = flattenedGames
        guard !games.isEmpty else { return }
        let currentIdx = games.firstIndex { $0.gameId == store.activeGameId }
        let target: GameSummary
        if let i = currentIdx {
            let next = max(0, min(games.count - 1, i + step))
            if next == i { return }
            target = games[next]
        } else {
            // No active selection yet — start from the top or bottom
            // depending on which direction the user pressed.
            target = step > 0 ? games[0] : games[games.count - 1]
        }
        loadGame(target)
    }

    private func loadGame(_ game: GameSummary) {
        guard store.loadingGameId == nil else { return }
        Task {
            do {
                try await GameLoader.load(gameId: game.gameId)
            } catch {
                NSLog("[Sidebar] load error: %@", String(describing: error))
                GameLibraryStore.shared.setError(error.localizedDescription)
            }
        }
    }

    private func canDelete(_ game: GameSummary) -> Bool {
        // Match iOS: only the author can delete, and never builtin
        // games. Backend enforces the same — these checks just hide
        // the menu item to keep the UI honest.
        (game.isOwner ?? false) && (game.kind ?? "") != "builtin"
    }

    // MARK: - Row badges

    @ViewBuilder
    private func inputModeBadge(_ mode: String) -> some View {
        let (symbol, label) = inputModeDisplay(mode)
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(label)
                .font(.caption2)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(
            Capsule().fill(Color.secondary.opacity(0.14))
        )
    }

    /// Icon-only variant of the input mode badge — used in the library
    /// row where space is tight. The localised label still backs the
    /// accessibility hint so VoiceOver users still hear "Body Pose".
    @ViewBuilder
    private func inputModeIcon(_ mode: String) -> some View {
        let (symbol, label) = inputModeDisplay(mode)
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .help(label)
            .accessibilityLabel(label)
    }

    /// Friendly icon + localised label for the `meta.json` `input_mode`
    /// string. Unknown values fall through to the raw mode name so a
    /// future backend addition still renders something.
    private func inputModeDisplay(_ mode: String) -> (String, String) {
        switch mode {
        case "touch":     return ("hand.tap", L10n.string("input_mode.touch"))
        case "body_pose": return ("figure.walk", L10n.string("input_mode.body_pose"))
        default:          return ("dot.circle", mode)
        }
    }

    /// Like / favourite / remix / share counts, inline with the title.
    /// Zero values are hidden so a freshly-published game stays uncluttered.
    @ViewBuilder
    private func countStrip(for game: GameSummary) -> some View {
        HStack(spacing: 6) {
            countItem(icon: "heart.fill",            count: game.likeCount,     tint: .pink)
            countItem(icon: "star.fill",             count: game.favoriteCount, tint: .yellow)
            countItem(icon: "arrow.triangle.branch", count: game.remixCount,    tint: .accentColor)
            countItem(icon: "square.and.arrow.up",   count: game.shareCount,    tint: .secondary)
        }
    }

    @ViewBuilder
    private func countItem(icon: String, count: Int?, tint: Color) -> some View {
        if let n = count, n > 0 {
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                Text(formatCount(n))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Compact display: < 1000 shows as-is, 1.2K, 12K, 1.2M, etc.
    private func formatCount(_ n: Int) -> String {
        switch n {
        case ..<1_000:        return "\(n)"
        case ..<10_000:       return String(format: "%.1fK", Double(n) / 1_000)
        case ..<1_000_000:    return "\(n / 1_000)K"
        default:              return String(format: "%.1fM", Double(n) / 1_000_000)
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
            LazyVStack(alignment: .leading, spacing: 1, pinnedViews: [.sectionHeaders]) {
                if !store.myGames.isEmpty {
                    Section(header: sectionHeader(
                        "library.section.mine",
                        count: store.myGames.count,
                        collapsed: $mineCollapsed
                    )) {
                        if !mineCollapsed {
                            ForEach(store.myGames) { game in
                                row(for: game)
                            }
                        }
                    }
                }
                if !store.remixableGames.isEmpty {
                    Section(header: sectionHeader(
                        "library.section.remixable",
                        count: store.remixableGames.count,
                        collapsed: $remixableCollapsed
                    )) {
                        if !remixableCollapsed {
                            ForEach(store.remixableGames) { game in
                                row(for: game)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            .animation(.easeInOut(duration: 0.18), value: mineCollapsed)
            .animation(.easeInOut(duration: 0.18), value: remixableCollapsed)
        }
    }

    private func sectionHeader(_ key: String, count: Int, collapsed: Binding<Bool>) -> some View {
        Button {
            collapsed.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(collapsed.wrappedValue ? 0 : 90))
                    .animation(.easeInOut(duration: 0.18), value: collapsed.wrappedValue)
                T(key)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text("\(count)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
            .background(Color(NSColor.windowBackgroundColor))
        }
        .buttonStyle(.plain)
    }

    private func row(for game: GameSummary) -> some View {
        Button(action: {
            NSLog("[Sidebar] click game=%@", game.gameId)
            loadGame(game)
        }) {
            HStack(spacing: 10) {
                Text(game.icon ?? "🎮")
                    .font(.system(size: 26))
                    .frame(width: 36, height: 36)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Text(game.displayTitle)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        if let mode = game.inputMode, !mode.isEmpty {
                            inputModeIcon(mode)
                        }
                        countStrip(for: game)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .scrollClipDisabled()
                .frame(maxWidth: .infinity, alignment: .leading)

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
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(store.activeGameId == game.gameId
                          ? Color.accentColor.opacity(0.18)
                          : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(store.loadingGameId != nil)
        .contextMenu {
            if canDelete(game) {
                Button(role: .destructive) {
                    pendingDelete = game
                } label: {
                    Label(L10n.string("library.delete.action"), systemImage: "trash")
                }
                .disabled(deleteInFlight)
            }
        }
    }
}
