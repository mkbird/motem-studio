import SwiftUI

#if canImport(SwiftGodotKit)
import SwiftGodotKit
#endif

/// Top half of the main window.
///
/// CRITICAL: the embedded `GodotAppView` is always present once the app
/// launches. SwiftGodotKit's macOS path crashes the engine if the
/// `NSGodotAppView` is removed and re-added — the old scene's
/// deferred-free queue ends up dereferencing the previous embedded
/// display server (SIGSEGV in `DisplayServerEmbedded::cursor_set_shape`).
/// We keep the view structurally identical for the app's lifetime; the
/// `idle` / `failed` states overlay an opaque pane via opacity so the
/// engine layer underneath is never unmounted.
struct GodotPreviewPane: View {

    @ObservedObject private var controller = GodotPreviewController.shared
    @EnvironmentObject private var l10n: LocalizationManager

    var body: some View {
        ZStack {
            engineLayer

            overlay
                .opacity(showEngine ? 0 : 1)
                .allowsHitTesting(!showEngine)
        }
        .frame(minHeight: 240)
    }

    private var showEngine: Bool {
        if case .running = controller.state { return true }
        return false
    }

    // MARK: - Engine layer (always resident)

    @ViewBuilder
    private var engineLayer: some View {
        #if canImport(SwiftGodotKit)
        GodotAppView(source: controller.activeDirectoryPath)
            .environment(\.godotApp, controller.godotApp)
        #else
        Color.black.opacity(0.92)
        #endif
    }

    // MARK: - Overlay (placeholder + failure)

    @ViewBuilder
    private var overlay: some View {
        ZStack {
            Color.black.opacity(0.92)
            switch controller.state {
            case .idle:
                placeholder
            case .failed(let reason):
                failureView(reason)
            case .running:
                EmptyView()
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.white.opacity(0.6))
            T("preview.placeholder.title")
                .font(.title3)
                .foregroundStyle(.white)
            T("preview.placeholder.subtitle")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func failureView(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            T("preview.failed.title")
                .font(.headline)
                .foregroundStyle(.white)
            Text(reason)
                .font(.caption.monospaced())
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }
}
