# macOS Claude Code GUI Wrapper — MVP 实施方案

## Context

目标：做一款 macOS 原生 App，最终愿景是「AI 游戏创作 studio」，但 **MVP 阶段先不碰游戏垂直功能**，回答一个先决问题——

> **用户是否愿意用一个 GUI 来跑 Claude Code，而不是直接在 iTerm 里 `claude`？**

如果这个假设被验证，再在 V2 叠加游戏专属能力（引擎集成、资源管线、AI 美术联动等）；如果被证伪，及时止损。

### 路线选择

经过评估，决定走 **包用户本机已安装的 `claude` CLI** 路线（PTY + SwiftTerm），不用 Claude Agent SDK：

- **理由**：SDK 不能复用用户 Pro/Max OAuth、不自动加载 plugins、需要用户提供 API key。包 CLI 才能继承用户的 auth/MCP/skills/plugins/hooks 等全套环境，开发成本最低。
- **法律边界**：Anthropic 条款禁止"third-party 代用户操作 Pro/Max 凭据"+"非 ordinary individual usage"。本方案保持纯交互式（用户主导每一步），不做自动化/调度/并行 agent，行为模式等同 iTerm/Warp，处于可辩护灰区。**任何后台自动化、批量任务、定时执行都不在 MVP 范围**，留给 V2 + API key 模式。
- **不 bundle CLI**：Claude Code 是 Anthropic 专有软件，不可重分发；引导用户自己 `npm i -g`。
- **不动用户凭据**：让 `claude` 自己处理 auth，App 完全不读 `~/.claude/` 里的 token。

## 约束清单

| 项 | 决策 |
|---|---|
| 分发 | Developer ID + notarization 直接分发；放弃 Mac App Store（沙盒限制 spawn + 任意路径访问）|
| 命名 | 自起品牌名，不含 "Claude" / "Claude Code"；上线前 email `sales@anthropic.com` 做商标确认 |
| 营销文案 | 中性："works with your existing Claude Code setup"；不强调"用你的 Pro/Max 订阅" |
| CLI 安装 | 不打包，引导 `npm i -g @anthropic-ai/claude-code` |
| 配置目录 | 不污染 `~/.claude/`；任何 App 自身状态写到 `~/Library/Application Support/<AppName>/` |
| 自动化能力 | V1 一律不做（合规红线）|

---

## V1 功能范围

### 必做（6 项）

| # | 功能 | 验收要点 |
|---|---|---|
| 1 | 嵌入式终端 + Claude CLI 启动 | SwiftTerm + PTY，TUI / slash command / permission prompt 行为 100% 等同 iTerm |
| 2 | 项目（Workspace）管理 | Open Folder → 该目录起 claude；最近项目列表；每项目独立会话 |
| 3 | 文件树 + 单文件预览 | gitignore 感知；点击文件右侧只读预览；FSEvents 实时刷新；**不做编辑** |
| 4 | CLI 探测 + 引导安装 | 启动检测 `which claude`；缺失则弹引导页；版本过旧提示升级 |
| 5 | 多会话 Tab | 同项目多 tab；不同项目快速切换 |
| 6 | 设置面板（最小集）| 字体/字号/主题、默认工作目录、**多语言（详见下方）** |

### 强烈建议（2 项，差异化关键）

| # | 功能 | 收益 |
|---|---|---|
| 7 | Diff 查看器 | 顶部 git 状态 badge，点开看 diff；Claude 改完文件 review 不切窗口 |
| 8 | 截图 / 文件拖入终端 | 拖图片/文件到终端 → 自动转路径粘贴；`⌘⇧4` 截图自动塞 prompt |

### 明确不做

Plugin Manager UI、MCP Manager UI、Skill 浏览器、Task Panel（解析 CLI 状态）、自有插件市场、自动化 / `/loop` 一键 / 调度 / 并行 agent、文件编辑器、API Key 计费、游戏专属功能、自动升级 CLI、多窗口。

