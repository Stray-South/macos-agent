import MacAgentCore
import SwiftUI

/// Content of the menu bar extra popover.
/// Shows current task, last few actions, and a Stop button.
struct MenuBarStatusView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // ── Header ──────────────────────────────────────────────────────────
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusLabel)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Spacer()
                if model.isRunning {
                    Button("Stop") { Task { await model.abort() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                }
            }

            // ── Task ─────────────────────────────────────────────────────────────
            if !model.task.isEmpty {
                Text(model.task.count > 60 ? String(model.task.prefix(60)) + "…" : model.task)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            // ── Last 3 messages ──────────────────────────────────────────────────
            let recent = model.messages.suffix(3)
            if recent.isEmpty {
                Text("No activity yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(recent.enumerated()), id: \.offset) { _, msg in
                        HStack(alignment: .top, spacing: 6) {
                            Circle()
                                .fill(msg.role == .agent ? Color.cyan : Color.orange)
                                .frame(width: 5, height: 5)
                                .padding(.top, 4)
                            Text(msg.text.count > 80 ? String(msg.text.prefix(80)) + "…" : msg.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                        }
                    }
                }
            }

            Divider()

            // ── Autonomy badge ───────────────────────────────────────────────────
            HStack(spacing: 6) {
                Text("Mode:")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(model.autonomyMode.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var statusColor: Color {
        switch model.liveActivity {
        case .idle:                return .secondary
        case .observing:           return .cyan
        case .deciding:            return .yellow
        case .executing:           return .green
        case .waitingApproval:     return .orange
        case .clarifying:          return .purple
        }
    }

    private var statusLabel: String {
        switch model.liveActivity {
        case .idle:                return "Idle"
        case .observing:           return "Observing…"
        case .deciding:            return "Thinking…"
        case .executing:           return "Executing"
        case .waitingApproval(let tier): return "Waiting — \(tier)"
        case .clarifying:          return "Clarifying"
        }
    }
}

/// The icon shown in the menu bar — a colored circle that reflects agent state.
struct MenuBarIconLabel: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(iconColor)
            if model.isRunning, let name = model.visibleApps.first(where: {
                $0.bundleID == (NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
            })?.name {
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
        }
    }

    private var iconName: String {
        model.isRunning ? "circle.fill" : "circle"
    }

    private var iconColor: Color {
        guard model.isRunning else { return .secondary }
        switch model.liveActivity {
        case .idle:                return .secondary
        case .observing:           return .cyan
        case .deciding:            return .yellow
        case .executing:           return .green
        case .waitingApproval:     return .orange
        case .clarifying:          return .purple
        }
    }
}
