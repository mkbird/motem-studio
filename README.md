# Motem Studio

A macOS GUI for Claude Code.

> **MVP scope**: an interactive shell. Wraps the user's locally-installed
> `claude` CLI via PTY. No automation, no scheduling, no token handling.
> See `plan.md` for full design notes.

## Requirements

- macOS 13+
- Xcode 15+
- Node.js + Claude Code CLI installed by the user:
  ```bash
  npm i -g @anthropic-ai/claude-code
  claude   # complete first-run OAuth
  ```

## Build

Two paths — pick one.

### Path A: XcodeGen (recommended)

```bash
brew install xcodegen
cd motem-studio
xcodegen generate
open MotemStudio.xcodeproj
# In Xcode: Run (⌘R)
```

`project.yml` declares the SwiftTerm SPM dependency and project structure.
Re-run `xcodegen generate` whenever you add/rename source files.

### Path B: Manual Xcode project

1. Xcode → File → New → Project → macOS → App
   - Product Name: `MotemStudio`
   - Interface: SwiftUI
   - Language: Swift
2. Delete the auto-generated `ContentView.swift` and `MotemStudioApp.swift`.
3. Drag `Sources/MotemStudio/` into the project (Create folder references).
4. File → Add Package Dependencies → `https://github.com/migueldeicaza/SwiftTerm` → main branch.
5. Project → Info → Localizations → add **English** and **Chinese, Simplified**.
6. Disable App Sandbox in Signing & Capabilities (we spawn subprocesses).

## Layout

```text
motem-studio/
├── plan.md                         # design doc
├── project.yml                     # XcodeGen config
├── README.md
└── Sources/MotemStudio/
    ├── App/
    │   ├── MotemStudioApp.swift    # @main entry
    │   └── ContentView.swift
    ├── Terminal/
    │   ├── ClaudeBinaryLocator.swift
    │   ├── TerminalEnvironment.swift
    │   ├── ClaudeTerminalView.swift
    │   └── TerminalHostView.swift
    ├── Localization/
    │   ├── AppLanguage.swift
    │   ├── LocalizationManager.swift
    │   ├── L10n.swift
    │   └── Localizable.xcstrings
    ├── Settings/
    │   ├── SettingsView.swift
    │   └── GeneralSettingsView.swift
    └── Resources/
        └── MotemStudio.entitlements
```

## V1 status

Currently implemented:

- [x] PTY-backed terminal (SwiftTerm)
- [x] Login-shell PATH resolution (works with nvm/volta/Homebrew)
- [x] `claude` binary detection + missing-CLI message
- [x] Custom game-creation app icon asset
- [x] Project working directory + zsh `-ilc` wrap
- [x] Language: Follow System / Chinese / English with live switching
- [x] Settings panel scaffold

Next (see `plan.md`):

- [ ] Project / workspace management (#2)
- [ ] File tree + preview (#3)
- [ ] Onboarding install guide (#4)
- [ ] Multi-tab sessions (#5)
- [ ] Diff viewer (#7)
- [ ] Drag-and-drop into terminal (#8)