### V1 成功标准

- 首次跑通 `claude` 对话率 ≥ 80%
- 装完一周留存 ≥ 30%
- 用户能说出至少 1 个具体的"为什么用这个不用 iTerm"的理由
- 0 严重 bug（CLI 行为不一致 / TUI 渲染错乱）

---

## 架构总览

```text
┌─────────────────────────────────────────┐
│             macOS App (SwiftUI)         │
│  ┌─────────────────────────────────┐    │
│  │ ProjectListView │ TerminalTabs  │    │
│  │ FileTree        │ DiffPanel     │    │
│  │ SettingsView    │               │    │
│  └─────────────────────────────────┘    │
│           │                              │
│           ▼                              │
│  ┌─────────────────────────────────┐    │
│  │ LocalizationManager (i18n)      │    │
│  │ ProjectStore (recent projects)  │    │
│  │ TerminalSessionManager          │    │
│  └─────────────────────────────────┘    │
│           │                              │
│           ▼                              │
│  ┌─────────────────────────────────┐    │
│  │ SwiftTerm.LocalProcessTerminal  │    │
│  │           │                     │    │
│  │           ▼                     │    │
│  │       PTY + forkpty             │    │
│  └─────────────┬───────────────────┘    │
└────────────────┼─────────────────────────┘
                 ▼
        ┌────────────────────┐
        │  /usr/local/bin/   │
        │  claude (用户安装) │
        └────────┬───────────┘
                 ▼
        ┌────────────────────┐
        │ ~/.claude (用户)   │
        │ auth / plugins /   │
        │ skills / mcp       │
        └────────────────────┘
```

---

## 项目结构

```text
ClaudeStudio.xcodeproj
Sources/
├── App/
│   ├── ClaudeStudioApp.swift              # @main
│   └── ContentView.swift                  # 主窗口路由
├── Terminal/                              # 功能 #1
│   ├── ClaudeTerminalView.swift           # LocalProcessTerminalView 子类
│   ├── TerminalHostView.swift             # SwiftUI 包装
│   ├── TerminalEnvironment.swift          # 环境变量构造
│   ├── ClaudeBinaryLocator.swift          # 找 claude 路径
│   └── TerminalSessionManager.swift       # 会话管理（多 Tab）
├── Project/                               # 功能 #2
│   ├── ProjectStore.swift                 # 最近项目持久化
│   ├── ProjectPickerView.swift
│   └── WorkspaceView.swift
├── FileTree/                              # 功能 #3
│   ├── FileTreeView.swift
│   ├── GitignoreFilter.swift
│   └── FilePreviewView.swift
├── Onboarding/                            # 功能 #4
│   ├── CLIDetector.swift
│   └── InstallGuideView.swift
├── Diff/                                  # 功能 #7
│   └── GitDiffView.swift
├── DragDrop/                              # 功能 #8
│   └── TerminalDropHandler.swift
├── Settings/                              # 功能 #6
│   ├── SettingsView.swift
│   └── GeneralSettingsView.swift
└── Localization/                          # 多语言
    ├── LocalizationManager.swift
    ├── AppLanguage.swift
    ├── L10n.swift
    └── Localizable.xcstrings              # Xcode 15+ String Catalog

Resources/
├── Assets.xcassets
└── Info.plist
```

---

## 功能 #1：嵌入式终端 + Claude CLI（详细）

### 依赖

- **SwiftTerm**：`https://github.com/migueldeicaza/SwiftTerm`
  - 直接用其 `LocalProcessTerminalView`（封装好 PTY + 终端渲染 + ANSI 解析）
  - 不要自己写 `forkpty`

### 1.1 找到 `claude` 可执行文件

`ClaudeBinaryLocator.swift`：

