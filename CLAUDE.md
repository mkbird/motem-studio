# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Motem Studio** —— macOS 原生 App，作为 Claude Code / OpenAI Codex / Google Gemini 三家 CLI 的 GUI 宿主。MVP 阶段定位是「更漂亮的终端壳」，验证"用户是否愿意用 GUI 跑 agentic CLI"这一个假设。**不做任何自动化、调度、批处理、并行 agent**——这是法律红线（见下方 Constraints）。

设计文档：`plan.md`（详细 V1 范围 + 实现细节）。

## Build

依赖：macOS 13+、Xcode 15+、XcodeGen（`brew install xcodegen`）。

```bash
cd /Users/madongpeng/work/robot/motem-studio
xcodegen generate          # 增删源文件后必须重跑
open MotemStudio.xcodeproj # Xcode 内 ⌘R 运行
```

CLI build（Debug，本机使用）：

```bash
xcodebuild -project MotemStudio.xcodeproj -scheme MotemStudio \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build build
```

产物：`build/Build/Products/Debug/MotemStudio.app`。直接 `open` 即可。Debug 已经用
Developer ID Application (`X4BPFGFQXD`) 签了 + Hardened Runtime；本机
跑没"未知开发者"警告，但**没带 `--timestamp`、没 notarize**，分发给
别人需要走下面的 Release 路径。

### 对外分发（Release + Notarize）

凭据已存进 keychain，profile 名 `motem-notary`。完整流程：

```bash
# 1. 构建 Release（自动带 --timestamp）
xcodebuild -project MotemStudio.xcodeproj -scheme MotemStudio \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build clean build

# 2. 打包（保留签名）
APP=build/Build/Products/Release/MotemStudio.app
ditto -c -k --keepParent "$APP" /tmp/motem.zip

# 3. 提交 notarize 并等结果
xcrun notarytool submit /tmp/motem.zip \
  --keychain-profile motem-notary --wait

# 4. staple ticket（让离线 Mac 也能验证）
xcrun stapler staple "$APP"

# 5. 检验
spctl --assess --type execute --verbose=2 "$APP"
# 应该输出：accepted, source=Notarized Developer ID
```

**注意：**
- `--timestamp` 需要 codesign 走 Xcode 里登录态去取 token；中国大陆
  网络下 Apple TSA 经常 401，需要 VPN / 干净网络才能走通。
- Release 配置在 `project.yml` 里关闭了 `CODE_SIGN_INJECT_BASE_ENTITLEMENTS`
  —— Xcode 默认会注入 `com.apple.security.get-task-allow=true`
  方便 debugger 附加，Apple 公证一律拒带这个 entitlement 的二进制。
  Debug 配置保留默认注入（可以 lldb 调）。
- 修改 entitlements 文件或 signing 配置后必须重跑 `xcodegen generate`。

## Run 前置

用户必须自己装至少一种 agent CLI，App **不打包**：

```bash
npm i -g @anthropic-ai/claude-code   # Claude Code
npm i -g @openai/codex               # Codex
npm i -g @google/gemini-cli          # Gemini
```

每家 CLI 自己处理 OAuth/API key —— App 不读、不存、不转发任何凭据。

## Architecture

```
ContentView (toolbar 三选 segmented picker)
    │
    ▼
ZStack { ForEach(spawned agents) TerminalHostView }
    │   按需 spawn，切换时 opacity 控制可见，PTY 全程保活
    ▼
TerminalHostView (NSViewRepresentable)
    │
    ▼
AgentTerminalView : LocalProcessTerminalView (SwiftTerm)
    │   组合模式：TerminalCoordinator 单独对象作 delegate
    │   （父类同名 delegate 方法非 open，子类不能再 conform）
    ▼
PTY → /bin/zsh -ilc "cd <project> && exec <agent-bin>"
```

### Core Source Files

