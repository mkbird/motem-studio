import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let agent: Agent
    let workingDir: URL
    @Binding var title: String

    @EnvironmentObject private var l10n: LocalizationManager

    func makeNSView(context: Context) -> AgentTerminalView {
        let view = AgentTerminalView(
            agent: agent,
            workingDir: workingDir,
            appLanguage: l10n.language,
            frame: .zero
        )
        view.onTitleChange = { newTitle in
            DispatchQueue.main.async { self.title = newTitle }
        }
        let agentName = agent.executableName
        view.onExit = { code in
            NSLog("[MotemStudio] \(agentName) exited with code \(code)")
        }
        // The terminal must know its cell grid before the agent boots —
        // SwiftUI hasn't laid the view out yet on the first frame.
        DispatchQueue.main.async { view.start() }
        return view
    }

    func updateNSView(_ nsView: AgentTerminalView, context: Context) {}
}
