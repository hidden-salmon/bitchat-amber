import SwiftUI

/// Home screen after onboarding: a read-only list of inbound amber alerts.
/// Tapping an alert opens `SubmitInfoView` so the user can send a sighting.
struct AlertsListView: View {
    @EnvironmentObject var alertsVM: AlertsViewModel
    @State private var selectedAlert: AmberAlert? = nil

    var body: some View {
        NavigationStack {
            Group {
                if alertsVM.alerts.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(alertsVM.alerts) { alert in
                            Button {
                                selectedAlert = alert
                            } label: {
                                AlertRow(alert: alert)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
                }
            }
            .navigationTitle(navigationTitle)
            .sheet(item: $selectedAlert) { alert in
                SubmitInfoView(alert: alert)
                    .environmentObject(alertsVM)
            }
        }
    }

    private var navigationTitle: String {
        alertsVM.registration?.ngoName ?? "Amber Alerts"
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No active alerts")
                .font(.headline)
            Text("You'll see alerts from your NGO here. They arrive over the bitchat mesh even when you don't have internet.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AlertRow: View {
    let alert: AmberAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(alert.title)
                    .font(.headline)
                Spacer()
                ChannelBadge(via: alert.receivedVia)
            }
            Text(alert.summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(3)
            HStack(spacing: 6) {
                Text(alert.issuedAt, style: .relative)
                Text("ago")
                Text("·")
                Text(alert.caseId)
                    .monospaced()
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
    }
}

private struct ChannelBadge: View {
    let via: AmberAlert.ReceivedVia

    var body: some View {
        Text(via == .internet ? "internet" : "mesh")
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(via == .internet ? Color.blue.opacity(0.15) : Color.orange.opacity(0.15))
            .foregroundStyle(via == .internet ? Color.blue : Color.orange)
            .clipShape(Capsule())
    }
}
