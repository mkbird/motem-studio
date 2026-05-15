import Foundation

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:  return L10n.string("settings.language.system")
        case .chinese: return "简体中文"
        case .english: return "English"
        }
    }

    var localeCode: String? {
        switch self {
        case .system:  return nil
        case .chinese: return "zh-Hans"
        case .english: return "en"
        }
    }
}
