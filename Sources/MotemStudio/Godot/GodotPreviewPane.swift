import Combine
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
    @State private var screenshotState: ScreenshotState = .idle
    // Mirrors `MacFaceDetector.shared.{isActive, isReady}` via a Combine
    // subscription installed only AFTER the Godot engine reaches
    // `.running` — directly observing the singleton from view body
    // (e.g. `@ObservedObject`) triggers AVFoundation subsystem init at
    // app launch, which races with Godot Metal init and SIGABRTs the
    // engine in `Main::setup2()`.
    @State private var cameraWarmingUp: Bool = false
    @State private var cameraSubscription: AnyCancellable?

    private enum ScreenshotState: Equatable {
        case idle
        case saving
        case saved(URL)
        case failed(String)
    }

    /// iPhone landscape physical screen ratio (19.5:9, shared by every
    /// Pro Max from 12 through 16). The Motem host project also runs
    /// with `stretch_mode=canvas_items` + `aspect=expand`, so the game
    /// world is extended horizontally to fill this 19.5:9 frame
    /// without letterbox — game scripts read `screen_size.x` and lay
    /// HUD out against the actual rendered width.
    private static let iPhoneAspectRatio: CGFloat = 19.5 / 9.0

    var body: some View {
        ZStack {
            // Letterbox fill so the surrounding pane area reads as
            // "outside the device frame" — keeps the preview obviously
            // bounded even when the user drags the VSplitView into a
            // wider-than-iPhone shape.
            Color.black

            ZStack(alignment: .topTrailing) {
                engineLayer

                overlay
                    .opacity(showEngine ? 0 : 1)
                    .allowsHitTesting(!showEngine)

                if controller.paused {
                    pauseOverlay
                        .transition(.opacity)
                } else if cameraWarmingUp {
                    cameraWarmupOverlay
                        .transition(.opacity)
                }

                // Status chips along the top edge — transient feedback
                // for publish + screenshot. Sit above the right rail so
                // long messages can spill left without colliding.
                statusStrip
                    .padding(.top, 12)
                    .frame(maxWidth: .infinity, alignment: .top)

                // iPhone-style rail of plain white icons on the right
                // edge of the preview. Matches `GameRailIcon` in
                // `motem-ios/GodotGameView.swift:1641`.
                if case .running = controller.state {
                    rightRail
                        .padding(.trailing, 8)
                        .padding(.vertical, 12)
                }
            }
            .animation(.easeInOut(duration: 0.15), value: controller.paused)
            .animation(.easeInOut(duration: 0.15), value: cameraWarmingUp)
            .aspectRatio(Self.iPhoneAspectRatio, contentMode: .fit)
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
        .onChange(of: controller.state) { newState in
            installCameraWarmupObserverIfNeeded(state: newState)
        }
    }

    private func trackGeometry(_ frame: CGRect) {
        MacOSInputAdapter.shared.paneWindowFrame = frame
    }

    /// Install the `MacFaceDetector` warmup subscription the first time
    /// the engine reaches `.running`. Deferring until then avoids the
    /// app-launch ordering bug where eager `MacFaceDetector.shared`
    /// access initialises AVFoundation before Godot Metal init and
    /// SIGABRTs `Main::setup2()`.
    private func installCameraWarmupObserverIfNeeded(state: GodotPreviewController.State) {
        guard cameraSubscription == nil, case .running = state else { return }
        cameraSubscription = Publishers
            .CombineLatest(MacFaceDetector.shared.$isActive, MacFaceDetector.shared.$isReady)
            .receive(on: DispatchQueue.main)
            .sink { active, ready in
                cameraWarmingUp = active && !ready
            }
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

    // MARK: - Right-side rail (iPhone-style)

    private var rightRail: some View {
        HStack {
            Spacer()
            VStack(spacing: 10) {
                Spacer(minLength: 0)
                MotemRailIcon(
                    systemName: "camera",
                    action: takeScreenshot,
                    help: L10n.string("pane.action.screenshot"),
                    disabled: screenshotState == .saving
                )
                MotemRailIcon(
                    systemName: controller.paused ? "play.fill" : "pause.fill",
                    action: { controller.setPaused(!controller.paused) },
                    help: L10n.string(controller.paused ? "pane.action.resume" : "pane.action.pause")
                )
                MotemRailIcon(
                    systemName: "paperplane",
                    action: { showPublishSheet = true },
                    help: L10n.string("publish.button"),
                    disabled: !canPublish
                )
                Spacer(minLength: 0)
            }
        }
        .sheet(isPresented: $showPublishSheet) {
            PublishSheet(isPresented: $showPublishSheet)
        }
    }

    private var canPublish: Bool {
        switch publish.state {
        case .packaging, .uploading, .finalizing:
            return false
        default:
            return publish.hasPendingChanges
        }
    }

    @ViewBuilder
    private var statusStrip: some View {
        HStack(spacing: 8) {
            publishStatusChip
            screenshotStatusChip
        }
    }

    /// iPhone-style PAUSED panel — same layout as
    /// `CanvasHostStage1View.swift:706` (PAUSED label + Resume +
    /// Rerun buttons), restyled for macOS so the same paused state
    /// renders consistently on both surfaces.
    private var pauseOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .allowsHitTesting(false)
            VStack(spacing: 20) {
                T("pause.title")
                    .font(.system(size: 24, weight: .bold))
                    .tracking(4)
                    .foregroundStyle(.white)

                HStack(spacing: 16) {
                    Button {
                        controller.setPaused(false)
                    } label: {
                        T("pause.action.continue")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Capsule().fill(Color.white))
                    }
                    .buttonStyle(.plain)

                    Button {
                        Task { await controller.rerun() }
                    } label: {
                        T("pause.action.rerun")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Capsule().stroke(Color.white, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.92))
            )
        }
    }

    /// Briefly shown while `MacFaceDetector` is opening the camera but
    /// hasn't published a Vision frame yet. Blocks taps so the player
    /// can't dismiss the game's START screen before the camera is
    /// actually ready — guarantees gameplay always begins with live
    /// input. Usually visible for ~200-300 ms, often shorter than that
    /// because we pre-warm at game-load.
    private var cameraWarmupOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .contentShape(Rectangle())
                .onTapGesture {}  // swallow taps
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                T("preview.camera_warmup")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.85))
            )
        }
    }

    @ViewBuilder
    private var screenshotStatusChip: some View {
        switch screenshotState {
        case .idle:
            EmptyView()
        case .saving:
            statusChip(icon: "camera", text: L10n.string("screenshot.saving"), tint: .secondary)
        case .saved(let url):
            // Tap the chip → reveal the PNG in Finder.
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                statusChip(icon: "checkmark.circle.fill",
                           text: L10n.string("screenshot.saved"),
                           tint: .green)
            }
            .buttonStyle(.plain)
        case .failed(let reason):
            statusChip(icon: "xmark.octagon.fill", text: reason, tint: .red)
        }
    }

    private func takeScreenshot() {
        screenshotState = .saving
        Task { @MainActor in
            do {
                let url = try controller.screenshot()
                screenshotState = .saved(url)
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if case .saved = screenshotState { screenshotState = .idle }
            } catch {
                screenshotState = .failed(error.localizedDescription)
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if case .failed = screenshotState { screenshotState = .idle }
            }
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

}

/// iPhone-style rail icon: plain SF Symbol on the right edge of the
/// preview, no chrome. Mirrors `GameRailIcon` from
/// `motem-ios/GodotGameView.swift:1641`: 22 pt symbol, white at
/// 92 % opacity, 44×44 hit area, black shadow for legibility against
/// game content, and a brief scale pulse on press.
private struct MotemRailIcon: View {
    let systemName: String
    let action: () -> Void
    let help: String
    var disabled: Bool = false

    @State private var pressed = false

    var body: some View {
        Button {
            guard !disabled else { return }
            action()
            withAnimation(.easeOut(duration: 0.10)) { pressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.easeIn(duration: 0.18)) { pressed = false }
            }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(Color.white.opacity(disabled ? 0.35 : 0.92))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 1)
                .scaleEffect(pressed ? 1.12 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}
