import SwiftUI

struct TerminalHostView: NSViewRepresentable {
    let agent: Agent
    let workingDir: URL
    let isActive: Bool
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
        view.isHidden = !isActive
        // The terminal must know its cell grid before the agent boots —
        // SwiftUI hasn't laid the view out yet on the first frame.
        DispatchQueue.main.async { view.start() }
        return view
    }

    func updateNSView(_ nsView: AgentTerminalView, context: Context) {
        let shouldHide = !isActive
        if nsView.isHidden != shouldHide {
            // Use isHidden (not opacity/allowsHitTesting) so AppKit drops
            // the view from its performKeyEquivalent broadcast — otherwise
            // Cmd-V / Cmd-K / Cmd-Arrow leak into background tabs whose
            // visibility was only suppressed at the SwiftUI layer.
            nsView.isHidden = shouldHide
        }
        if isActive {
            // Once visible again, claim first responder so subsequent
            // keystrokes go straight to this PTY rather than lingering
            // on whichever view used to be active.
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}
