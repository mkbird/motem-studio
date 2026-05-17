import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Form-style publish sheet. Mirrors the iPhone app's GamePublishSheet:
/// the user picks a cover image, a title, and a visibility tier; the
/// sheet hands those to `PublishController` which writes meta.json,
/// uploads the zip, then PATCHes visibility + uploads cover.
struct PublishSheet: View {

    @Binding var isPresented: Bool

    @ObservedObject private var preview = GodotPreviewController.shared
    @ObservedObject private var publish = PublishController.shared

    @State private var title: String = ""
    @State private var coverImageURL: URL?
    @State private var coverImage: NSImage?
    @State private var visibility: PublishController.Visibility = .privateOnly
    @State private var inputMode: PublishController.InputMode = .touch
    @State private var hydrated = false

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if preview.currentProjectDir == nil {
                        noProjectNotice
                    }
                    coverSection
                    titleSection
                    visibilitySection
                    if case .failed(let reason) = publish.state {
                        failureBanner(reason)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }

            footer
        }
        .frame(width: 540, height: 620)
        .onAppear { hydrate() }
        .onChange(of: preview.currentProjectDir) { _ in hydrate(force: true) }
        .onChange(of: publish.state) { newState in
            // Successful publish auto-dismisses; the toolbar status chip
            // outside the sheet keeps the success message visible for a
            // moment so the user still gets feedback.
            if case .success = newState {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    isPresented = false
                }
            }
        }
        .onDisappear {
            // Reset terminal states so the sheet starts clean next time
            // the user opens it. An in-flight publish keeps running on
            // the controller's Task — only the surface state is reset.
            switch publish.state {
            case .success, .failed:
                publish.reset()
            default:
                break
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "paperplane.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            T("publish.sheet.title")
                .font(.headline)
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            statusBadge
            Spacer()
            Button {
                isPresented = false
            } label: {
                T("publish.action.cancel")
                    .frame(minWidth: 64)
            }
            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.bar)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch publish.state {
        case .idle:
            Button(action: trigger) {
                T("publish.action.publish")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canPublish)

        case .packaging, .uploading, .finalizing:
            Button { } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    T("publish.action.publish")
                }
                .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)

        case .success:
            Button {
                isPresented = false
            } label: {
                T("publish.sheet.done")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

        case .failed:
            Button(action: trigger) {
                T("publish.action.retry")
                    .frame(minWidth: 80)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .disabled(!canPublish)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch publish.state {
        case .idle, .failed:
            EmptyView()
        case .packaging:
            spinnerBadge(L10n.string("publish.state.packaging"))
        case .uploading:
            spinnerBadge(L10n.string("publish.state.uploading"))
        case .finalizing:
            spinnerBadge(L10n.string("publish.state.finalizing"))
        case .success(_, let message):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message)
                    .font(.caption)
                    .lineLimit(1)
            }
        }
    }

    private func spinnerBadge(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Sections

    private var noProjectNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            T("publish.sheet.noProject")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    // MARK: Cover

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            T("publish.field.cover.label")
                .font(.subheadline.weight(.semibold))
            coverTile
            HStack(spacing: 8) {
                T("publish.field.cover.placeholder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if coverImageURL != nil {
                    Button {
                        coverImageURL = nil
                        coverImage = nil
                    } label: {
                        T("publish.field.cover.action.remove")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }

    private var coverTile: some View {
        Button(action: pickCover) {
            ZStack(alignment: .bottomTrailing) {
                Color.gray.opacity(0.18)
                if let image = coverImage {
                    // `.aspectRatio(.fill) + .clipped()` keeps the image
                    // inside the 140-pt tile no matter what the source
                    // resolution is; without `.clipped()` SwiftUI lets
                    // the intrinsic size leak out and push the
                    // surrounding form down.
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    coverHoverChip
                        .padding(8)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.secondary)
                        T("publish.field.cover.action.pick")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 140)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var coverHoverChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "pencil")
            T("publish.field.cover.action.change")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    // MARK: Title

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            T("publish.field.title.label")
                .font(.subheadline.weight(.semibold))
            TextField(
                L10n.string("publish.field.title.placeholder"),
                text: $title
            )
            .textFieldStyle(.roundedBorder)
            .font(.body)
        }
    }

    // MARK: Visibility

    private var visibilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            T("publish.field.visibility.label")
                .font(.subheadline.weight(.semibold))
            VStack(spacing: 0) {
                visibilityRow(
                    .publicRemixable,
                    icon: "globe",
                    titleKey: "publish.visibility.public_remixable.title",
                    hintKey: "publish.visibility.public_remixable.hint"
                )
                Divider()
                visibilityRow(
                    .publicViewOnly,
                    icon: "eye",
                    titleKey: "publish.visibility.public_view_only.title",
                    hintKey: "publish.visibility.public_view_only.hint"
                )
                Divider()
                visibilityRow(
                    .privateOnly,
                    icon: "lock",
                    titleKey: "publish.visibility.private.title",
                    hintKey: "publish.visibility.private.hint"
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            )
        }
    }

    private func visibilityRow(
        _ option: PublishController.Visibility,
        icon: String,
        titleKey: String,
        hintKey: String
    ) -> some View {
        let selected = (visibility == option)
        return Button {
            visibility = option
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    T(titleKey)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    T(hintKey)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func failureBanner(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(reason)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(.red.opacity(0.35), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private var canPublish: Bool {
        guard preview.currentProjectDir != nil else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }

    private func pickCover() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic]
        if panel.runModal() == .OK, let url = panel.url {
            coverImageURL = url
            coverImage = NSImage(contentsOf: url)
        }
    }

    private func trigger() {
        guard let dir = preview.currentProjectDir else { return }
        let snapshotTitle = title
        let snapshotVisibility = visibility
        let snapshotCover = coverImageURL
        Task {
            await publish.publish(
                projectDir: dir,
                title: snapshotTitle,
                visibility: snapshotVisibility,
                inputMode: inputMode,
                coverImageURL: snapshotCover
            )
        }
    }

    /// Prefill the form from `meta.json` the first time the sheet is
    /// shown for a given project. When the user switches the previewed
    /// project mid-sheet we re-hydrate. We also prefer any cover image
    /// the project already ships — the AI agent may have generated one,
    /// or a previously-published game keeps its cover here.
    private func hydrate(force: Bool = false) {
        guard let dir = preview.currentProjectDir else {
            if force {
                title = ""
                visibility = .privateOnly
                coverImageURL = nil
                coverImage = nil
            }
            return
        }
        guard !hydrated || force else { return }
        hydrated = true
        title = publish.currentTitle(in: dir) ?? dir.lastPathComponent
        visibility = publish.currentVisibility(in: dir)
        if let existing = publish.existingCoverURL(in: dir) {
            coverImageURL = existing
            coverImage = NSImage(contentsOf: existing)
        } else {
            coverImageURL = nil
            coverImage = nil
        }
    }
}
