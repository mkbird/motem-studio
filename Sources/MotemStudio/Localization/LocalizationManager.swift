import Combine
import Foundation

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
        let raw = UserDefaults.standard.string(forKey: Self.defaultsKey)
            ?? AppLanguage.system.rawValue
        self.language = AppLanguage(rawValue: raw) ?? .system
        updateBundle()

        systemLocaleObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.language == .system else { return }
            self.updateBundle()
            self.objectWillChange.send()
        }
    }

    deinit {
        if let observer = systemLocaleObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func setLanguage(_ language: AppLanguage) {
        guard language != self.language else { return }
        self.language = language
    }

    var currentLocale: Locale {
        switch language {
        case .system:  return .current
        case .chinese: return Locale(identifier: "zh-Hans")
        case .english: return Locale(identifier: "en")
        }
    }

    private func updateBundle() {
        let code: String
        switch language {
        case .system:
            code = Bundle.main.preferredLocalizations.first {
                $0.hasPrefix("zh") || $0.hasPrefix("en")
            } ?? "en"
        case .chinese:
            code = "zh-Hans"
        case .english:
            code = "en"
        }

        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            self.bundle = bundle
        } else {
            self.bundle = .main
        }
    }
}
