# Motem Studio: 跨平台 AI 游戏创作（macOS ↔ iPhone）

## Context

Motem Studio 是 macOS 上的 AI 游戏创作 GUI。本期目标：**用户在 Motem Studio 终端里让 claude 写出一个 Godot 4 游戏，macOS 上能用键鼠/触控板试玩；满意后一键发布，iPhone 上能用视觉+触控玩同一个游戏**。

后端（deskrobot-backend）和 iOS 端（deskrobot-ios）已经有一整套 AI 生成 → zip 分发 → 设备运行的流水线，关键资源：

- 模板：`games/_template/` + `games/_template_slowpath/CLAUDE.md`，封装 `InputBridge` / `GameManager` / `I18n` / `AudioManager` autoload
- 跨平台契约：Godot 的 `/root/InputBridge` 9 个属性（`body_lean_x/y` / `face_position` / `is_ducking` / `is_hands_up` / `hand_gesture` / `is_reaching_out` / `body_detected` / `face_detected` / `hand_position`）
- 生成 prompt：`robot/agent/tools/game_tools.py` 里的 `_build_system_prompt(input_mode, screen_resolution, use_mcp)`
- 分发：`GET /api/games/{id}/download` 返 zip + `game_ready` WebSocket 事件推 iPhone

**思路**：游戏是 Godot 4 工程，没有平台特化字段。"在哪个平台能跑"取决于谁实现 InputBridge 那 9 个属性。iOS 用 FaceDetector，macOS 用键鼠 —— 游戏代码原封不动。

## 关键决策

| 决策点 | 选择 |
|---|---|
| 生成位置 | macOS 本地终端 claude 写文件；不调后端 Fast Path、不调后端 Claude Code SDK |
| 是否加新 MCP 工具 | 不加 —— 现有 `godot_preview` / `godot_reload` 已足够；agent 用原生 Write/Edit 写文件 |
| 模板复用 | macOS 启动后通过新接口 `GET /api/games/template-bundle` 拉 tarball 到 sandbox |
| 同步触发 | macOS GUI 按钮 "Publish to iPhone"（手动），不走 agent |
| 身份 | SwiftUI Login 面板，复用 deskrobot iOS 同一套 email/密码账号体系 |
| Library | 左侧 sidebar 拉同账号游戏列表（自有的，不含 Explore） |
| 输入映射 | 隐式适配：`input_mode=touch|body_pose` 不变；macOS 把键鼠/触控板映射成 InputBridge 属性 |

## 整体架构

```
┌──────────────────────── Motem Studio (macOS) ─────────────────────────┐
│                                                                        │
│  ┌─────────────────────────┬───────────────────────────────────────┐   │
│  │   GameLibrary sidebar   │   GodotPreviewPane (上半)             │   │
│  │   GET /api/games        │   host scene + child loaded_game      │   │
│  │   click → 下载切换       │   显示 claude 本地写的或后端下来的    │   │
│  ├─────────────────────────┴─────────────────┬─────────────────────┤   │
│  │   Terminal pane (下半 — 已有)             │   "Publish" 按钮    │   │
│  │   sandbox cwd 里 claude/codex/gemini      │   → 打 zip → POST   │   │
│  │   直接写 Godot 文件                       │      /api/games     │   │
│  │   写完调 godot_preview                    │                     │   │
│  └───────────────────────────────────────────┴─────────────────────┘   │
│                                                                        │
│  ┌──────────────── MacOSInputAdapter ────────────────────┐             │
│  │  键盘/鼠标/触控板 → /root/InputBridge 9 个属性        │             │
│  │  30Hz 泵到 GodotApp，与 iOS FaceDetector 同接口       │             │
│  └────────────────────────────────────────────────────────┘            │
│                                                                        │
│  AuthManager / APIClient / TemplateBundleSync                          │
└────────────────────┬───────────────────────────────────────────────────┘
                     │  HTTPS (token-authed)
                     ▼
        ┌───────────────────────────────┐
        │       deskrobot-backend       │
        │   GET  /api/games             │
        │   GET  /api/games/{id}/dl     │
        │   POST /api/games            (NEW)
        │   GET  /api/games/           (NEW)
        │        template-bundle        │
        │   WS   game_ready ────────────┼──→ iPhone (deskrobot-ios)
        └───────────────────────────────┘
```

