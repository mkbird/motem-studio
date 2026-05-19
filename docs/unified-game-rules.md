# 统一 macOS / iOS 游戏生成规则到单一 CLAUDE.md

## 背景

iPhone（后端 Claude Code SDK 子进程）和 macOS Motem Studio（本地终端 claude）现在生成同一种 Godot 4 游戏，但**喂给模型的"游戏规则文档"分散在三处**：

| 来源 | 谁看得见 | 内容 |
|---|---|---|
| `motem-backend/robot/agent/tools/game_tools.py` 内 `_GODOT_SKELETON_SYSTEM_PROMPT` | 后端 SDK 独有 | iOS runtime、screen 1194×834、UI 安全区、输入桥参考、音效 catalog、Hooks 列表、GDScript 陷阱 |
| `motem-backend/games/_template_slowpath/CLAUDE.md`（97 行）| 两端共享 | Skeleton-hook 架构、必/可选 hooks、files 修改边界、GDScript 类型推断陷阱 |
| `motem-studio/Sources/MotemStudio/Sandbox/AgentSandbox.swift` 内 `motemPromptSection`（~110 行）| Motem 独有 | "Running inside Motem Studio" 介绍、godot_preview MCP 工具、Godot 4 cheat sheet + 从零写 main.gd 的最小示例、image 输入说明 |

### 实际产生的两个问题

1. **范式冲突**：Motem 段顶部的 "Godot 4 cheat sheet" 是 from-scratch 的 `_draw()` 画矩形示例，与下半段（从 backend 拉过来的）skeleton-hook 范式直接矛盾。本地 claude 优先采纳上半段例子 → 生成的游戏不走骨架 → 发布到 iPhone 上 z_index / 字体 / 输入桥都不对。
2. **runtime 规则缺失**：1194×834、安全区、音效 ID 白名单、输入桥属性表这些 iOS 真机硬约束，Motem 端的本地 claude 完全看不到 → 即使在 macOS 预览能跑，搬到 iPhone 大概率崩。

---

## 目标

**单一权威 = `_template_slowpath/CLAUDE.md`**。后端 SDK 和 Motem 本地 claude 都消费同一份文件。每端只保留真正"宿主特异"的提示（MCP 工具、sandbox 路径），不重复也不冲突。

预期结果：

- macOS Motem 生成的游戏 → 推到 iPhone 直接可玩
- iPhone 后端生成的游戏 → macOS Motem Library 下载预览正常
- 任一端修改游戏规则 → 改一个文件，两端通过 template-bundle ETag 自动同步

---

## 文档拆分模型

```
┌────────────────────── 唯一权威：跨平台游戏规则 ────────────────────┐
│ motem-backend/games/_template_slowpath/CLAUDE.md              │
│  • Operating mode: SKELETON HOOKS                                  │
│  • Runtime environment（iOS 目标 + macOS 预览 letterbox）          │
│  • Required hooks / Optional override hooks                        │
│  • Input bridge reference（body_pose + touch 两段同时列出）        │
│  • Asset structure（background.png + z_index=-100 + Sprite2D 规则）│
│  • Files may modify / must NOT modify                              │
│  • Coding constraints（GDScript 陷阱合集）                          │
│  • Audio catalog（{audio_section} 占位符，渲染时填入）              │
│  • Workflow                                                        │
└────────────────────────────────────────────────────────────────────┘
            │                                          │
            ▼                                          ▼
┌──────── 后端 SDK 系统提示词 ────────┐    ┌─── Motem 沙箱 CLAUDE.md ───┐
│ thin opener（"You are an expert │    │ <!-- managed: motem -->     │
│   Godot 4 game developer..."）  │    │ "Running inside Motem       │
│   + input_mode 提示             │    │  Studio…"                   │
│   + MCP tools 提示              │    │ Game rules: see backend     │
│ + 文件内容（{audio_section} 已   │    │   section below             │
│   渲染）                         │    │ MCP tools: godot_preview /  │
│ + per-game CLAUDE.md（== 文件   │    │   godot_reload / ...        │
│   拷贝）作为 system_prompt 末尾   │    │ Image attachments → .pastes/ │
│   追加                          │    │ Backend template mirror →   │
│                                 │    │   .template/                │
│ → 调 Claude Code SDK 子进程     │    │ <!-- /managed: motem -->    │
│                                 │    │                             │
│                                 │    │ <!-- managed: backend-      │
│                                 │    │   template version=<etag> --> │
│                                 │    │ [文件内容（{audio_section} 已 │
│                                 │    │  渲染）]                     │
│                                 │    │ <!-- /managed: backend-     │
│                                 │    │   template -->              │
└─────────────────────────────────┘    └─────────────────────────────┘
```