| 文件 | 职责 |
|------|------|
| `Sources/MotemStudio/App/MotemStudioApp.swift` | `@main`，注入 `LocalizationManager` 到 WindowGroup 和 Settings scene |
| `Sources/MotemStudio/App/ContentView.swift` | 顶部 agent picker；`ZStack` 持久化多 agent 会话；`@AppStorage("DefaultAgent")` 决定首次 spawn 哪个 |
| `Sources/MotemStudio/Terminal/Agent.swift` | 枚举 `claude / codex / gemini`，带 `executableName` / `installCommand` / `brandColor` / `displayName` |
| `Sources/MotemStudio/Terminal/AgentBinaryLocator.swift` | 走 `zsh -ilc "command -v <bin>"` 解析路径（关键：-i 才加载 .zshrc，否则 nvm/fnm/npm prefix 用户全找不到） |
| `Sources/MotemStudio/Terminal/TerminalEnvironment.swift` | 给 PTY 注入的环境变量：PATH 走 login shell 解析、`TERM=xterm-256color` + `COLORTERM=truecolor` + `FORCE_COLOR=1`，按 AppLanguage 设 LANG/LC_ALL。不覆盖 Claude / Codex / Gemini 的默认 home/config，复用用户本机 CLI 已登录会话。**严禁**注入任何认证 token，让 CLI 自己走自己的认证 |
| `Sources/MotemStudio/Terminal/AgentTerminalView.swift` | SwiftTerm 子类，组合 `TerminalCoordinator` 做 delegate；找不到 binary 时 feed 红色错误 + 本地化安装提示 |
| `Sources/MotemStudio/Terminal/TerminalHostView.swift` | SwiftUI 桥；`DispatchQueue.main.async { view.start() }` 必须延后到下一帧，否则首帧 cols/rows=0 会破坏 ink TUI |
| `Sources/MotemStudio/Localization/LocalizationManager.swift` | `@Published var language`；`bundle` 跟着切；监听 `NSLocale.currentLocaleDidChangeNotification` 让 follow-system 模式响应系统改语言 |
| `Sources/MotemStudio/Localization/L10n.swift` | `L10n.string(key, args)` + `T("key")` view 包装。**所有 SwiftUI 文本必须走 `T(...)`，不能直接 `Text("...")`**——原生 `Text(LocalizedStringKey)` 只读 `Bundle.main`，不响应运行时切换 |
| `Sources/MotemStudio/Localization/AppLanguage.swift` | 枚举 `system / chinese / english` |
| `Sources/MotemStudio/Localization/Localizable.xcstrings` | String Catalog (Xcode 15+)，sourceLanguage=en，含 en + zh-Hans。新增 key 必须同时补齐两种语言 |
| `Sources/MotemStudio/Resources/Assets.xcassets/AppIcon.appiconset` | macOS AppIcon，多尺寸 PNG 由生成图标源图导出 |
| `Sources/MotemStudio/Settings/GeneralSettingsView.swift` | 账号退出登录、语言选择、默认 agent 选择 |
| `Sources/MotemStudio/Resources/MotemStudio.entitlements` | App Sandbox = false（需要 spawn 任意 binary）、`allow-unsigned-executable-memory` / `allow-jit` for hardened runtime |
| `project.yml` | XcodeGen 配置；SwiftTerm SPM 依赖；`GENERATE_INFOPLIST_FILE=NO` + 显式 `info.properties` |

## Constraints — Legal（红线，不可绕）

参考 Anthropic 法律页 `code.claude.com/docs/en/legal-and-compliance` 与 2026-02 OAuth 政策澄清。三家 CLI 都按同一套边界处理：

- **不读、不转发任何 CLI 的凭据**。`~/.claude/`、`~/.codex/`、`~/.gemini/` 全程不碰，每家 CLI 自己处理认证；Claude / Codex / Gemini 直接复用各自默认 home 下已经存在的本机登录态。
- **不打包任何 CLI 二进制**，引导用户自己 `npm i -g`。
- **不做后台/调度/批量/并行 agent**。即使技术上能做，会触发 Anthropic "non ordinary individual usage" 条款。任何"自动化"功能（一键 loop、定时任务、多 agent 并行）必须留给未来的 API key 模式，不能进 MVP。
- **不在产品名/营销文案里出现 "Claude Code" 当作产品名**。App 内描述用 "works with Claude Code" 这种 nominative fair use 即可。上线前 `sales@anthropic.com` 发邮件做商标确认。
- **保持 spawn 而非自己 implement agent 逻辑**。我们只是 PTY 宿主，性质等同 iTerm2 / Warp 内置 AI 终端，落在可辩护灰区。

## Constraints — 技术

