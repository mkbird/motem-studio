import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var l10n: LocalizationManager
    @ObservedObject private var auth = AuthManager.shared
    @ObservedObject private var preview = GodotPreviewController.shared
    @AppStorage("DefaultAgent") private var defaultAgent: Agent = .claude

    @State private var sessions: [TerminalSession] = []
    @State private var activeID: UUID?
    @State private var titles: [UUID: String] = [:]
    @State private var workingDir: URL = AgentSandbox.directory
    @State private var initialized = false

    var body: some View {
        // The login gate guards every other piece of the workspace —
        // sandbox layout, MCP bridge, and Godot engine all sit behind
        // an authenticated session so per-user templates and uploads
        // line up with the same identity on iPhone.
        if auth.isLoggedIn {
            workspace
        } else if auth.isBootstrapping {
            sessionRestoreView
        } else {
            LoginView()
        }
    }

    private var sessionRestoreView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            T("auth.restoring.title")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 520, minHeight: 480)
        .background(Color(NSColor.windowBackgroundColor).ignoresSafeArea())
    }

    private var workspace: some View {
        NavigationSplitView {
            GameLibrarySidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            workspaceDetail
        }
    }

    private var workspaceDetail: some View {
        VSplitView {
            GodotPreviewPane()
                .frame(minHeight: 200, idealHeight: 360)

            terminalArea
                .frame(minHeight: 220)
        }
        .navigationTitle(currentTitle)
        .onAppear {
            if !initialized {
                let first = TerminalSession(agent: defaultAgent)
                sessions = [first]
                activeID = first.id
                initialized = true
            }
        }
    }

    @ViewBuilder
    private var terminalArea: some View {
        VStack(spacing: 0) {
            ControlModeBar()
            Divider()
            TerminalTabBar(
                sessions: sessions,
                activeID: activeID,
                titles: titles,
                onSelect: { activeID = $0 },
                onClose: closeSession,
                onNew: addSession
            )
            Divider()
            ZStack {
                if sessions.isEmpty {
                    emptyTerminalState
                } else {
                    ForEach(sessions) { session in
                        TerminalHostView(
                            agent: session.agent,
                            workingDir: workingDir,
                            isActive: session.id == activeID,
                            title: bindingForTitle(of: session.id)
                        )
                    }
                }
            }
        }
    }

    private var emptyTerminalState: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.secondary)
            T("terminal.empty.title")
                .font(.headline)
                .foregroundStyle(.secondary)
            T("terminal.empty.subtitle")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private var currentTitle: String {
        guard let id = activeID, let session = sessions.first(where: { $0.id == id }) else {
            return ""
        }
        let title = titles[id] ?? ""
        return title.isEmpty ? session.agent.displayName : title
    }

    private func bindingForTitle(of id: UUID) -> Binding<String> {
        Binding(
            get: { titles[id] ?? "" },
            set: { titles[id] = $0 }
        )
    }

    private func addSession(agent: Agent) {
        let session = TerminalSession(agent: agent)
        sessions.append(session)
        activeID = session.id
    }

    private func closeSession(_ id: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions.remove(at: index)
        titles.removeValue(forKey: id)
        if activeID == id {
            // Prefer the neighbour to the left, falling back to the new
            // first session. If we closed the last one, drop activeID
            // so the empty-state view takes over.
            if index > 0 {
                activeID = sessions[index - 1].id
            } else {
                activeID = sessions.first?.id
            }
        }
    }
}

/// Horizontal chip strip across the top of the terminal pane: one chip
/// per live session, brand-coloured by agent, plus a `+` menu on the
/// right for spawning a new session with a chosen agent.
private struct TerminalTabBar: View {
    let sessions: [TerminalSession]
    let activeID: UUID?
    let titles: [UUID: String]
    let onSelect: (UUID) -> Void
    let onClose: (UUID) -> Void
    let onNew: (Agent) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(sessions) { session in
                        TerminalTabChip(
                            session: session,
                            title: titles[session.id] ?? "",
                            isActive: session.id == activeID,
                            onSelect: { onSelect(session.id) },
                            onClose: { onClose(session.id) }
                        )
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer(minLength: 0)

            Menu {
                ForEach(Agent.allCases) { agent in
                    Button {
                        onNew(agent)
                    } label: {
                        Label(agent.displayName, systemImage: "terminal")
                            .foregroundStyle(agent.brandColor)
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L10n.string("terminal.new.tooltip"))
            .padding(.trailing, 8)
        }
        .frame(height: 32)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

private struct TerminalTabChip: View {
    let session: TerminalSession
    let title: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(session.agent.brandColor)
                .frame(width: 6, height: 6)

            Text(displayLabel)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isActive ? .primary : .secondary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isActive || isHovering ? 1 : 0.0)
            .help(L10n.string("terminal.close.tooltip"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: 220)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive
                      ? Color(NSColor.selectedContentBackgroundColor).opacity(0.18)
                      : (isHovering ? Color.secondary.opacity(0.08) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? session.agent.brandColor.opacity(0.45) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { isHovering = $0 }
    }

    private var displayLabel: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? session.agent.displayName : trimmed
    }
}
