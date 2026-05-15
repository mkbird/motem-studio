import SwiftUI

struct PreviewSettingsView: View {
    @EnvironmentObject private var l10n: LocalizationManager
    @ObservedObject private var bridge = MCPBridgeServer.shared
    @ObservedObject private var godot = GodotPreviewController.shared

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(bridge.isRunning
                         ? L10n.string("preview.settings.bridge_running")
                         : L10n.string("preview.settings.bridge_stopped"))
                        .foregroundStyle(bridge.isRunning ? .green : .secondary)
                } label: {
                    T("preview.settings.bridge_status")
                }

                LabeledContent {
                    Text(bridge.socketURL.path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    T("preview.settings.socket")
                }
            }

            Section {
                LabeledContent {
                    Text(godot.activeDirectoryPath)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } label: {
                    T("preview.settings.active_dir")
                }

                LabeledContent {
                    Text(engineStateDescription)
                        .foregroundStyle(.secondary)
                } label: {
                    T("preview.settings.engine_state")
                }
            }

            T("preview.settings.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 520)
    }

    private var engineStateDescription: String {
        switch godot.state {
        case .idle:
            return "idle"
        case .running(let dir):
            return "running — \(dir.lastPathComponent)"
        case .failed(let reason):
            return "failed — \(reason)"
        }
    }
}