---

## 实施清单

### A. 扩充 `_template_slowpath/CLAUDE.md`

把当前 `_GODOT_SKELETON_SYSTEM_PROMPT` 里**所有静态、跨平台**的内容移过来：

| 新增章节 | 内容来源 |
|---|---|
| `## Runtime environment` | iOS embedded SwiftGodotKit / Forward Mobile / **1194×834 设计分辨率** / HUD 安全区（左右 130px） / macOS 预览 letterbox 说明 |
| `## Input bridge reference` | `_SKELETON_BODY_POSE_INPUT_DOCS` + `_SKELETON_TOUCH_INPUT_DOCS` 两段合并：`get_body_target(margin)` helper + 9 个 `bridge.*` 原始属性 + touch 走 `_handle_gameplay_tap` |
| `## Asset structure` | `assets/background.png` 必填 + `z_index = -100` 陷阱 + Sprite2D vs `_draw()` 规则 |
| `## Coding constraints` | 合并：no inner classes / no keyboard input / `draw_colored_polygon` 第二参单 `Color` / `draw_rect` 无宽度参 / `_tr()` 走 i18n / `_safe_load_texture` 包装 / `AudioManager.play()` 走 catalog / `:=` 不能配 `Variant` |
| `{audio_section}` 占位符 | 渲染时填 `_build_audio_section()` 输出 |

保留当前 CLAUDE.md 里已经写好的 Architecture / Required hooks / Optional override hooks / GDScript 类型推断 gotcha / Files may modify / must NOT modify / "How to override" 重复 func 报错警告。

预计扩到 200-250 行。

### B. 后端 `_build_skeleton_system_prompt` 改成读文件 + 注入动态变量

文件：`motem-backend/robot/agent/tools/game_tools.py`

| 改动 | 目的 |
|---|---|
| 模块加载时缓存 `_SLOWPATH_CLAUDE_MD_TEMPLATE = _TEMPLATE_SLOWPATH_CLAUDE_MD.read_text()` | 避免每请求 IO |
| 新增 `_render_slowpath_claude_md()` → `template.format(audio_section=_build_audio_section())` | 单一渲染入口 |
| `_GODOT_SKELETON_SYSTEM_PROMPT` 缩成 thin opener：「You are…」+ 输入模式提示 + `{mcp_section}` + 拼接 rendered file | 唯一权威即文件本身 |
| 删 `_SKELETON_BODY_POSE_INPUT_DOCS` / `_SKELETON_TOUCH_INPUT_DOCS` 常量 | 内容现在 CLAUDE.md 里 |
| `_build_audio_section()` 保留，被 `_render_slowpath_claude_md()` 调用 | 仍按 audio manifest 动态生成 |
| Slowpath create 末尾 `copytree(_template_slowpath, game_dir)` 之后，**用 rendered 内容覆写 `game_dir/CLAUDE.md`** | per-game CLAUDE.md 不能留 `{audio_section}` literal |
| 保留 `--bare`、保留 system prompt 末尾 append per-game CLAUDE.md 的现有逻辑 | 现有行为不破坏 |

**约束**：用 OpenRouter 代理实测验证 token 消耗（按 `motem-backend/CLAUDE.md` 的 token 调试步骤），预期 ±200 token 内。

### C. Template-bundle 端点 serve 渲染后版本

文件：`motem-backend/robot/games/router.py`

| 改动 | 目的 |
|---|---|
| `_template_bundle_files()` 把 audio manifest 路径也算进去 | audio 改了 → ETag 自动翻新 |
| `_pack_template_bundle_sync()` 包 `_template_slowpath/CLAUDE.md` 时**用 `_render_slowpath_claude_md()` 渲染后的内容**作为 tar entry，而不是直接 `tar.add(file)` | Motem 拉到的 CLAUDE.md 不含未渲染占位符 |

### D. Motem `motemPromptSection` 瘦身

文件：`motem-studio/Sources/MotemStudio/Sandbox/AgentSandbox.swift`

**保留**（真·Motem 独有）：