```swift
enum ClaudeBinaryLocator {
    static func locate() -> URL? {
        if let path = whichViaLoginShell("claude") {
            return URL(fileURLWithPath: path)
        }
        let fallbacks = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return fallbacks.lazy.map(URL.init(fileURLWithPath:)).first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private static func whichViaLoginShell(_ bin: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "which \(bin)"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (out?.isEmpty == false) ? out : nil
    }
}
```

**坑**：macOS GUI app 从 launchd 启动，不加载 `~/.zshrc`，必须用 login shell 解析 PATH（nvm/volta/asdf 都在 shell rc 里设置）。

### 1.2 环境变量构造

`TerminalEnvironment.swift`：

```swift
struct TerminalEnvironment {
    static func build(workingDirectory: URL, appLanguage: AppLanguage) -> [String: String] {
        let parent = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]

        let inherit = ["HOME", "USER", "LOGNAME", "SHELL",
                       "TMPDIR", "SSH_AUTH_SOCK",
                       "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"]
        for key in inherit { if let v = parent[key] { env[key] = v } }

        env["PATH"] = resolvedPath(shell: parent["SHELL"] ?? "/bin/zsh")
                      ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["FORCE_COLOR"] = "1"

        // 多语言 → LANG / LC_ALL（影响 git/npm 等子工具输出）
        switch appLanguage {
        case .system:
            if let v = parent["LANG"] { env["LANG"] = v }
            if let v = parent["LC_ALL"] { env["LC_ALL"] = v }
        case .chinese:
            env["LANG"] = "zh_CN.UTF-8"
            env["LC_ALL"] = "zh_CN.UTF-8"
        case .english:
            env["LANG"] = "en_US.UTF-8"
            env["LC_ALL"] = "en_US.UTF-8"
        }

        // 严禁：不要设 ANTHROPIC_API_KEY / CLAUDE_CONFIG_DIR / 任何 CLAUDE_*
        // 让 claude 走自己的认证和配置目录

        return env
    }

    private static func resolvedPath(shell: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-l", "-c", "echo $PATH"]
        let pipe = Pipe(); p.standardOutput = pipe
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

**禁止行为**：
- 不要清空环境只塞最小集（会破坏 nvm/Homebrew）
- 不要直接 copy `Process.environment`（已被 launchd 污染）
- 不要触碰任何 `CLAUDE_*` / `ANTHROPIC_*` 变量

### 1.3 启动 claude

`ClaudeTerminalView.swift`：

```swift
import SwiftTerm
import AppKit

final class ClaudeTerminalView: LocalProcessTerminalView, LocalProcessTerminalViewDelegate {
    private let workingDir: URL
    var onExit: ((Int32) -> Void)?
    var onTitleChange: ((String) -> Void)?

    init(workingDir: URL, frame: NSRect) {
        self.workingDir = workingDir
        super.init(frame: frame)
        self.processDelegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func start() {
        guard let claude = ClaudeBinaryLocator.locate() else {
            feed(text: "\r\n\u{1b}[31m\(L10n.string("terminal.notFound.title"))\u{1b}[0m\r\n")
            feed(text: "  \(L10n.string("terminal.notFound.install"))\r\n")
            return
        }
        let env = TerminalEnvironment.build(
            workingDirectory: workingDir,
            appLanguage: LocalizationManager.shared.language
        )
        let envArray = env.map { "\($0.key)=\($0.value)" }

        // 用 shell -ilc 包一层 cd，保证 .zshrc 完整加载 + 切到项目目录
        startProcess(
            executable: "/bin/zsh",
            args: ["-ilc", "cd \(workingDir.path.shellEscaped) && exec \(claude.path.shellEscaped)"],
            environment: envArray,
            execName: "-zsh"
        )
    }

    // MARK: - Delegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { onTitleChange?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { onExit?(exitCode ?? -1) }
}

extension String {
    var shellEscaped: String { "'\(replacingOccurrences(of: "'", with: "'\\''"))'" }
}
```

### 1.4 SwiftUI 包装

`TerminalHostView.swift`：

```swift
struct TerminalHostView: NSViewRepresentable {
    let workingDir: URL
    @Binding var title: String

