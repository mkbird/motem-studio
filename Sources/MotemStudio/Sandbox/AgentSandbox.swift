import Foundation

/// A dedicated working directory that every agent terminal session runs
/// inside. Three goals:
///
/// 1. **Pin cwd** so each CLI's project-level memory walk (`CLAUDE.md` /
///    `AGENTS.md` / `GEMINI.md`) stops at this directory and never leaks
///    into the user's home or unrelated projects.
/// 2. **Keep first-party CLI auth/config in the CLI's own default home**.
///    Claude / Codex / Gemini deliberately keep their default
///    `~/.claude` / `~/.codex` / `~/.gemini` homes so each local CLI can
///    reuse its existing OAuth session. Motem does not read or copy
///    those credentials.
/// 3. **Inject a Motem Studio prompt** as the project-level memory
///    file, telling the agent what tools it has and how to use Godot 4
///    in this environment.
///
/// Gemini does not expose a clean home override; we intentionally let it
/// use its default home. The sandbox-local `GEMINI.md` is layered on top
/// as project memory.
enum AgentSandbox {

    static let directory: URL = {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("MotemStudio/sandbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Mirror of the backend's `_template/` skeleton, refreshed by
    /// `TemplateBundleSync` after each login. Claude / Codex / Gemini
    /// read from here when authoring new Godot projects so the macOS
    /// scaffold stays in lock-step with what the iOS pipeline expects.
    static var templateDirectory: URL {
        directory.appendingPathComponent(".template", isDirectory: true)
    }

    /// Holding pen for images the user drops onto the terminal or
    /// pastes from the clipboard. `AgentTerminalView` writes here and
    /// then inserts the absolute path at the PTY cursor so the agent
    /// CLI can read it as an attachment.
    static var pastesDirectory: URL {
        directory.appendingPathComponent(".pastes", isDirectory: true)
    }

    /// Lay down the sandbox files needed for every agent CLI to start
    /// fresh inside Motem Studio. Idempotent — safe to call on every
    /// app launch; existing project files (user-generated games) are
    /// left untouched.
    static func ensureLayout() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: pastesDirectory, withIntermediateDirectories: true)

        // Write the managed CLAUDE / AGENTS / GEMINI files with whatever
        // backend-template content is currently cached (or the Motem
        // section only on first launch — the user is expected to log in
        // before authoring, which triggers `TemplateBundleSync.sync()`
        // and rewrites these files with the merged content).
        writePromptFiles(backendSection: nil)

        // Halt the project-level memory walk at the sandbox boundary.
        // A .git directory is the most reliable marker that all three
        // CLIs honor when ascending from cwd.
        let gitDir = directory.appendingPathComponent(".git")
        if !fm.fileExists(atPath: gitDir.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["init", "-q", directory.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                // No CLI surface for the absence of git — silently
                // skip; the memory walk will simply reach $HOME and
                // pick up whatever the user has there. Logged-in
                // scenarios still see the sandbox-scoped CLAUDE.md as
                // the closest match.
                try? fm.createDirectory(at: gitDir, withIntermediateDirectories: true)
            }
        }
    }

    /// Called by `TemplateBundleSync` after a successful pull. Re-renders
    /// `CLAUDE.md` / `AGENTS.md` / `GEMINI.md` with the backend's
    /// `_template_slowpath/CLAUDE.md` appended inside a fenced marker
    /// block so subsequent syncs can replace just the backend slice.
    static func applyBackendTemplate(claudeMd: String, etag: String) {
        let trimmed = claudeMd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        writePromptFiles(backendSection: BackendSection(content: trimmed, etag: etag))
    }

    // MARK: - Prompt rendering

    private struct BackendSection {
        let content: String
        let etag: String
    }

