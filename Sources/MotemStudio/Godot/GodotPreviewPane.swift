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
    @ObservedObject private var publish = PublishController.shared
    @EnvironmentObject private var l10n: LocalizationManager
    @State private var showPublishSheet = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            engineLayer

            overlay
                .opacity(showEngine ? 0 : 1)
                .allowsHitTesting(!showEngine)

            publishOverlay
                .padding(12)
        }
        .frame(minHeight: 240)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { trackGeometry(proxy.frame(in: .global)) }
                    .onChange(of: proxy.frame(in: .global)) { newFrame in
                        trackGeometry(newFrame)
                    }
            }
        )
        .onAppear {
            // The adapter installs global NSEvent monitors and a 30 Hz
            // pump, so it should run for the whole app lifetime once
            // the user has a preview pane on screen.
            MacOSInputAdapter.shared.start()
            publish.beginWatching(projectDir: controller.currentProjectDir)
        }
        .onChange(of: controller.currentProjectDir) { newDir in
            publish.beginWatching(projectDir: newDir)
        }
    }

    private func trackGeometry(_ frame: CGRect) {
        MacOSInputAdapter.shared.paneWindowFrame = frame
    }

    private var showEngine: Bool {
        if case .running = controller.state { return true }
        return false
    }

    // MARK: - Engine layer (always resident)

    @ViewBuilder
    private var engineLayer: some View {
        #if canImport(SwiftGodotKit)
        if let godotApp = controller.godotApp {
            // Once mounted, this view stays for the rest of the app's
            // lifetime — re-mounting crashes the embedded display server.
            GodotAppView(source: controller.activeDirectoryPath)
                .environment(\.godotApp, godotApp)
        } else {
            // Engine not booted yet. The overlay layer renders the
            // placeholder, so all we need here is a neutral background
            // that won't trigger any permission-bearing initialisation.
            Color.black.opacity(0.92)
        }
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

    // MARK: - Publish overlay (top-right)

    @ViewBuilder
    private var publishOverlay: some View {
        HStack(spacing: 10) {
            publishStatusChip
            publishButton
        }
    }

    @ViewBuilder
    private var publishStatusChip: some View {
        switch publish.state {
        case .idle:
            EmptyView()
        case .packaging:
            statusChip(icon: "archivebox", text: L10n.string("publish.state.packaging"), tint: .secondary)
        case .uploading:
            statusChip(icon: "arrow.up.circle", text: L10n.string("publish.state.uploading"), tint: .secondary)
        case .finalizing:
            statusChip(icon: "arrow.up.circle", text: L10n.string("publish.state.finalizing"), tint: .secondary)
        case .success(_, let message):
            statusChip(icon: "checkmark.circle.fill", text: message, tint: .green)
        case .failed(let reason):
            statusChip(icon: "xmark.octagon.fill", text: reason, tint: .red)
        }
    }

    private func statusChip(icon: String, text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            if icon == "arrow.up.circle" || icon == "archivebox" {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Image(systemName: icon).foregroundStyle(tint)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(.regularMaterial)
        )
        .overlay(
            Capsule().stroke(tint.opacity(0.4), lineWidth: 1)
        )
        .frame(maxWidth: 320)
    }

    private var publishButton: some View {
        Button(action: handlePublish) {
            Label(L10n.string("publish.button"), systemImage: "paperplane.fill")
                .font(.callout.weight(.medium))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)
        .disabled(!canPublish)
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet(isPresented: $showPublishSheet)
        }
    }

    private var canPublish: Bool {
        // Gate on (a) the publish controller not being mid-upload and
        // (b) the project having content the user hasn't already
        // pushed. Re-uploading an unchanged project would just churn
        // the backend and re-notify the iPhone with the same payload.
        switch publish.state {
        case .packaging, .uploading, .finalizing:
            return false
        default:
            return publish.hasPendingChanges
        }
    }

    private func handlePublish() {
        showPublishSheet = true
    }
}