- 介绍段："Running inside Motem Studio … sandbox-bounded shell"
- 一句话指明"游戏规则看下方 backend section"
- `## Available MCP tools` 表：`godot_preview` / `godot_reload` / `godot_stop` / `godot_status`
- `## Image and file attachments`（沙箱 `.pastes/` 说明）
- `## Backend template mirror` 指向 `.template/`
- `## Working with the user`（中英文 + workflow 简版）

**删掉**（已在后端 CLAUDE.md / 与之冲突）：

- `## Godot 4 cheat sheet`（minimal project.godot / main.tscn / main.gd from-scratch 例子）
- 「Avoid GDScript autoloads — the preview wraps your scene as a child of a host scene」这条本来就是错的（template 里 InputBridge / GameManager / I18n / AudioManager 都是 autoload，缺一不可）
- 「res:// 路径会被 ActiveDirectorySync rewrite」——macOS 宿主细节，AI 不必知道

预计瘦到 35-45 行（vs 当前 ~110 行）。

---

## 关键修改文件

| 文件 | 改动 |
|---|---|
| `motem-backend/games/_template_slowpath/CLAUDE.md` | 97 行 → ~220 行（吸收 system prompt 的静态部分；加 `{audio_section}` 占位符） |
| `motem-backend/robot/agent/tools/game_tools.py` | 缩 `_GODOT_SKELETON_SYSTEM_PROMPT` 模板；删 `_SKELETON_*_INPUT_DOCS` 两段常量；加文件读取缓存 + `_render_slowpath_claude_md()`；slowpath create 覆写 game_dir/CLAUDE.md |
| `motem-backend/robot/games/router.py` | `_template_bundle_files()` 加 audio manifest；`_pack_template_bundle_sync()` serve 渲染后的 CLAUDE.md |
| `motem-studio/Sources/MotemStudio/Sandbox/AgentSandbox.swift` | `motemPromptSection` ~110 行 → ~40 行 |
| `motem-studio/CLAUDE.md` | 注明"游戏规则唯一权威在后端" |
| `robot/CLAUDE.md` | macOS 跨平台游戏创作段补一句"游戏规则统一在后端 CLAUDE.md，Motem 客户端不重复" |

**不动**：

- `_template/` skeleton scripts（input_bridge.gd / game_manager.gd / i18n.gd / audio_manager.gd / main.gd 骨架）
- template-bundle 接口签名 / ETag 缓存机制（只动 ETag 输入 + 包内容）
- Motem `TemplateBundleSync` 拉取 + `AgentSandbox.applyBackendTemplate` 拼接逻辑（fenced marker 已存在）
- iOS 端任何代码（不消费 CLAUDE.md）
- 后端 legacy `_GODOT_SYSTEM_PROMPT_BASE`（from-scratch 模式，已非默认；保留 dead code）

---

## 关键已复用接口

| 接口 | 位置 |
|---|---|
| `_TEMPLATE_SLOWPATH_CLAUDE_MD` 常量 | `robot/games/router.py:332` |
| `_build_audio_section()` | `robot/agent/tools/game_tools.py:449` |
| `AgentSandbox.applyBackendTemplate(claudeMd:etag:)` | `Sandbox/AgentSandbox.swift:95`（fenced marker `<!-- managed: backend-template -->` 已就绪） |
| `TemplateBundleSync.shared.sync()` | `Backend/TemplateBundleSync.swift`（ETag / If-None-Match 已就绪） |
| `--bare` + `extra_args` 拼接 | `robot/agent/tools/game_tools.py`（已抑制 cwd CLAUDE.md auto-discovery） |

---

## 验证（端到端）

1. **后端单元**：`conda activate robot && pytest tests/robot/test_template_bundle.py` —— ETag 跟着文件 + audio manifest mtime 翻新；tar.gz 含新版 + 已渲染 audio section 的 CLAUDE.md
2. **后端 token 实测**：按 `motem-backend/CLAUDE.md` 的 OpenRouter 代理步骤，比对改动前后 `system[2]` token 数差异（预期 ±200 内）
3. **后端 create 游戏**：iOS 客户端发 `[game_create]`，看 SDK 真实输出仍是 skeleton-hook 范式（read main.gd → fill 3 hooks）
4. **Motem cold start**：删 `~/Library/Application Support/MotemStudio/sandbox/CLAUDE.md`，重启 app，登陆 → 触发 TemplateBundleSync → 检查新 sandbox CLAUDE.md：
   - Motem 段 ~40 行，无 cheat sheet
   - Backend 段含 "Runtime environment / 1194×834 / 安全区 / Input bridge reference / Audio catalog" 新章节，且 audio catalog 真实展开