- **macOS GUI 进程从 launchd 启动，不加载 `.zshrc`**。所以 `AgentBinaryLocator` 和 `TerminalEnvironment.resolvedPath` 必须用 `-ilc`（interactive login），不能用 `-l -c`。否则 nvm/fnm/自定义 npm prefix 的用户的 binary 全部找不到。
- **Claude / Codex / Gemini 不能覆盖默认认证目录**。否则 Motem Studio 会让 CLI 使用 sandbox 里的空配置目录，无法复用用户普通终端已经登录好的 `~/.claude` / `~/.codex` / `~/.gemini` 登录态，触发重新 OAuth。Motem 不读取这些文件，只让 CLI 自己按默认规则使用它们。
- **SwiftTerm 的 `LocalProcessTerminalView` 自己 conform 了 `LocalProcessTerminalViewDelegate` 的同名非 open 方法**。子类再 conform 会编译报错 "overriding non-open instance method outside of its defining module"。解法：**组合模式**——单独的 `TerminalCoordinator` 对象做 delegate，弱引用回主类。
- **SwiftUI `Text("key")` 不支持运行时切语言**。它只读 `Bundle.main`。所有可见文案必须走 `T("key")` / `LocalizedText`，从 `LocalizationManager.shared.bundle` 取。
- **切换 agent 不能重启 PTY**。`ContentView` 用 `ZStack` + `Set<Agent> spawned` 按需创建并保活，靠 `.opacity` + `.allowsHitTesting` 控制可见性。用 `.id(sessionID)` + `onChange` 重建会杀掉用户当前会话。
- **首帧 PTY 不能立即 start**。`makeNSView` 里 `DispatchQueue.main.async { view.start() }` 推迟到下一帧，否则 cols/rows=0 时 claude 的 ink TUI 会崩或转 fallback。
- **PTY 进程的 LANG 在 fork 时复制**。语言切换后已开会话的 LANG 不会变；hint 文案明确告诉用户"需新建会话"。

## Localization 规范

- xcstrings 已设 `sourceLanguage=en`。所有新 key 用英文做 key 名（snake/dot 都行，目前是 dot 风格如 `settings.agent.label`）。
- 新增 key 必须同时填 `en` 和 `zh-Hans`，不允许漏一边。
- View 内文案 → `T("key")`；非 View 上下文（终端 feed 错误等）→ `L10n.string("key")`。
- 不要用 SwiftUI 原生 `Text("hardcoded English")` —— 切到中文不会变。

## Known Gotchas