    func makeNSView(context: Context) -> ClaudeTerminalView {
        let view = ClaudeTerminalView(workingDir: workingDir, frame: .zero)
        view.onTitleChange = { title = $0 }
        view.onExit = { code in NSLog("claude exited: \(code)") }
        // 必须延后到 layout 之后，否则 cols/rows = 0 会破坏 ink TUI
        DispatchQueue.main.async { view.start() }
        return view
    }
    func updateNSView(_ nsView: ClaudeTerminalView, context: Context) {}
}
```

### 1.5 Resize / 信号 / 退出

- **Resize**：SwiftTerm 自动 `ioctl(TIOCSWINSZ)`，不用写
- **Ctrl-C**：SwiftTerm 默认正确传 `\x03`，由 tty driver 处理
- **关 Tab**：发 `\x04`（EOF）让 claude 优雅退出
- **App quit**：`applicationWillTerminate` 遍历所有 terminal view 发 SIGHUP，防进程残留

### 1.6 验收 checklist（#1）

| 测试项 | 期望 |
|---|---|
| `claude` 启动后看到欢迎界面 | ✅ |
| 输入中文 | 无乱码 |
| `/loop`, `/codex`, `/plan` slash command | 菜单正常 |
| Shift+Tab → Plan mode | TUI 框正确渲染 |
| Permission prompt | 方向键可选 |
| 调用 `npm` / `git` 子命令 | 输出实时刷新 |
| 窗口 resize | claude 内部 UI 跟随重排 |
| Ctrl-C / Ctrl-D / `exit` | 行为等同 iTerm |
| 大量输出（`find /`） | 不掉帧、不爆内存 |
| 首次 OAuth 登录 | 浏览器回调成功 |

### 1.7 常见坑速查

| 现象 | 解决 |
|---|---|
| `command not found: claude` | `whichViaLoginShell` 走 login shell |
| TUI 边框乱码 | `TERM=xterm-256color` |
| 颜色变黑白 | `FORCE_COLOR=1` |
| nvm 装的 node 跑不起 | 必须 `zsh -ilc` 包一层 |
| 启动后空白 | `DispatchQueue.main.async` 延后 start |
| 关 App 后 claude 残留 | `applicationWillTerminate` 发 SIGHUP |

---

## 多语言支持（功能 #6 子模块）

三种模式：**跟随系统** / **简体中文** / **English**。运行时切换，**无需重启**。

### 核心思路

SwiftUI 原生 `Text("key")` 只读 `Bundle.main`，**无法运行时切换**。所以自建 `LocalizationManager` 维护"当前生效 bundle"，通过 `@Published` 触发 SwiftUI 重渲染。

### 实现

`AppLanguage.swift`：

```swift
enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system, chinese, english
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system:  return L10n.string("settings.language.system")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }
}
```

`LocalizationManager.swift`：

```swift
final class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()

    @Published private(set) var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
            updateBundle()
        }
    }
    private(set) var bundle: Bundle = .main
    private static let defaultsKey = "AppLanguage"
    private var systemLocaleObserver: NSObjectProtocol?

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? AppLanguage.system.rawValue
        self.language = AppLanguage(rawValue: raw) ?? .system
        updateBundle()

        systemLocaleObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.language == .system else { return }
            self.updateBundle()
            self.objectWillChange.send()
        }
    }

    func setLanguage(_ lang: AppLanguage) {
        guard lang != language else { return }
        language = lang
    }

    private func updateBundle() {
        let code: String
        switch language {
        case .system:
            code = Bundle.main.preferredLocalizations.first(where: {
                $0.hasPrefix("zh") || $0.hasPrefix("en")
            }) ?? "en"
        case .chinese: code = "zh-Hans"
        case .english: code = "en"
        }
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let b = Bundle(path: path) { self.bundle = b }
        else { self.bundle = .main }
    }

    var currentLocale: Locale {
        switch language {
        case .system:  return .current
        case .chinese: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        }
    }
}
```

`L10n.swift`：

```swift
enum L10n {
    static func string(_ key: String, _ args: CVarArg...) -> String {
        let m = LocalizationManager.shared
        let format = m.bundle.localizedString(forKey: key, value: nil, table: nil)
        return args.isEmpty ? format : String(format: format, arguments: args)
    }
}