## 用户故事（端到端）

1. 打开 Motem Studio → Login（email/密码 = iPhone 账号）
2. Motem Studio 后台从后端拉 template bundle → 解到 sandbox（含 `_template/` + CLAUDE.md）
3. 终端跟 claude 说"做个接苹果的游戏"
4. claude 读 sandbox 里的合并版 CLAUDE.md，按模板写 `project.godot` / `scenes/main.tscn` / `scenes/main.gd` / `scripts/input_bridge.gd`（从 `.template/` 复制）等
5. claude 调一次 `godot_preview` → 上半窗口看到游戏；A/D + 鼠标试玩
6. 改一行 → claude 调 `godot_reload` → 即时刷新
7. 点 "Publish to iPhone"：打 zip → POST `/api/games`
8. 后端入库 + 推 `game_ready` 给同账号 iPhone
9. iPhone 收到 → 下载 → 在 GamesHub 列表里 → 视觉/触控玩

## 关键组件

### 新增

| 组件 | 路径 | 职责 |
|---|---|---|
| LoginView | `Sources/MotemStudio/Auth/LoginView.swift` | 邮箱/密码登录 UI；未登录态遮罩主界面 |
| AuthManager | `Sources/MotemStudio/Auth/AuthManager.swift` | token Keychain 持久化、user_id、isLoggedIn、logout |
| APIClient | `Sources/MotemStudio/Backend/APIClient.swift` | REST 客户端；Accept-Language 头；列表/下载/上传/模板 |
| TemplateBundleSync | `Sources/MotemStudio/Backend/TemplateBundleSync.swift` | 登录后从 `/api/games/template-bundle` 拉 tarball 解到 sandbox |
| GameLibrarySidebar | `Sources/MotemStudio/Library/GameLibrarySidebar.swift` | 左侧 sidebar；点击 → 触发下载切换 |
| GameLoader | `Sources/MotemStudio/Library/GameLoader.swift` | 下载 `/api/games/{id}/download` → 解到 sandbox → 走 godot_preview |
| PublishController | `Sources/MotemStudio/Backend/PublishController.swift` | "Publish" 按钮 → 打 zip → POST → 进度/结果 |
| MacOSInputAdapter | `Sources/MotemStudio/Godot/MacOSInputAdapter.swift` | NSEvent + 30Hz 泵循环；键鼠/触控板 → `/root/InputBridge` |
| TemplateBundleEndpoint | `deskrobot-backend/robot/games/router.py` (handler) | `GET /api/games/template-bundle` → tar.gz；ETag = mtime |
| GameUploadEndpoint | `deskrobot-backend/robot/games/router.py` (handler) | `POST /api/games` → 解压 + 落库 + 广播 `game_ready` |

### 修改

| 组件 | 改动 |
|---|---|
| `App/MotemStudioApp.swift` | 登录后启 `TemplateBundleSync.shared.sync()` |
| `App/ContentView.swift` | 加左侧 Sidebar（NavigationSplitView 包 VSplitView） |
| `Godot/GodotPreviewPane.swift` | 右上 "Publish to iPhone" 按钮（currentProjectDir ≠ nil 时可点） |
| `Sandbox/AgentSandbox.swift` | CLAUDE.md 分成"Motem 规则"+"Backend 模板指南"两段；sync 后重写 |
| `Terminal/TerminalEnvironment.swift` | 加 `MOTEM_USER_ID` 供 agent 引用 |
| `Godot/GodotPreviewController.swift` | 加 `loadFromBackend(gameId:)`：下载 + 解 + preview |
| `Localizable.xcstrings` | 加 `auth.*` / `library.*` / `publish.*` 双语 key |

### 不动

- 现有 4 个 MCP 工具 `godot_preview` / `godot_reload` / `godot_stop` / `godot_status`
- `ActiveDirectorySync` 路径重写逻辑
- iOS 端任何代码 — 现有 `game_ready` 推送下载流程不变
- 后端 Fast Path / Claude Code SDK 生成路径
- meta.json schema、`InputBridge` 契约、`_template/` 内的脚本

