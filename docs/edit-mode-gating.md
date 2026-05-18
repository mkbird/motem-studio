# 编辑态门控（Edit-mode gating）

## 背景

目前 `ContentView` 总是在 Godot preview 下面挂一个终端面板，并在
`onAppear` 时按 `DefaultAgent` 默认 spawn 一个 `TerminalSession`。
结果是：

- 用户只想"玩一下游戏 / 看 preview"时也会无意义地起一个 claude /
  codex / gemini 进程。
- 终端和游戏切换互不相关，用户在编辑一个游戏的途中点了 sidebar
  另一个游戏，agent 进程仍指向上一个目录，状态混乱。

期望行为：把终端从"常驻面板"改成"明确开启的编辑会话"。

## 新行为

| 状态 | 含义 | UI |
|---|---|---|
| `viewing`（默认）| 没有 agent，只是看 / 玩 | preview pane + sidebar；**无终端面板** |
| `editingExisting(URL)` | 正在编辑当前 preview 的游戏 | preview pane + 终端面板；sidebar / `+` 都锁住 |
| `editingNew` | 正在让 agent 新建游戏 | preview 清空 + 终端面板；sidebar / `+` 都锁住 |

### 入口（两条）

1. **编辑现有游戏**：preview pane 右侧 rail 加一个 ✏️ 图标（沿用
   现有 `MotemRailIcon`）。仅当 `controller.state == .running`
   且当前不在编辑态时显示。点击 → `editingExisting(currentProjectDir)`。
2. **新建游戏**：macOS 窗口 toolbar 右上加一个 `+` 按钮（用
   SwiftUI 原生 `.toolbar { ToolbarItem(placement: .primaryAction) }`）。
   点击 → `controller.stop()` 把预览清空 + `editingNew`。

### 出口（两条）

1. **Publish 成功（主路径）**：`PublishController.state` 转入
   `.success(...)` → 自动 `endEditing()`，终端面板移除。
2. **Discard editing（兜底）**：终端 tab bar 右侧加一个小的
   `xmark.circle` 按钮，仅在编辑态显示。点击 → `.confirmationDialog`
   二次确认 → `endEditing()`。**仅终止 PTY，不回滚 agent 已经写到
   磁盘的改动**（保持简单，文件层面就是它现在的样子）。

### 锁

进入编辑态后：

- `GameLibrarySidebar` 每一行 `Button` 加 `.disabled(EditModeStore.shared.isEditing)`。
- toolbar `+` 按钮加 `.disabled(...)`。
- preview pane 的 ✏️ 图标隐藏（自己再点没意义）。
- 终端 tab bar 最后一个 chip 的关闭 X **禁用**（强制走 Publish 或
  Discard，不留"关掉最后一个 session 就空着"的歧义路径）。

## 状态机实现

### 新文件：`Sources/MotemStudio/State/EditModeStore.swift`

```swift
@MainActor
final class EditModeStore: ObservableObject {
    static let shared = EditModeStore()

    enum Mode: Equatable {
        case viewing
        case editingExisting(projectDir: URL)
        case editingNew
    }

    @Published private(set) var mode: Mode = .viewing
    var isEditing: Bool { mode != .viewing }

    func beginEditExisting(_ url: URL) { mode = .editingExisting(projectDir: url) }
    func beginEditNew()                { mode = .editingNew }
    func endEditing()                  { mode = .viewing }
}
```

单例 store，是 UI 的唯一真相源。`ContentView` 订阅它驱动终端面板
mount/unmount；sidebar / preview rail / toolbar 都读 `isEditing`
联动 disabled 状态。**`PublishController` 不直接调用 store**——单向依赖，
UI 侧用 `.sink` 桥接两个 store，保持 controller 纯净。

## 文件改动清单

### 1. `Sources/MotemStudio/State/EditModeStore.swift`（新建）

如上。

### 2. `Sources/MotemStudio/App/ContentView.swift`

- 删掉 `workspaceDetail.onAppear` 里的 eager spawn（line 59-66）。
- 加 `@ObservedObject private var editMode = EditModeStore.shared`。
- `workspaceDetail` 的 `VSplitView`：`terminalArea` 仅在
  `editMode.isEditing` 时渲染；否则只剩 preview pane。
- 订阅 `editMode.$mode`：
  - `.viewing → editing*`：`sessions = [TerminalSession(agent: defaultAgent)]`，
    `activeID = first.id`。
  - `editing* → .viewing`：`sessions = []`。SwiftTerm 的
    `LocalProcessTerminalView` deinit 自动给 PTY 子进程发 SIGHUP，
    所以**不需要**手动 kill claude 进程（CLAUDE.md gotchas
    line 441 已确认此机制）。
- 订阅 `PublishController.shared.$state`：进 `.success(...)` 时调用
  `editMode.endEditing()`。
- 在 `workspace` 视图上加 `.toolbar { ToolbarItem(placement: .primaryAction) { + 按钮 } }`，
  action: `Task { _ = await GodotPreviewController.shared.stop() }` +
  `editMode.beginEditNew()`，`.disabled(editMode.isEditing)`。
