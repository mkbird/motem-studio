import SwiftUI

enum L10n {
    /// Plain string lookup. Use in non-View contexts. Returns the key
    /// itself if no translation exists, matching `NSLocalizedString`.
    static func string(_ key: String, _ args: CVarArg...) -> String {
        let manager = LocalizationManager.shared
        let format = manager.bundle.localizedString(forKey: key, value: nil, table: nil)
        return args.isEmpty ? format : String(format: format, arguments: args)
    }
}

/// SwiftUI text that re-renders when the user changes language.
/// `Text(LocalizedStringKey)` only reads `Bundle.main`, so we wrap it.
struct LocalizedText: View {
    @ObservedObject private var manager = LocalizationManager.shared
    private let key: String
    private let args: [CVarArg]

    init(_ key: String, _ args: CVarArg...) {
        self.key = key
        self.args = args
    }

    var body: some View {
        Text(L10n.string(key, args))
    }
}

typealias T = LocalizedText