5. **Motem 本地生成 + 跨端**：终端跟 claude 说"接苹果游戏，体感控制"，期望它：
   - **不写** `_draw()` 画矩形的整套 main.gd（旧 cheat sheet 范式）
   - **写**到 `scenes/main.gd` 的 AI ZONE 里填 `_init_game/_update_gameplay/_draw_gameplay`
   - 调 `godot_preview` → 上半窗口跑通
   - 点 "Publish to iPhone" → iPhone 拉下来玩 → 控制正常
6. **iPhone → macOS 反向**：iOS 创建游戏 → Motem Library 下载 → preview 跑通 → 键鼠映射到 `bridge.*` 正常
7. **修改规则可见性**：临时给 `_template_slowpath/CLAUDE.md` 加一条假规则（e.g.「never use Color.RED」）→ 后端 mtime 翻 ETag → Motem 下次启动拉到新版 → 沙箱 CLAUDE.md 含新规则；同时下次 iOS create 游戏，Claude SDK system prompt 也含新规则 → 双端同步证毕

---

## 不在本期范围

- **删 legacy `_GODOT_SYSTEM_PROMPT_BASE` from-scratch 路径**：保留 dead code，避免 surprise
- **完全去除 system prompt 与 per-game CLAUDE.md 的内容重复**（双倍 token）：后端目前同时注入两份；优化要换 `--bare` 行为，单独一轮 PR
- **删 Motem 端 `ActiveDirectorySync` 的 `.template/` 同步**：模板镜像仍然有用，不动
- **iOS 端 / 后端 SDK input_mode 之外的运行时元数据传递**：input_mode 仍走现有 meta.json 字段
- **screen_resolution 多设备适配**：1194×834 已是统一画布，iPad 适配 `stretch_mode` 自动 letterbox 解决

---

## 风险与回退

| 风险 | 概率 | 回退 |
|---|---|---|
| 扩充后 CLAUDE.md > 2.5K token，后端 round-trip 涨 500+ token | 中 | 拆「runtime environment」+「coding constraints」常驻段，input/audio 仍走 system prompt 注入；分文件 include |
| Motem 端旧版客户端拉到新版 CLAUDE.md，老 cheat sheet 已删，本地生成代码风格突变 | 低 | Motem 段是 hard-coded Swift 代码 → 老版客户端用老 Motem 段 + 新 backend 段，依然兼容（新段只是更详细，没破坏性变更） |
| `_pack_template_bundle_sync` 把 audio manifest 加入 ETag 输入后，没有 audio manifest 的环境（测试 / 本地）会 panic | 低 | 路径不存在时跳过加入 ETag 输入（保持 OSError try/except） |
| skeleton mode AI 仍偶尔 "rewrite main.gd from scratch"（旧训练惯性） | 中 | CLAUDE.md 顶部加更强 ⚠️ 提示；可顺手把 system prompt opener 改一句 "DO NOT rewrite main.gd; only fill hooks in the AI ZONE" |

---

## 实施顺序建议

1. **抽内容**：把 `_GODOT_SKELETON_SYSTEM_PROMPT` 的静态片段（Runtime / Input bridge / Asset structure / Coding constraints）整理到 `_template_slowpath/CLAUDE.md`，留 `{audio_section}` 占位符
2. **后端缩 system prompt + 加 `_render_slowpath_claude_md()`**：`_build_skeleton_system_prompt` 改成 thin opener + 动态 `{mcp_section}` + rendered file content
3. **后端 router 改 template-bundle 包内容**：serve 渲染后的 CLAUDE.md；ETag 输入加 audio manifest
4. **跑后端测试**：`pytest tests/robot/test_template_bundle.py` + `test_game_creation_streaming.py`
5. **Motem 瘦 `motemPromptSection`**：删 cheat sheet 段，保留 MCP / sandbox / image / template-mirror / working-with-user 段
6. **build motem-studio**：`xcodegen generate && xcodebuild Debug` → 删 sandbox CLAUDE.md → 重启 app → 看新 sandbox 内容
7. **端到端**：验证项 5-7
8. **token 实测**：验证项 2，确认未异常上涨
9. **文档**：更新 `motem-studio/CLAUDE.md` + `robot/CLAUDE.md` 关于"单一权威"的说明