- **找不到 CLI 报错**：99% 是 PATH 问题。手动验证：`env -i HOME=$HOME SHELL=/bin/zsh PATH=/usr/bin:/bin zsh -ilc "command -v claude"` 应该返回路径。如果空，用户的 PATH 设置就有问题，不是 App 的 bug。
- **切语言后已开会话仍是旧语言**：PTY 是 fork 时拷贝的 env，预期行为。
- **App 关闭后 claude 进程残留**：未来要在 `applicationWillTerminate` 遍历所有 terminal view 发 SIGHUP。当前未实现，遇到再补。
- **删除源文件时**：用 `/bin/rm`，不要用 shell 的 `rm`（被 alias 成 mv-to-trash，触发沙盒）。删完必须重跑 `xcodegen generate` 同步 xcodeproj。
- **SwiftUI view body 不能直接 `@ObservedObject` `MacFaceDetector.shared`**：会在 app launch 阶段触发单例 init 实例化 `AVCaptureSession`，比 Godot embedded Metal init 还早，二者撞导致 `Main::setup2()` SIGABRT。订阅必须延后到 `controller.state == .running` 之后通过 Combine `.sink` 安装到本地 `@State`。同样的原因，`AVCaptureSession` 在 `MacFaceDetector` 内必须用 `lazy var`，不能 stored property eager 分配。
- **`AVCaptureDevice.requestAccess` 是异步的**：`MacFaceDetector.start()` 在 callback 回到 main 之前 `isActive` 仍为 false，多次 syncCamera 触发会跑多个 `bootSession()` 并发 → AVCaptureSession 抛 NSException 出 `commitConfiguration` / `startRunning` → SIGABRT。必须用 `bootInFlight` 闸门 + main-thread callback 里二次校验 `!isActive` 双重防御。
- **场景切换（rerun / 切库游戏）必须主动清 `bridge.gameplay_active`**：autoload bridge 跨场景持久，上一局 `_enter_playing` 留下的 `true` 会让 `MacFaceDetector.reconcileWithGameState` 下一拍误读 → 摄像头在新游戏 START 屏就亮起。`GodotPreviewController.preview / rerun` 在 `setPaused(false)` 之前同步走 `runOnGodotThread`（macOS 上是 sync）写 false；host.gd 的 `_swap_to_loaded` 也再清一次兜底。
- **Hardened Runtime 必须带 `com.apple.security.device.camera`（+ `audio-input`）entitlement，否则正常启动下体感全废**：App 开了 Hardened Runtime；没有这条 entitlement 时，从 Finder/Dock/`open` 正常启动的进程调用 `AVCaptureDevice.requestAccess` 会被系统**直接拒绝（`notDetermined`→`denied`）且不弹授权框** → `MacFaceDetector` 永远 `isActive=false`，所有体感游戏的摄像头跟踪静默失效（键鼠 fallback 仍能动，掩盖问题）。诡异点：从 **Xcode Run / 终端直接跑二进制**时进程继承父进程（Xcode/Terminal）的摄像头授权，体感照常工作，所以这个缺失只在「重新编译 + Dock 启动」后暴露，极易误判为代码回归。修复：`Sources/MotemStudio/Resources/MotemStudio.entitlements` 必须保留 `com.apple.security.device.camera` 和 `com.apple.security.device.audio-input` 两条；改完重跑 `xcodegen generate` 再 build，并用 `codesign -d --entitlements - <app>` 确认进了产物。诊断手法：`AVCaptureDevice.authorizationStatus` 若 `notDetermined(0)` 调一次 `requestAccess` 立刻变 `denied(2)` 且无弹窗 = 缺 entitlement（不是 TCC 缓存，`tccutil reset Camera com.motem.studio` 救不了）。注意 `log show` 抓不到本 app 的 NSLog，调试时把诊断写文件（如 `/tmp`）才能在 `open` 启动下读到。
- **摄像头开不开由「加载游戏自身的 `input_mode`」决定，不是顶部「控制方式」工具栏**：顶部 `ControlModePreference` 只表达**创作意图**（告诉本地 agent 生成哪种输入 / Publish 写进 meta），玩游戏时是否开前置摄像头是 PLAY-TIME 决策，由当前加载游戏的 `input_mode == body_pose` 决定（`ControlModePreference.syncCamera()` 读 `GodotPreviewController.currentGameInputMode`）。**坑**：下载到 `sandbox/library/<id>/meta.json` 的 `input_mode` 经常滞后于后端权威值（`ai_games.input_mode`，即 sidebar 角标同源），body-pose 游戏常被写成 `touch` 或缺失 → 直接读本地 meta 会让一部分体感游戏开不了摄像头。修复在 `GameLoader.stampInputModeFromLibrary()`：下载后、`preview()` 前，把 `GameSummary.inputMode`（列表实时值）幂等盖回本地 meta.json，使 play-time 判据与列表角标一致。新增依赖游戏类型的逻辑时一律以这个 stamped meta / 列表值为准，不要回退用工具栏 gating。仅当游戏尚未声明 `input_mode`（全新创作工程）才退回工具栏选项以保持预览可测。

## V1 进度（参考 `plan.md`）

- [x] PTY 嵌入终端（SwiftTerm）
- [x] login shell PATH 解析
- [x] 三家 agent CLI 探测 + 缺失时本地化安装提示
- [x] 游戏创作主题 AppIcon 资产
- [x] 多 agent 顶部切换 + 会话保活
- [x] 跟随系统 / 中文 / 英文 三种语言，运行时切换
- [x] 默认 agent 设置
- [x] Settings 中退出 Motem Studio 登录
- [ ] 项目（workspace）管理 + 最近项目
- [ ] 文件树 + 单文件预览
- [ ] CLI 缺失时的引导安装页（目前只在终端里 feed 提示）
- [ ] 多 Tab（同一 agent 多会话）
- [ ] Diff 查看器
- [ ] 拖拽文件/截图到终端

## V2 进度 — 跨平台 AI 游戏创作

详细设计：`docs/cross-platform-creation.md`。目标：用户在 Motem Studio 终端里
让 claude 写 Godot 4 游戏，macOS 上键鼠/触控板试玩，一键 Publish 到后端，
iPhone（motem-ios）上自动可玩 —— 复用后端已有的 `_template` + `CLAUDE.md`、
`InputBridge` 跨平台契约和 `game_ready` 分发流水线。

