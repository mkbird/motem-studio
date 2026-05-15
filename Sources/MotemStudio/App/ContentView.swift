import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var l10n: LocalizationManager
    @AppStorage("DefaultAgent") private var defaultAgent: Agent = .claude

    @State private var agent: Agent = .claude
    @State private var workingDir: URL = URL(fileURLWithPath: NSHomeDirectory())
    @State private var titles: [Agent: String] = [:]
    @State private var spawned: Set<Agent> = []
    @State private var initialized = false

    var body: some View {
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
