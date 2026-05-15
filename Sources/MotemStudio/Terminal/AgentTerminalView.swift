import AppKit
import SwiftTerm

final class AgentTerminalView: LocalProcessTerminalView {

    private let agent: Agent
    private let workingDir: URL
    private let appLanguage: AppLanguage
    private let coordinator = TerminalCoordinator()

    var onExit: ((Int32) -> Void)?
    var onTitleChange: ((String) -> Void)?

    init(agent: Agent, workingDir: URL, appLanguage: AppLanguage, frame: NSRect) {
        self.agent = agent
        self.workingDir = workingDir
        self.appLanguage = appLanguage
        super.init(frame: frame)
        coordinator.owner = self
        self.processDelegate = coordinator
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func start() {
        guard let binary = AgentBinaryLocator.locate(agent) else {
            feedError(L10n.string("terminal.notFound.title.\(agent.rawValue)"))
            feedHint(L10n.string("terminal.notFound.install.prefix") + " " + agent.installCommand)
            return
        }

        let env = TerminalEnvironment.build(
            workingDirectory: workingDir,
            appLanguage: appLanguage
        )
        let envArray = env.map { "\($0.key)=\($0.value)" }

        let cdCommand = "cd \(workingDir.path.shellEscaped) && exec \(binary.path.shellEscaped)"
        startProcess(
            executable: "/bin/zsh",
            args: ["-ilc", cdCommand],
            environment: envArray,
            execName: "-zsh"
        )
    }

    fileprivate func notifyTitle(_ title: String) { onTitleChange?(title) }
    fileprivate func notifyExit(_ code: Int32) { onExit?(code) }

    private func feedError(_ message: String) {
        feed(text: "\r\n\u{1b}[31m\(message)\u{1b}[0m\r\n")
    }

    private func feedHint(_ message: String) {
        feed(text: "  \(message)\r\n")
    }
}

private final class TerminalCoordinator: NSObject, LocalProcessTerminalViewDelegate {

    weak var owner: AgentTerminalView?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        owner?.notifyTitle(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        owner?.notifyExit(exitCode ?? -1)
    }
}

extension String {
    /// Single-quote escape for safe embedding in a POSIX shell command.
    var shellEscaped: String {
        "'\(replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