struct LocalizedText: View {
    @ObservedObject private var manager = LocalizationManager.shared
    let key: String
    let args: [CVarArg]
    init(_ key: String, _ args: CVarArg...) { self.key = key; self.args = args }
    var body: some View { Text(L10n.string(key, args)) }
}

typealias T = LocalizedText
```

### App 入口注入

```swift
@main
struct ClaudeStudioApp: App {
    @StateObject private var l10n = LocalizationManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, l10n.currentLocale)
                .environmentObject(l10n)
        }
        Settings {
            SettingsView()
                .environment(\.locale, l10n.currentLocale)
                .environmentObject(l10n)
        }
    }
}
```

### 设置 UI

```swift
struct GeneralSettingsView: View {
    @EnvironmentObject var l10n: LocalizationManager
    var body: some View {
        Form {
            Picker(selection: Binding(
                get: { l10n.language },
                set: { l10n.setLanguage($0) }
            )) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
            } label: { T("settings.language.label") }
            .pickerStyle(.inline)

            T("settings.language.hint")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding().frame(width: 420)
    }
}
```

### String Catalog

`Localizable.xcstrings`（Xcode 15+），在 Project Editor → Info → Localizations 添加 **English** 和 **Chinese, Simplified (zh-Hans)**。

初始 key 集（按 scope 命名）：

| Key | English | 简体中文 |
|---|---|---|
| `settings.language.label` | Language | 语言 |
| `settings.language.system` | Follow System | 跟随系统 |
| `settings.language.hint` | Changes apply immediately. Open new sessions to apply to terminal. | 切换后立即生效。终端会话需新建后才会切换语言。|
| `terminal.notFound.title` | Claude Code not found | 未找到 Claude Code |
| `terminal.notFound.install` | Run `npm i -g @anthropic-ai/claude-code` to install. | 运行 `npm i -g @anthropic-ai/claude-code` 安装。|
| `project.open` | Open Folder… | 打开文件夹… |
| `project.recent` | Recent Projects | 最近项目 |
| `tab.new` | New Session | 新会话 |
| `onboarding.welcome` | Welcome | 欢迎 |
| `settings.appearance` | Appearance | 外观 |
| `settings.font` | Font | 字体 |

### 用法约定

- **所有 View 中文本** → 用 `T("key")`，不要再写 `Text("...")`
- **非 View 上下文**（如终端注入的错误提示）→ 用 `L10n.string("key")`
- **新功能开发** → 先加 key 到 xcstrings 再写代码

### 终端会话的语言传递

PTY 进程的环境变量在 fork 时复制，**已开终端会话不会因语言切换而改 `LANG`**。

策略：
- 切换语言后，UI 文案立即变
- 已开会话保持原 `LANG`（避免破坏性重启）
- 在设置 hint 里明示"终端会话需新建后才会切换语言"
- 新开会话使用最新 `LANG` 注入（见 §1.2）

### 验收 checklist（多语言）

- [ ] 切到「简体中文」→ 菜单/按钮/Label 立即变中文，无需重启
- [ ] 切到「English」→ 立即变英文
- [ ] 切到「跟随系统」→ 匹配 macOS 当前语言
- [ ] macOS 系统语言变化时，跟随模式自动响应
- [ ] App 重启后保留上次选择
- [ ] 新终端会话调 `git status` 在中文模式下输出中文错误信息
- [ ] `Text(Date.now, style: .date)` 中文模式显示「2026年5月15日」，英文「May 15, 2026」
- [ ] xcstrings 漏翻 key → fallback 英文（不崩、不显示原 key）

---

## 实施时间线（单人，4–6 周）

| 周 | 工作 | 产出 |
|---|---|---|
| 1 | 项目脚手架、SwiftTerm 集成、`ClaudeBinaryLocator` | 能在 App 里跑通 `claude` |
| 2 | `TerminalEnvironment`、`ClaudeTerminalView`、`CLIDetector` + 引导页 | 功能 #1 + #4 完整 |
| 3 | `ProjectStore`、`WorkspaceView`、最近项目持久化、多 Tab | 功能 #2 + #5 |
| 4 | 文件树、gitignore 过滤、文件预览、设置面板基础 | 功能 #3 + #6 基础 |
| 5 | **多语言（i18n）**、Diff 查看器、拖拽 | 功能 #6 完整 + #7 + #8 |
| 6 | 打磨、内测、代码签名 + 公证、官网准备 | V1 发布 |

---

## 关键文件清单（实施时优先创建）

| 路径 | 用途 | 必读参考 |
|---|---|---|
| `Sources/Terminal/ClaudeBinaryLocator.swift` | claude 路径解析 | 本方案 §1.1 |
| `Sources/Terminal/TerminalEnvironment.swift` | 环境变量构造（含 LANG）| §1.2 |
| `Sources/Terminal/ClaudeTerminalView.swift` | PTY 终端核心 | §1.3 |
| `Sources/Terminal/TerminalHostView.swift` | SwiftUI 桥接 | §1.4 |
| `Sources/Localization/LocalizationManager.swift` | 多语言核心 | i18n 实现 |
| `Sources/Localization/L10n.swift` | 取字符串入口 | i18n 实现 |
| `Sources/Localization/AppLanguage.swift` | 三种模式枚举 | i18n 实现 |
| `Sources/Localization/Localizable.xcstrings` | 字符串目录 | Xcode 新建 |
| `Sources/App/ClaudeStudioApp.swift` | App 入口，环境注入 | i18n 实现 |
| `Sources/Settings/GeneralSettingsView.swift` | 语言选择 UI | i18n 实现 |

---

## 端到端验证

### 准备
1. macOS 13+，Xcode 15+
2. 用户机器已装 Node + `claude` CLI 并完成 OAuth 登录

### 验证流程

1. **构建运行**：Xcode Run，App 启动
2. **CLI 探测**：故意改 PATH 让 `claude` 找不到 → 应弹引导页；恢复 PATH → 正常启动
3. **终端核心**：参照 §1.6 checklist 逐项跑
4. **多语言**：参照"多语言验收 checklist"逐项跑
5. **完整对话**：在 App 里跑一次真实任务（如让 `claude` 改一个文件 + 用 `/plan` + 同意 permission prompt + 完成）
6. **对比 iTerm**：同样任务在 iTerm 里跑，行为应 100% 一致
7. **资源占用**：连续使用 1 小时，内存/CPU 无异常增长
8. **进程清理**：关闭 App，`ps aux | grep claude` 应无残留

### 法律自查

- [ ] App 内任何位置不出现 "Claude Code" 作为产品名
- [ ] 营销文案不暗示"用 Pro/Max 订阅省 API 费"
- [ ] 无任何后台/调度/批量/并行 agent 功能
- [ ] 不读 `~/.claude/` 任何文件
- [ ] 不 bundle `claude` 二进制
- [ ] `sales@anthropic.com` 发出商标确认邮件（上线前完成）

---

## V2 预留（不在本方案范围）

游戏垂直功能：Godot/Unity 集成、资源管线、AI 美术联动、关卡预览、热重载；
商业化路径：API key 模式 + 计费 + 后台自动化能力；
插件市场：自有 plugin/skill 分发。

V1 用户假设验证通过后再启动。
