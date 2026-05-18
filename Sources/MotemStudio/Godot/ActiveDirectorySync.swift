import Foundation

/// Manages the single `_active` working directory that Godot's engine is pinned to.
///
/// Godot's engine is a process-level singleton: once `GodotApp.start()` runs with
/// `--path <X>`, the engine refuses to switch source paths. Every AI-generated
/// project is therefore mirrored into one fixed location and the engine reloads
/// resources from there.
enum ActiveDirectorySync {

    enum SyncError: Error, LocalizedError {
        case sourceMissing(URL)
        case sourceNotADirectory(URL)
        case noProjectFile(URL)
        case rsyncFailed(exitCode: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .sourceMissing(let url):
                return "Source directory does not exist: \(url.path)"
            case .sourceNotADirectory(let url):
                return "Source path is not a directory: \(url.path)"
            case .noProjectFile(let url):
                return "Source directory is missing project.godot: \(url.path)"
            case .rsyncFailed(let code, let stderr):
                return "rsync failed (exit \(code)): \(stderr)"
            }
        }
    }

    /// Absolute URL of the `_active` directory. Created on first access.
    static let activeURL: URL = {
        let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let base = appSupport ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let url = base.appendingPathComponent("MotemStudio/_active", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Sub-directory under `_active` where user/agent projects live.
    /// The host scene at `_active/` root never moves; only this folder
    /// is wiped and rewritten on each `godot_preview`.
    static var loadedGameURL: URL {
        activeURL.appendingPathComponent("loaded_game", isDirectory: true)
    }

    /// Mirror `srcDir` into `_active/loaded_game/`, dropping engine caches
    /// and VCS metadata. The host scene at `_active/` (project.godot +
    /// __motem_host__) is left untouched.
    @discardableResult
    static func syncProjectToActive(srcDir: URL) throws -> URL {
        try validate(srcDir)

        let dstDir = loadedGameURL
        try FileManager.default.createDirectory(at: dstDir, withIntermediateDirectories: true)

        let src = srcDir.path.hasSuffix("/") ? srcDir.path : srcDir.path + "/"
        let dst = dstDir.path.hasSuffix("/") ? dstDir.path : dstDir.path + "/"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/rsync")
        process.arguments = [
            "-a",
            "--delete",
            // Preserve `.godot/` from backend-supplied zips: that's
            // where the pre-built `imported/*.ctex` textures and font
            // data live. macOS Motem Studio runs the engine on a host
            // project rooted elsewhere, so Godot never re-runs its
            // import pipeline for the loaded game — without these
            // cached files every texture / font load fails.
            "--exclude=.git",
            "--exclude=.DS_Store",
            src,
            dst,
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw SyncError.rsyncFailed(exitCode: process.terminationStatus, stderr: stderr)
        }

        // Rebase every `res://...` reference inside the sync'd files so
        // they resolve relative to the engine root (`_active/`), which
        // is rooted at the host project — not the user's project. We
        // skip `project.godot` because the host script parses it
        // verbatim and adds the prefix on its own.
        rebaseResPaths(in: dstDir, prefix: "loaded_game")

        return dstDir
    }

    /// Rewrite every `res://...` occurrence inside text resources under
    /// `dir` to `res://<prefix>/...`, so a project that was authored at
    /// the engine root continues to resolve cleanly when nested into
    /// `_active/<prefix>/`. Already-rebased paths are left alone.
    static func rebaseResPaths(in dir: URL, prefix: String) {
        let fm = FileManager.default
        let extensions: Set<String> = [
            "tscn", "tres", "gd", "gdshader", "shader", "json", "cfg", "import",
        ]
        let pattern: NSRegularExpression
        do {
            // (?<!loaded_game/) — don't match if already prefixed.
            // [A-Za-z_0-9] in the negative lookbehind would be cleaner
            // but ICU regex doesn't allow variable-length lookbehind on
            // older Apple platforms, so we use a fixed-length one here.
            let escaped = NSRegularExpression.escapedPattern(for: prefix)
            pattern = try NSRegularExpression(pattern: "res://(?!\(escaped)/)")
        } catch {
            NSLog("[ActiveDirectorySync] regex compile failed: \(error)")
            return
        }
        let replacement = "res://\(prefix)/"

        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard extensions.contains(ext) else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(content.startIndex..<content.endIndex, in: content)
            let rewritten = pattern.stringByReplacingMatches(
                in: content,
                options: [],
                range: range,
                withTemplate: replacement
            )
            if rewritten != content {
                try? rewritten.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    /// True when `_active/project.godot` exists, i.e. the engine has something
    /// to launch against.
    static var activeHasProject: Bool {
        let projectFile = activeURL.appendingPathComponent("project.godot")
        return FileManager.default.fileExists(atPath: projectFile.path)
    }

    /// Lay down the persistent host project under `_active`. The host
    /// scene stays the engine's `current_scene` for the entire app
    /// lifetime; user projects are loaded as children to avoid the
    /// libgodot-macOS `cursor_set_shape` / `set_mouse_mode` crashes that
    /// fire during `_flush_scene_change`.
    ///
    /// Writes are idempotent — if the host files already match, this is
    /// a no-op. We always overwrite to keep the host script in sync
    /// with whatever the Swift side expects of it.
    static func ensureStubProject() {
        let dir = activeURL
        let hostDir = dir.appendingPathComponent("__motem_host__", isDirectory: true)
        try? FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)

        // 1194×834 is the design resolution every AI-generated game
        // is authored against (kept identical to iOS for cross-platform
        // parity). `stretch_mode=canvas_items` + `aspect=keep` makes
        // Godot scale + letterbox automatically so the same scene
        // renders correctly inside any preview-pane size the user
        // drags the splitter to on macOS.
        //
        // The `InputBridge` autoload makes `/root/InputBridge` always
        // available so `MacOSInputAdapter` can pump the 9 properties
        // straight into a stable node, regardless of which AI game is
        // currently loaded under the host.
        // Register ALL FOUR autoloads up front. AI-generated games
        // routinely reference `AudioManager`, `GameManager`, `I18n`
        // from their main scripts; if any of those symbols aren't
        // declared at parse time, the game's main.gd refuses to load
        // and the user sees a white pane. `TemplateBundleSync` only
        // ships the rich autoload implementations after the user
        // signs in, so we have to register the names — backed by stub
        // scripts — from the very first boot.
        let projectGodot = """
        config_version=5

        [application]
        config/name=\"MotemStudioHost\"
        run/main_scene=\"res://__motem_host__/host.tscn\"
        config/features=PackedStringArray(\"4.4\")
        boot_splash/show_image=false
        boot_splash/bg_color=Color(0.05, 0.05, 0.08, 1)

        [autoload]
        InputBridge=\"*res://__motem_host__/input_bridge.gd\"
        GameManager=\"*res://__motem_host__/game_manager.gd\"
        I18n=\"*res://__motem_host__/i18n.gd\"
        AudioManager=\"*res://__motem_host__/audio_manager.gd\"

        [display]
        window/size/viewport_width=1194
        window/size/viewport_height=834
        window/stretch/mode=\"canvas_items\"
        window/stretch/aspect=\"expand\"

        [input_devices]
        pointing/emulate_touch_from_mouse=true

        [rendering]
        renderer/rendering_method.mobile=\"mobile\"
        """
        let hostTscn = """
        [gd_scene load_steps=2 format=3]

        [ext_resource type=\"Script\" path=\"res://__motem_host__/host.gd\" id=\"1\"]

        [node name=\"Host\" type=\"Node2D\"]
        script = ExtResource(\"1\")
        """
        // Host script — owns one optional child (the AI-generated game).
        // Polls a token file for changes so we never have to call any
        // scene-change API from the Swift side. queue_free + instantiate
        // + add_child avoids `_flush_scene_change`, the function whose
        // cursor handling crashes on macOS embedded.
        let hostGd = #"""
        extends Node2D

        const TOKEN_PATH := "res://__motem_host__/reload_token.txt"
        const LOADED_DIR := "res://loaded_game"

        var loaded_scene: Node = null
        var last_token: String = ""
        var poll_accum: float = 0.0

        func _ready() -> void:
        	# Cold-start fix: SwiftGodotKit's embedded DisplayServer reports
        	# the real pane size only after the first SwiftUI layout pass,
        	# which happens *after* _ready runs on the very first boot.
        	# Without a nudge, the first scene loads with the viewport still
        	# at project.godot's declared 1194x834 — stretch=expand can't
        	# expand because it sees the design size as the window size, so
        	# the game renders in the upper-left and leaves grey to the
        	# right. Subsequent reloads work because the resize event has
        	# arrived in between. Wait one process frame for the embedded
        	# DisplayServer to publish actual bounds, then force the root
        	# viewport to match — this re-runs the stretch calc and the
        	# first game fills the pane like every later one does.
        	await get_tree().process_frame
        	_sync_root_to_display()
        	_check_reload()

        func _sync_root_to_display() -> void:
        	var ds_size := DisplayServer.window_get_size()
        	if ds_size.x <= 0 or ds_size.y <= 0:
        		return
        	var win := get_window()
        	if win != null and win.size != ds_size:
        		win.size = ds_size

        func _process(delta: float) -> void:
        	poll_accum += delta
        	if poll_accum > 0.25:
        		poll_accum = 0.0
        		_check_reload()

        func _draw() -> void:
        	if loaded_scene == null:
        		draw_rect(Rect2(0, 0, 4000, 4000), Color(0.05, 0.05, 0.08))

        func _check_reload() -> void:
        	var token := ""
        	if FileAccess.file_exists(TOKEN_PATH):
        		var f := FileAccess.open(TOKEN_PATH, FileAccess.READ)
        		if f != null:
        			token = f.get_as_text()
        			f.close()
        	if token == last_token:
        		return
        	last_token = token
        	_swap_to_loaded()

        func _swap_to_loaded() -> void:
        	# Reset the cross-platform input contract for the incoming
        	# scene so the previous game's leftover gameplay_active flag
        	# doesn't make the macOS host re-arm the camera before the
        	# player has tapped the new game's START screen. The bridge
        	# is an autoload and persists across scene swaps, so without
        	# this reset the new game would inherit `gameplay_active=true`
        	# left over from the previous _enter_playing().
        	var bridge := get_node_or_null("/root/InputBridge")
        	if bridge != null:
        		bridge.gameplay_active = false
        	if loaded_scene != null and is_instance_valid(loaded_scene):
        		# Force-reparse every script attached to the previous
        		# scene tree. Without this, Godot's ScriptServer keeps
        		# the old parsed bytecode under res://loaded_game/...
        		# paths and the next instantiate() runs the previous
        		# game's logic — second-game-onwards renders white.
        		_reload_scripts_in_tree(loaded_scene)
        		remove_child(loaded_scene)
        		loaded_scene.queue_free()
        		loaded_scene = null
        	var entry := _resolve_entry()
        	if entry == "":
        		queue_redraw()
        		return
        	var packed := ResourceLoader.load(entry, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE_DEEP)
        	if packed == null or not (packed is PackedScene):
        		push_error("[motem-host] failed to load %s" % entry)
        		return
        	var inst := (packed as PackedScene).instantiate()
        	if inst == null:
        		push_error("[motem-host] failed to instantiate %s" % entry)
        		return
        	loaded_scene = inst
        	add_child(loaded_scene)
        	queue_redraw()
        	print("[motem-host] loaded %s" % entry)

        func _reload_scripts_in_tree(root: Node) -> void:
        	# Typed Array[Node] + explicit casts keep the file parseable
        	# under `gdscript/warnings/treat_warnings_as_errors=true`,
        	# which the host project enables to catch AI-generated game
        	# code that drifts from typed-GDScript style.
        	var stack: Array[Node] = [root]
        	while not stack.is_empty():
        		var node: Node = stack.pop_back()
        		var s: Script = node.get_script() as Script
        		if s != null:
        			s.reload(false)
        		for child: Node in node.get_children():
        			stack.append(child)

        func _resolve_entry() -> String:
        	# Prefer the loaded project's declared main scene; fall back
        	# to common conventions if project.godot is missing or odd.
        	var candidates := [
        		"res://loaded_game/scenes/main.tscn",
        		"res://loaded_game/main.tscn",
        	]
        	# Try reading run/main_scene out of loaded_game/project.godot.
        	if FileAccess.file_exists("res://loaded_game/project.godot"):
        		var f := FileAccess.open("res://loaded_game/project.godot", FileAccess.READ)
        		if f != null:
        			var text := f.get_as_text()
        			f.close()
        			var lines := text.split("\n", false)
        			for raw in lines:
        				var line := raw.strip_edges()
        				if line.begins_with("run/main_scene="):
        					var rest := line.substr("run/main_scene=".length()).strip_edges()
        					rest = rest.trim_prefix("\"").trim_suffix("\"")
        					if rest.begins_with("res://"):
        						# rewrite as a path inside loaded_game
        						var sub := rest.substr("res://".length())
        						var resolved := "res://loaded_game/%s" % sub
        						if FileAccess.file_exists(resolved):
        							return resolved
        	for c in candidates:
        		if FileAccess.file_exists(c):
        			return c
        	return ""
        """#
        // Minimal `InputBridge` mirroring the iOS template contract.
        // Hosts (iOS FaceDetector pump, macOS MacOSInputAdapter pump,
        // future controller bridges) write the 9 properties directly via
        // `Node.set(property:value:)`; the game scripts read them in
        // `_process()` / `_input()`. No signals are emitted — the contract
        // is property-polling for parity with the iOS implementation.
        let inputBridgeGd = """
        extends Node

        # 9 properties — cross-platform InputBridge contract. Hosts write
        # these every frame; game scripts poll them.
        var body_lean_x: float = 0.0
        var body_lean_y: float = 0.0
        var is_reaching_out: bool = false
        var is_ducking: bool = false
        var is_hands_up: bool = false
        var body_detected: bool = false
        var face_position: Vector2 = Vector2(0.5, 0.5)
        var face_detected: bool = false
        var hand_gesture: String = "none"
        var hand_position: Vector2 = Vector2(0.5, 0.5)
        """
        // project.godot is overwritten unconditionally — the four
        // autoload entries must be registered every launch, regardless
        // of whether a previous (one-autoload) version is on disk.
        // input_bridge.gd and the autoload stubs are seeded only when
        // missing; `TemplateBundleSync.installHostAutoloads` later
        // upgrades the same files in place with the upstream
        // implementations and we must not clobber its work.
        let projectGodotURL = dir.appendingPathComponent("project.godot")
        try? projectGodot.write(to: projectGodotURL, atomically: true, encoding: .utf8)
        let inputBridgeURL = hostDir.appendingPathComponent("input_bridge.gd")
        if !FileManager.default.fileExists(atPath: inputBridgeURL.path) {
            try? inputBridgeGd.write(to: inputBridgeURL, atomically: true, encoding: .utf8)
        }
        let autoloadStubs: [(filename: String, source: String)] = [
            ("audio_manager.gd", #"""
            extends Node
            # Stub: replaced by TemplateBundleSync.installHostAutoloads.
            func play(_name: String, _params: Variant = null) -> void: pass
            func stop(_name: String = "") -> void: pass
            func set_muted(_muted: bool) -> void: pass
            """#),
            ("game_manager.gd", #"""
            extends Node
            # Stub: replaced by TemplateBundleSync.installHostAutoloads.
            signal game_started
            signal game_over
            func emit_started() -> void: game_started.emit()
            func emit_over() -> void: game_over.emit()
            """#),
            ("i18n.gd", #"""
            extends Node
            # Stub: replaced by TemplateBundleSync.installHostAutoloads.
            var current_lang: String = "en"
            func translate(key: String, _params: Dictionary = {}) -> String: return key
            func set_lang(lang: String) -> void: current_lang = lang
            """#),
            ("i18n_strings.gd", #"""
            extends Node
            # Stub: replaced by TemplateBundleSync.installHostAutoloads.
            const STRINGS: Dictionary = {}
            """#),
        ]
        for stub in autoloadStubs {
            let url = hostDir.appendingPathComponent(stub.filename)
            if !FileManager.default.fileExists(atPath: url.path) {
                try? stub.source.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        try? hostTscn.write(to: hostDir.appendingPathComponent("host.tscn"), atomically: true, encoding: .utf8)
        try? hostGd.write(to: hostDir.appendingPathComponent("host.gd"), atomically: true, encoding: .utf8)

        // Initial token file (empty = nothing loaded yet)
        let tokenPath = hostDir.appendingPathComponent("reload_token.txt")
        if !FileManager.default.fileExists(atPath: tokenPath.path) {
            try? "".write(to: tokenPath, atomically: true, encoding: .utf8)
        }
    }

    /// Write a fresh token value so the host scene's poller detects a
    /// reload event and swaps its child node.
    static func touchReloadToken() {
        let token = "\(Date().timeIntervalSince1970)"
        let url = activeURL
            .appendingPathComponent("__motem_host__/reload_token.txt")
        try? token.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Install `AudioManager` / `GameManager` / `I18n` / `InputBridge`
    /// (plus the const `i18n_strings.gd` data file `I18n` depends on)
    /// as engine autoloads under the host project. Called by
    /// `TemplateBundleSync` right after it unpacks the backend bundle
    /// so loaded games which reference these autoloads parse cleanly.
    ///
    /// `res://` references inside each script are rebased to
    /// `res://loaded_game/...` — the originals expect a flat layout
    /// rooted at the game directory, but our engine root holds the
    /// host project with games nested under `loaded_game/`.
    static func installHostAutoloads(fromTemplate templateScriptsDir: URL) {
        let fm = FileManager.default
        let hostDir = activeURL.appendingPathComponent("__motem_host__", isDirectory: true)
        try? fm.createDirectory(at: hostDir, withIntermediateDirectories: true)

        let autoloadScripts = [
            "audio_manager.gd",
            "game_manager.gd",
            "i18n.gd",
            "i18n_strings.gd",
            "input_bridge.gd",
        ]

        for filename in autoloadScripts {
            let src = templateScriptsDir.appendingPathComponent(filename)
            guard fm.fileExists(atPath: src.path),
                  let raw = try? String(contentsOf: src, encoding: .utf8) else { continue }
            let rebased = rebaseResPathsInString(raw, prefix: "loaded_game")
            let dst = hostDir.appendingPathComponent(filename)
            try? rebased.write(to: dst, atomically: true, encoding: .utf8)
        }

        // Rewrite project.godot to register all four autoloads.
        // Settings (display / rendering / boot_splash) stay identical
        // to the stub project's defaults.
        let projectGodot = """
        config_version=5

        [application]
        config/name=\"MotemStudioHost\"
        run/main_scene=\"res://__motem_host__/host.tscn\"
        config/features=PackedStringArray(\"4.4\")
        boot_splash/show_image=false
        boot_splash/bg_color=Color(0.05, 0.05, 0.08, 1)

        [autoload]
        InputBridge=\"*res://__motem_host__/input_bridge.gd\"
        GameManager=\"*res://__motem_host__/game_manager.gd\"
        I18n=\"*res://__motem_host__/i18n.gd\"
        AudioManager=\"*res://__motem_host__/audio_manager.gd\"

        [display]
        window/size/viewport_width=1194
        window/size/viewport_height=834
        window/stretch/mode=\"canvas_items\"
        window/stretch/aspect=\"expand\"

        [input_devices]
        pointing/emulate_touch_from_mouse=true

        [rendering]
        renderer/rendering_method.mobile=\"mobile\"
        """
        try? projectGodot.write(
            to: activeURL.appendingPathComponent("project.godot"),
            atomically: true,
            encoding: .utf8
        )
    }

    /// In-place version of `rebaseResPaths` — used when we already
    /// hold the file contents in memory (autoload script copies).
    private static func rebaseResPathsInString(_ source: String, prefix: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: prefix)
        guard let pattern = try? NSRegularExpression(pattern: "res://(?!\(escaped)/)") else {
            return source
        }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return pattern.stringByReplacingMatches(
            in: source,
            options: [],
            range: range,
            withTemplate: "res://\(prefix)/"
        )
    }

    private static func validate(_ srcDir: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: srcDir.path, isDirectory: &isDir) else {
            throw SyncError.sourceMissing(srcDir)
        }
        guard isDir.boolValue else {
            throw SyncError.sourceNotADirectory(srcDir)
        }
        let projectFile = srcDir.appendingPathComponent("project.godot")
        guard FileManager.default.fileExists(atPath: projectFile.path) else {
            throw SyncError.noProjectFile(srcDir)
        }
    }
}
