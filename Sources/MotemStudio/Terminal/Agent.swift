import SwiftUI

enum Agent: String, CaseIterable, Identifiable, Codable {
    case claude
    case codex
    case gemini

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex:  return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// Name of the executable to look up on PATH.
    var executableName: String {
        switch self {
        case .claude: return "claude"
        case .codex:  return "codex"
        case .gemini: return "gemini"
        }
    }

    /// Shell command users run to install this CLI.
    var installCommand: String {
        switch self {
        case .claude: return "npm i -g @anthropic-ai/claude-code"
        case .codex:  return "npm i -g @openai/codex"
        case .gemini: return "npm i -g @google/gemini-cli"
        }
    }

    /// Vendor brand color, used for accents.
    var brandColor: Color {
        switch self {
        case .claude: return Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
        case .codex:  return Color(red: 0x10 / 255, green: 0xA3 / 255, blue: 0x7F / 255)
        case .gemini: return Color(red: 0x42 / 255, green: 0x85 / 255, blue: 0xF4 / 255)
        }
    }
}