## 分辨率与缩放

iPhone 是横屏 **1194×834** 固定；macOS 预览面板尺寸随窗口变化，长宽比与 iPhone 不一致。

### 设计分辨率统一

所有 AI 游戏一律按 `1194×834` 设计（同 iOS 后端 `_build_system_prompt(screen_resolution="1194x834")`）。CLAUDE.md 模板反复强调。

### Godot 缩放策略

`_template/project.godot` 必须配置：

```
[display]
window/size/viewport_width=1194
window/size/viewport_height=834
window/stretch/mode="canvas_items"
window/stretch/aspect="keep"
```

- `stretch/mode=canvas_items`：以 1194×834 渲染，按窗口实际尺寸缩放输出
- `stretch/aspect=keep`：保持长宽比；不一致时自动黑边补齐
- iPhone 1:1 显示；macOS 同一份工程被缩放 + letterbox，游戏内部坐标计算不变

### macOS 预览面板尺寸

- `GodotPreviewPane` 默认 `idealHeight: floor(panelWidth × 834 / 1194)` 贴合设计长宽比
- 用户可自由拉伸，靠 Godot `aspect=keep` 兜底

### 输入归一化

- `face_position` / `hand_position` 已是 `Vector2(0…1, 0…1)`，跨平台直接复用
- macOS `MacOSInputAdapter` 用预览面板**实际像素**做分母归一化鼠标坐标，**不是 1194×834**
- 鼠标点击走 Godot 原生 `InputEventMouseButton` —— canvas_items stretch 模式下 Godot 自动反算到 1194×834 坐标系

## InputBridge 映射（macOS 侧契约）

`MacOSInputAdapter` 每 30Hz 把 NSEvent 状态写到 `/root/InputBridge`，与 iOS 同接口、同频率：

| InputBridge 属性 | macOS 来源 |
|---|---|
| `body_lean_x` (float -1…1) | A/D 或 ←/→（按下 ±1，松开 0） |
| `body_lean_y` (float -1…1) | W/S 或 ↑/↓ |
| `is_reaching_out` (bool) | 鼠标左键按住 |
| `is_ducking` (bool) | Shift 按住 |
| `is_hands_up` (bool) | 空格按住 |
| `body_detected` (bool) | 常量 `true` |
| `face_position` (Vector2) | 鼠标位置归一化到预览面板 |
| `face_detected` (bool) | 常量 `true` |
| `hand_gesture` (String) | 数字键 1-7 切换 `none/fist/thumbsUp/peace/ok/heart/wave` |
| `hand_position` (Vector2) | 鼠标位置（与 face_position 同源） |

触控板原生触摸事件走 Godot `InputEventScreenTouch` —— 适配器不参与。

`touch` 模式：鼠标点击当 touch（Godot `emulate_mouse_from_touch` 默认开），body_pose 模式靠键鼠映射。

## 同步协议

### Publish 流程

1. 用户点 "Publish to iPhone"
2. PublishController：
   - 读 sandbox 当前 game 目录（project.godot / meta.json / scenes/）
   - meta.json 缺失时弹 sheet 补 title_i18n + description_i18n + input_mode（默认 touch）
   - 打 zip（`/usr/bin/zip -r` 或 Compression.framework）
   - `POST /api/games` multipart：zip + meta.json；Authorization: Bearer <token>
3. 后端 GameUploadEndpoint：
   - 解压到 `games/{game_id}/`（id 用 meta 里的或 `mac_<unix_ts>_<md5>`）
   - 入 DB：owner_id、visibility=private、title_i18n
   - 广播 `game_ready` 给 owner 所有连接 → iPhone 自动 `downloadAndExtract`
4. macOS 弹 toast

### Template Bundle 流程

- macOS 登录后调 `GET /api/games/template-bundle`
- 后端返 `_template/` + `_template_slowpath/CLAUDE.md` tar.gz；headers `ETag: <mtime-hash>`
- macOS 存 ETag；下次带 `If-None-Match`；304 跳过
- 更新则解到 `<sandbox>/.template/`，CLAUDE.md 内容 append 到 sandbox 主 CLAUDE.md（fenced 标记块替换上一次）

## 模板与 CLAUDE.md 复用关系