- 改 `TerminalTabBar` 签名，传 `isEditing` 和 `onDiscard` 进去：
  - 最后一个 session 的 chip 关闭 X 在 `isEditing` 时 `.disabled(true)`。
  - tab bar 右侧加 "Discard editing" 按钮（仅编辑态显示）。

### 3. `Sources/MotemStudio/Godot/GodotPreviewPane.swift`

- 加 `@ObservedObject private var editMode = EditModeStore.shared`。
- `rightRail`（line 213）顶部加一个 `MotemRailIcon(systemName: "pencil")`，
  显示条件：`case .running = controller.state` **且**
  `!editMode.isEditing`。Action: `editMode.beginEditExisting(controller.currentProjectDir!)`。
- 既有 camera / pause / paperplane 三个 rail icon **不动**，
  publish 仍然从那里走（编辑态也保留出口）。

### 4. `Sources/MotemStudio/Library/GameLibrarySidebar.swift`

- 加 `@ObservedObject private var editMode = EditModeStore.shared`。
- line 382 改：
  ```swift
  .disabled(store.loadingGameId != nil || editMode.isEditing)
  ```
- 可选：`.opacity(editMode.isEditing ? 0.55 : 1.0)` 加点视觉提示，
  让锁住状态显眼。

### 5. `Sources/MotemStudio/Backend/PublishController.swift`

**不动**。`@Published var state` 已经向外广播；ContentView 侧消费
即可。保持 controller 不感知 EditModeStore，依赖单向。

### 6. `Sources/MotemStudio/Localization/Localizable.xcstrings`

新增 5 个 key（每个都补 `en` + `zh-Hans`）：

| key | en | zh-Hans |
|---|---|---|
| `pane.action.edit` | Edit this game | 编辑这个游戏 |
| `toolbar.new_game.tooltip` | Create a new game | 新建游戏 |
| `edit.discard.button` | Discard editing | 放弃编辑 |
| `edit.discard.confirm.title` | Discard current edits? | 放弃本次编辑？ |
| `edit.discard.confirm.message` | The terminal will close. Files already saved by the agent stay on disk. | 终端会关闭。Agent 已经写到磁盘的改动会保留。 |

## 可复用的现有工具

- `AgentSandbox.currentPreviewSection()`：当 `currentPreviewDir == nil`
  时已经会自动输出"CREATE a new game"那段提示。toolbar `+` 只要
  `controller.stop()` 一下，CLAUDE.md 内容自动切换，**不需要**额外
  注入提示词。
- `MotemRailIcon`（`GodotPreviewPane.swift:424`）：直接复用做 ✏️
  图标，不要新建组件。
- SwiftTerm `LocalProcessTerminalView`：view 卸载时自动发 SIGHUP，
  `sessions = []` 即等价于"杀掉 agent"。

## 验证

依次手测：

1. **Build & 重启**：
   ```bash
   cd /Users/madongpeng/work/robot/motem-studio && \
   xcodebuild -project MotemStudio.xcodeproj -scheme MotemStudio \
     -configuration Debug -destination 'platform=macOS' \
     -derivedDataPath build CODE_SIGNING_ALLOWED=NO build
   pkill -f MotemStudio.app/Contents/MacOS
   open build/Build/Products/Debug/MotemStudio.app
   ```
2. **空闲态**：app 打开，**没有**终端面板。`pgrep -f "claude --session"`
   返回空。
3. **编辑现有**：点 sidebar 一行 → preview 加载 → ✏️ 出现在右侧 rail。
   点 ✏️ → 终端面板出现，开了一个默认 agent session。sidebar 行
   变灰（`.disabled`），toolbar `+` 变灰。
4. **Discard**：点终端右侧 "Discard editing" → 确认 → 终端面板消失，
   sidebar / `+` 重新可点。`pgrep -f "claude --session"` 回 0。
5. **Publish 出口**：再次进编辑态，让 agent 改完，点 publish。
   `PublishController.state == .success` 后终端面板**自动**消失。
6. **新建游戏**：preview 空白时点 toolbar `+` → preview 保持空白
   placeholder + 终端面板出现。在终端里 `cat ~/Library/Application\ Support/MotemStudio/sandbox/CLAUDE.md | grep -A2 "Default action"`
   应该看到 "CREATE a new game"，不是 "EDIT the currently-previewed
   game"。
7. **编辑态内多 agent**：编辑态下用 tab bar `+` 菜单加一个 codex
   session。两个并存。最后一个 chip 的关闭 X 应该是灰的，鼠标
   hover 显示禁用提示。

## 显式不做（推后）

- toolbar `+` 不带 agent picker：第一版直接用 `DefaultAgent`，
  以后可以长按弹菜单。
- 编辑态不跨 app 重启持久化：每次启动都是 `viewing`。
- 不在 viewing 态自动 release Godot 引擎：引擎单例规则不变（一旦
  boot 不能 unmount），preview pane 仍常驻。