    private static func writePromptFiles(backendSection: BackendSection?) {
        let body = renderPrompt(backendSection: backendSection)
        for filename in ["CLAUDE.md", "AGENTS.md", "GEMINI.md"] {
            let url = directory.appendingPathComponent(filename)
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func renderPrompt(backendSection: BackendSection?) -> String {
        var output = motemPromptSection
        if let backendSection {
            output += "\n\n<!-- managed: backend-template version=\(backendSection.etag) -->\n"
            output += backendSection.content
            if !backendSection.content.hasSuffix("\n") { output += "\n" }
            output += "<!-- /managed: backend-template -->\n"
        }
        return output
    }

    // MARK: - Prompt

    /// The Motem-Studio-owned section. After `TemplateBundleSync` pulls
    /// from the backend, the full game-rules section (authoritative for
    /// both iOS-side and macOS-side Godot generation) is appended below
    /// inside its own fenced marker block. This Motem section only owns
    /// macOS-host concerns: MCP tools that proxy to the embedded Godot
    /// engine, sandbox boundaries, and how to read clipboard/dropped
    /// images. Anything about Godot architecture, hooks, asset rules,
    /// or audio catalog lives in the backend section.
    private static let motemPromptSection: String = """
    <!-- managed: motem -->
    <!--
      This file is managed by Motem Studio and rewritten when the app
      launches or syncs templates from the backend. Do not edit it by
      hand — your changes will be lost.
    -->

    # Motem Studio Environment

    You are running inside **Motem Studio**, a macOS GUI host for
    AI-driven Godot 4 game development. The shell is rooted at a
    sandbox directory dedicated to Motem Studio — write project files
    here, not in the user's home directory or unrelated locations.

    ## Game rules

    The full architecture, required hooks, asset structure, coding
    constraints and audio catalogue are in the **backend-template
    section appended below**. Treat that as the authoritative spec for
    every Godot project you author — this Motem section only documents
    macOS-host conveniences (preview MCP tools, sandbox boundaries,
    image input). Do NOT contradict the backend rules; do NOT
    "from-scratch" a `main.gd` — the backend's skeleton-hook
    architecture is the only supported shape.

    ## Available MCP tools

    Motem Studio exposes an in-process Godot 4 engine through an MCP
    server registered in this directory's `.mcp.json`. Use these tools
    when the user asks you to build or update a game:

    | Tool | When to call |
    |---|---|
    | `godot_preview(project_dir)` | After writing a new game's files, call with the absolute path to the directory containing `project.godot`. The user sees it instantly in the preview pane above the terminal. |
    | `godot_reload()` | After editing any `.gd`, `.tscn`, or asset file, call this so the user sees the change without restarting the engine. |
    | `godot_stop()` | When the user is finished or wants the pane cleared. |
    | `godot_status()` | When you want to check whether the engine is loaded and what project is active. |

    **Always call `godot_preview` once you have written a complete
    project to disk** — the user is expecting visual feedback in real
    time. Do not suggest the user run `godot` from the command line;
    they don't have it installed and they don't need to.

    ## Image and file attachments

    When the user drops a file onto the terminal, or pastes a clipboard
    image, Motem Studio writes the file to this sandbox's `.pastes/`
    directory (for clipboard images) or uses the file's original path
    (for Finder drops) and inserts the absolute path at the PTY cursor.
    Treat any such path as an attachment the user wants you to read —
    open the file directly rather than asking them to upload it again.

    ## Backend template mirror

    A mirror of the backend's Godot skeleton lives at `.template/` in
    this sandbox. Read scripts from there (e.g.
    `.template/_template/scripts/input_bridge.gd`) rather than
    reinventing them — they are the same files iOS-side games are
    generated against. When the mirror is empty, the backend has not
    been reached yet (run a login flow first).

    ## Working with the user

    - Match the language the user writes in (Mandarin or English).
    - For new projects: read the backend rules below, write the game
      files following the skeleton-hook architecture, then call
      `godot_preview` exactly once.
    - For iterative tweaks: edit files in place, then call
      `godot_reload`.
    <!-- /managed: motem -->
    """
}