```
deskrobot-backend/games/_template/                   ──┐
deskrobot-backend/games/_template_slowpath/CLAUDE.md ──┤
                                                        ▼
                              GET /api/games/template-bundle
                                                        │
                                                        ▼
       ~/Library/Application Support/MotemStudio/sandbox/
         ├── CLAUDE.md         ← Motem 规则 + Backend 模板指南（合并）
         ├── AGENTS.md         ← 同上
         ├── GEMINI.md         ← 同上
         ├── .template/        ← 后端 _template 镜像（claude 读 + 抄）
         │   ├── scripts/input_bridge.gd
         │   ├── scripts/game_manager.gd
         │   ├── scripts/i18n.gd
         │   ├── scripts/audio_manager.gd
         │   └── ...
         ├── scenes/           ← claude 创作时写到 sandbox 根
         ├── project.godot
         └── meta.json
```

CLAUDE.md 合并格式：

```markdown
<!-- managed: motem -->
[Motem Studio 规则段]
<!-- /managed: motem -->

<!-- managed: backend-template version=<etag> -->
[后端 slowpath CLAUDE.md 原文]
<!-- /managed: backend-template -->
```

## 验证（端到端）

1. 登录：Motem Studio 启动 → 输入 iPhone 账号 → Library 出现自有游戏
2. 模板同步：`<sandbox>/.template/` 出现 `scripts/input_bridge.gd`；CLAUDE.md 末段包含后端 CLAUDE.md
3. 本地创建：claude 写"接苹果"游戏 → 拷 `.template/scripts/input_bridge.gd` → 写 `scenes/main.gd` → meta.json `input_mode: body_pose` → 调 `godot_preview`
4. 上半窗口出现游戏，按 A/D 接果子 → InputAdapter OK
5. 修改：claude 加分数 HUD → 调 `godot_reload` → 即时刷新
6. Publish：点按钮 → toast 成功
7. iPhone 收 game_ready → 下载 → 玩；测试 iPhone 视觉控制
8. 跨设备一致：同一份 game macOS（键鼠） / iPhone（视觉）都能玩

## 不在本期范围

- 后端 Fast Path 给 macOS 用
- 后端 → macOS 主动推（macOS 端 Library 拉式）
- 协作 / Explore 公开游戏
- macOS modify 后再 publish（MVP 假设一次性流程）
- 新 `input_mode=kbm`
- macOS 创建 widget
- Trackpad 多指手势 → InputBridge

## 风险与回退

| 风险 | 概率 | 回退 |
|---|---|---|
| `POST /api/games` 接受外部 zip 安全风险 | 中 | size cap、解压前校验 manifest、沙盒解压、owner-only 鉴权 |
| claude 写出来不遵守 `_template` 契约 | 中 | CLAUDE.md 强调；Publish 前静态校验（必须有 input_bridge.gd + autoload） |
| iPhone 不识别 `mac_*` game_id 前缀 | 低 | 后端入库统一规范化 id |
| 30Hz 输入泵拖帧 | 低 | 监测；必要时 `runOnGodotThread` 批量 |
| 用户想 macOS 拉 iPhone 创建的游戏 | 中 | GET /api/games 已能拉到；GameLoader 处理 zip 落地 |
| 后端 `_template` 改字段，macOS cache 滞后 | 中 | ETag；发版前保证三方契约统一 |

## 实施顺序

1. **MacOSInputAdapter**（macOS 独立，不依赖 backend）：拿现有 sandbox 里的 hello-world 验证 A/D → body_lean_x
2. **后端**：`GET /api/games/template-bundle` + `POST /api/games`
3. **macOS**：AuthManager + APIClient + LoginView
4. **macOS**：TemplateBundleSync —— sandbox `.template/` 出现，CLAUDE.md 合并段出现
5. **macOS**：GameLibrarySidebar + GameLoader —— 能拉同账号 iPhone 上已有的游戏
6. **macOS**：PublishController + "Publish to iPhone" 按钮
7. **跨端联调**：macOS 写游戏 → publish → iPhone 收 → 玩；反向也通
8. **文档同步**：本文件 + `motem-studio/README.md` + `robot/CLAUDE.md`
