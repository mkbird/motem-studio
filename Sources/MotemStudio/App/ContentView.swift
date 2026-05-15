import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var l10n: LocalizationManager
    @ObservedObject private var auth = AuthManager.shared
    @ObservedObject private var preview = GodotPreviewController.shared
    @AppStorage("DefaultAgent") private var defaultAgent: Agent = .claude

    @State private var agent: Agent = .claude
    @State private var workingDir: URL = AgentSandbox.directory
    @State private var titles: [Agent: String] = [:]
    @State private var spawned: Set<Agent> = []
    @State private var initialized = false

    var body: some View {
        // The login gate guards every other piece of the workspace —
        // sandbox layout, MCP bridge, and Godot engine all sit behind
        // an authenticated session so per-user templates and uploads
        // line up with the same identity on iPhone.
        if auth.isLoggedIn {
            workspace
        } else {
            LoginView()
        }
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

            ZStack {
                ForEach(Agent.allCases) { candidate in
                    if spawned.contains(candidate) {
                        TerminalHostView(
                            agent: candidate,
                            workingDir: workingDir,
                            title: bindingForTitle(of: candidate)
                        )
                        .opacity(candidate == agent ? 1 : 0)
                        .allowsHitTesting(candidate == agent)
                    }
                }
            }
            .frame(minHeight: 220)
        }
        .navigationTitle(currentTitle)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $agent) {
                    ForEach(Agent.allCases) { agent in
                        Text(agent.displayName).tag(agent)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minWidth: 260)
            }
        }
        .onAppear {
            if !initialized {
                agent = defaultAgent
                spawned.insert(defaultAgent)
                initialized = true
            }
        }
        .onChange(of: agent) { newAgent in
            // Lazily spawn an agent the first time the user picks it.
            // Once spawned it stays resident (hidden when inactive) so
            // switching back never restarts the PTY.
            spawned.insert(newAgent)
        }
    }

    private var currentTitle: String {
        let title = titles[agent] ?? ""
        return title.isEmpty ? agent.displayName : title
    }

    private func bindingForTitle(of agent: Agent) -> Binding<String> {
        Binding(
            get: { titles[agent] ?? "" },
            set: { titles[agent] = $0 }
        )
    }
}
