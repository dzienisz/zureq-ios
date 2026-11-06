import SwiftUI

/// Toolbar capsule with the credits left this month. Tapping it explains the numbers.
struct CreditsBadge: View {
    @Environment(AppModel.self) private var app
    @State private var showDetails = false

    var body: some View {
        if let usage = app.usage, let remaining = usage.remaining {
            let state = Credits.state(of: usage)
            Button { showDetails = true } label: {
                Label {
                    Text(Credits.format(remaining))
                        .font(.caption.monospacedDigit().weight(.semibold))
                } icon: {
                    Image(systemName: state == .ok ? "circle.hexagongrid.fill" : "exclamationmark.triangle.fill")
                        .font(.caption2)
                }
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(state.tint.opacity(0.15), in: Capsule())
                .foregroundStyle(state == .ok ? Color.primary : state.tint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Credits.format(remaining)) credits left")
            .accessibilityHint("Shows credit details")
            .popover(isPresented: $showDetails, arrowEdge: .top) {
                CreditsSummary()
                    .padding()
                    .frame(idealWidth: 300)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// Remaining credits, usage bar and this session's spend. Shared by the badge popover and Settings.
struct CreditsSummary: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let usage = app.usage
        let state = usage.map(Credits.state) ?? .ok
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Credits.format(usage?.remaining))
                    .font(.title.monospacedDigit().bold())
                    .foregroundStyle(state == .ok ? Color.primary : state.tint)
                Text("credits left")
                    .foregroundStyle(.secondary)
                Spacer()
                if let plan = usage?.plan {
                    Text(plan.capitalized)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                }
            }
            if let used = usage?.used, let included = usage?.included, included > 0 {
                ProgressView(value: min(used, included), total: included)
                    .tint(state.tint)
                Group {
                    if let period = usage?.period {
                        Text("\(Credits.format(used)) of \(Credits.format(included)) used in \(period)")
                    } else {
                        Text("\(Credits.format(used)) of \(Credits.format(included)) used")
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if let message = state.message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(state.tint)
            }
            Divider()
            LabeledContent("Spent in this app session", value: Credits.format(app.sessionCredits))
                .font(.footnote)
            Text("Search 3 (1 if nothing is found) · live price 1 · checkout link 1 · usage and markets free.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { await app.refreshUsage() }
    }
}
