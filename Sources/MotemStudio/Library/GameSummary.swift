import Foundation

/// A row in `/api/games/mine`. Only fields the sidebar and loader
/// need are decoded; the backend returns several more (like_count,
/// share_count, view_type, etc.) that we ignore on macOS.
struct GameSummary: Codable, Identifiable, Equatable, Hashable {
    let gameId: String
    let title: String
    let titleI18n: [String: String]?
    let description: String?
    let icon: String?
    let inputMode: String?
    let kind: String?
    let coverURL: String?

    var id: String { gameId }

    enum CodingKeys: String, CodingKey {
        case gameId = "game_id"
        case title
        case titleI18n = "title_i18n"
        case description
        case icon
        case inputMode = "input_mode"
        case kind
        case coverURL = "cover_url"
    }

    /// `title` localised to the current device language (en or zh-Hans).
    /// Falls back to the raw `title` field when no localisation is
    /// available — matches how iOS picks the display string.
    var displayTitle: String {
        let lang = Locale.current.language.languageCode?.identifier ?? "en"
        let key = lang.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
        if let map = titleI18n, let value = map[key] ?? map["en"], !value.isEmpty {
            return value
        }
        return title
    }
}

/// Top-level response shape for `GET /api/games/mine`.
struct GameListResponse: Codable {
    let games: [GameSummary]
}
