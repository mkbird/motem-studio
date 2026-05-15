import AppKit
import SwiftTerm
import UniformTypeIdentifiers

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
        // Accept dragged files (any kind — image, code, config) and
        // raw images from apps that don't expose a backing file URL
        // (Preview, Photoshop selections, Cmd-Shift-Ctrl-4 captures).
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func start() {
        guard let binary = AgentBinaryLocator.locate(agent) else {
            feedError(L10n.string("terminal.notFound.title.\(agent.rawValue)"))
            feedHint(L10n.string("terminal.notFound.install.prefix") + " " + agent.installCommand)
            return
        }

        // Lay down the sandbox skeleton and start the MCP bridge on the
        // first session. Both are idempotent and main-actor safe. We do
        // them here rather than at app launch so a user who never opens
        // a terminal never pays the permission tax.
        AgentSandbox.ensureLayout()
        MCPBridgeServer.shared.start()

        // Make the Godot preview MCP server visible to the agent before
        // it boots. Failures here are non-fatal: the terminal still
        // works, only the auto-preview feature is unavailable.
        MCPConfigInjector.inject(into: workingDir)

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

    // MARK: - Keyboard shortcuts

    /// SwiftUI's default `WindowGroup` does not ship an Edit menu, so the
    /// standard `paste:` / `copy:` / `selectAll:` menu items never fire on
    /// Cmd-C / Cmd-V / Cmd-A. Intercept the equivalents here and call the
    /// methods SwiftTerm already implements. We also translate macOS
    /// cursor / line shortcuts into readline / vt100 control bytes so
    /// they work in every CLI's prompt and in vim / less alike.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Option + Backspace → delete word backward.
        // Most readline-driven prompts bind Ctrl-W to backward-kill-word,
        // which is more reliable than the Esc+Backspace some shells use.
        if modifiers == .option,
           let chars = event.charactersIgnoringModifiers,
           chars.unicodeScalars.first?.value == 0x7F /* DEL */ {
            send(txt: "\u{17}")
            return true
        }

        guard modifiers == .command,
              let chars = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }

        switch chars {
        case "v":
            return handlePaste()
        case "c":
            copy(self)
            return true
        case "a":
            selectAll(self)
            return true
        case "k":
            // Cmd-K — clear screen + scrollback. Send Ctrl-L so any
            // readline prompt redraws cleanly, then drop the parent
            // buffer's scrollback so the user can't scroll back to old
            // output. This matches Terminal.app / iTerm2 conventions.
            send(txt: "\u{0c}")
            getTerminal().resetToInitialState()
            return true
        default:
            // Arrow keys arrive without a character; check the keyCode
            // for Cmd-Left / Cmd-Right / Cmd-Backspace.
            switch event.keyCode {
            case 0x7B: // Left arrow
                send(txt: "\u{01}") // Ctrl-A: beginning of line
                return true
            case 0x7C: // Right arrow
                send(txt: "\u{05}") // Ctrl-E: end of line
                return true
            case 0x33: // Backspace / Delete
                send(txt: "\u{15}") // Ctrl-U: kill to line start
                return true
            default:
                return super.performKeyEquivalent(with: event)
            }
        }
    }

    /// Cmd-V branch. If the clipboard holds an image (e.g. a screenshot
    /// from Cmd-Shift-Ctrl-4), stage it into the sandbox's `.pastes/`
    /// directory and emit its absolute path. Otherwise fall through to
    /// SwiftTerm's normal text paste, which wraps the payload in
    /// bracketed-paste sequences so the CLI sees it as a single literal.
    private func handlePaste() -> Bool {
        let pb = NSPasteboard.general
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           !pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            if let url = stageImage(image) {
                emit(paths: [url])
                return true
            }
        }
        paste(self)
        return true
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        accepts(sender) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            emit(paths: urls)
            return true
        }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let staged = stageImage(image) {
            emit(paths: [staged])
            return true
        }
        return false
    }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }
        return false
    }

    // MARK: - Image staging

    /// Encode `image` as PNG and drop it into the sandbox's `.pastes/`
    /// directory. Returns the on-disk URL on success.
    private func stageImage(_ image: NSImage) -> URL? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else {
            return nil
        }
        let dir = AgentSandbox.pastesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let suffix = String(format: "%04x", Int.random(in: 0..<0xFFFF))
        let url = dir.appendingPathComponent("img-\(stamp)-\(suffix).png")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Send the absolute paths into the PTY at the cursor, separated by
    /// spaces and each one shell-escaped so that paths containing
    /// spaces or quotes survive the prompt intact. A trailing space
    /// lets the user keep typing the rest of their message.
    private func emit(paths: [URL]) {
        let joined = paths
            .map { $0.path.shellEscaped }
            .joined(separator: " ")
        send(txt: joined + " ")
    }

    // MARK: - Right-click context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        let copyItem = NSMenuItem(
            title: L10n.string("terminal.menu.copy"),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"
        )
        copyItem.target = self
        copyItem.isEnabled = selectionActive
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(
            title: L10n.string("terminal.menu.paste"),
            action: #selector(menuPaste(_:)),
            keyEquivalent: "v"
        )
        pasteItem.target = self
        menu.addItem(pasteItem)

        let pasteAsPath = NSMenuItem(
            title: L10n.string("terminal.menu.pasteAsPath"),
            action: #selector(menuPasteAsPath(_:)),
            keyEquivalent: ""
        )
        pasteAsPath.target = self
        pasteAsPath.isEnabled = clipboardHasAttachable()
        menu.addItem(pasteAsPath)

        menu.addItem(NSMenuItem.separator())

        let selectAllItem = NSMenuItem(
            title: L10n.string("terminal.menu.selectAll"),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        let clearItem = NSMenuItem(
            title: L10n.string("terminal.menu.clearBuffer"),
            action: #selector(menuClearBuffer(_:)),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)

        return menu
    }

    @objc private func menuPaste(_ sender: Any?) {
        _ = handlePaste()
    }

    @objc private func menuPasteAsPath(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            emit(paths: urls)
            return
        }
        if let images = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first,
           let staged = stageImage(image) {
            emit(paths: [staged])
        }
    }

    @objc private func menuClearBuffer(_ sender: Any?) {
        send(txt: "\u{0c}")
        getTerminal().resetToInitialState()
    }

    private func clipboardHasAttachable() -> Bool {
        let pb = NSPasteboard.general
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            return true
        }
        if pb.canReadObject(forClasses: [NSImage.self], options: nil) {
            return true
        }
        return false
    }

    // MARK: - Hint feed

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
