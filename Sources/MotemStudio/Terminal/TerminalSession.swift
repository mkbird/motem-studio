import Foundation

/// A single terminal tab. The id is stable so SwiftUI keeps the same
/// `AgentTerminalView` (and its PTY) across re-renders even when other
/// sessions are opened or closed alongside it.
struct TerminalSession: Identifiable, Equatable {
    let id: UUID
    let agent: Agent

    init(id: UUID = UUID(), agent: Agent) {
        self.id = id
        self.agent = agent
    }
}
