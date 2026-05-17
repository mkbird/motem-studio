import SwiftUI

/// Thin strip between the Godot preview pane (top) and the terminal
/// stack (bottom). Lets the user pick how the game-being-authored is
/// meant to be controlled BEFORE talking to the local claude — the
/// pick is persisted via `ControlModePreference` and surfaced to the
/// agent through `AgentSandbox`'s CLAUDE.md so the next generated
/// game writes a matching `meta.json` + bridge / tap code shape.
struct ControlModeBar: View {

    @ObservedObject private var pref = ControlModePreference.shared

    var body: some View {
        HStack(spacing: 12) {
            T("controlMode.label")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                pill(.touch,
                     icon: "hand.tap",
                     titleKey: "controlMode.touch.title")
                pill(.bodyPose,
                     icon: "figure.wave",
                     titleKey: "controlMode.body_pose.title")
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            )

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(.bar)
    }

    private func pill(
        _ option: PublishController.InputMode,
        icon: String,
        titleKey: String
    ) -> some View {
        let selected = (pref.inputMode == option)
        return Button {
            pref.set(option)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                T(titleKey)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accentColor : Color.clear)
            )
            .foregroundStyle(selected ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