进度：

- [x] MacOSInputAdapter（键鼠/触控板 → `/root/InputBridge` 9 属性）
- [x] MacFaceDetector（AVFoundation + Vision → 前置摄像头 face/body 写 `/root/InputBridge`，仅 body-pose 游戏 PLAYING 时启动）
- [x] 后端 `GET /api/games/template-bundle` + `POST /api/games`
- [x] AuthManager + APIClient + LoginView
- [x] TemplateBundleSync（启动后从后端拉模板到 sandbox）
- [x] GameLibrarySidebar + GameLoader
- [x] PublishController + "Publish to iPhone" 按钮
- [x] 跨端联调（macOS → backend → iPhone 双向）
- [x] 游戏规则单一权威：`_template_slowpath/CLAUDE.md` 既是后端 SDK 系统提示词的核心内容，也通过 template-bundle 端点下发给 Motem 沙箱（详见 `docs/unified-game-rules.md`）

### 游戏规则的两段所有权

- `_template_slowpath/CLAUDE.md`（后端）= **唯一权威**。Skeleton-hook 架构、required/optional hooks、Runtime（1194×834 + 安全区）、Input bridge reference、Asset structure、Coding constraints、`{audio_section}` 动态注入的音效 catalog 全部在这里。template-bundle 端点把渲染后的内容打进 tar.gz；Motem 启动后 `TemplateBundleSync` 拉下来填到 sandbox CLAUDE.md 的 `<!-- managed: backend-template -->` 段。
- `AgentSandbox.motemPromptSection`（Motem app 内）= **macOS 宿主特有**：4 个 godot_preview MCP 工具、sandbox 边界、图片粘贴 `.pastes/`、template 镜像路径、working-with-user 简版。**不重复游戏规则**；任何与后端段冲突的提示都属于 bug。

### V2 端到端契约速查

| 概念 | 路径 / API |
|---|---|
| 设计分辨率 | 1194×834（与 iOS 一致；host `project.godot` 配 `stretch_mode=canvas_items` + `aspect=expand`，让 1194×834 世界横向扩展填满 19.5:9 预览窗格而不 letterbox）|
| 输入契约 | `/root/InputBridge` 10 属性（autoload，host 在 `_active/__motem_host__/input_bridge.gd`）。新增 `gameplay_active: bool` —— 骨架的 `_enter_playing` 写 true、`_enter_game_over` 写 false，传感器宿主（iPhone FaceDetector / macOS MacFaceDetector）轮询它来决定是否给摄像头供电 |
| macOS 键鼠映射 | `MacOSInputAdapter` 30Hz 泵：A/D=body_lean_x, W/S=body_lean_y, shift=is_ducking, 空格=is_hands_up, 鼠标=face_position |
| macOS 摄像头生命周期 | `MacFaceDetector` 250ms 轮询 `bridge.gameplay_active` —— true 且非 pause 时开 AVCaptureSession + Vision face detect，false 时立即断电；START 屏 / GAME OVER / 暂停 / touch 模式 / 无游戏加载 全部关。`bootInFlight` 闸门 + `state == .running` 守卫防止 AVFoundation 在 Godot Metal init 之前被触摸 |
| 引擎工程根 | `~/Library/Application Support/MotemStudio/_active/`（host scene 常驻；loaded_game 子目录通过 token + add_child 切换）|
| 资源路径重写 | rsync 后所有 `res://` 自动加 `loaded_game/` 前缀，`.godot/imported` 缓存随 zip 进 _active |
| 模板同步 | `GET /api/games/template-bundle`（tar.gz + ETag/If-None-Match），登录后自动；解到 `sandbox/.template/`，autoload 脚本拷到 host |
| 上传 | `POST /api/games`（multipart zip + meta；Bearer auth），id 缺失时后端用 `mac_<unix>_<md5>` |
| 推送 | `game_ready` WebSocket（owner_id 路由），iOS 端复用已有 download 流程 |

## 回复语言

中文。

## 提交代码

只有当用户明确说「commit」/「提交」/「提交代码」时才执行 `git commit`。本项目目前还不是 git 仓库，需要时由用户决定 `git init` 时机。
