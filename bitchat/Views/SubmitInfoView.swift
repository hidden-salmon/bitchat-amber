import SwiftUI

/// Modal sheet for submitting a sighting tied to a specific alert.
/// All sightings are addressed to the NGO hub — there is no recipient picker.
struct SubmitInfoView: View {
    let alert: AmberAlert

    @EnvironmentObject var alertsVM: AlertsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var freeText: String = ""
    @State private var attachLocation: Bool = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(alert.title)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(alert.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(alert.caseId)
                        .font(.caption)
                        .monospaced()
                        .foregroundStyle(.tertiary)
                }

                Section("What did you see?") {
                    TextEditor(text: $freeText)
                        .frame(minHeight: 120)
                }

                Section {
                    Toggle("Attach my approximate location", isOn: $attachLocation)
                } footer: {
                    Text("Location is only sent if you opt in. It helps your NGO map where the person was last seen.")
                }

                Section {
                    submissionStatus
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if alertsVM.submissionState == .submitting {
                            ProgressView()
                        } else {
                            Text("Send to NGO")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || alertsVM.submissionState == .submitting)
                }
            }
            .navigationTitle("Submit info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var submissionStatus: some View {
        switch alertsVM.submissionState {
        case .idle:
            EmptyView()
        case .submitting:
            HStack { ProgressView(); Text("Sending…") }
        case .sent:
            Label("Sent. Thank you.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.callout)
        }
    }

    private func submit() async {
        // Location capture is intentionally a placeholder — wire CoreLocation in
        // once the NGO confirms whether opt-in geolocation is acceptable.
        await alertsVM.submitSighting(
            caseId: alert.caseId,
            freeText: freeText.trimmingCharacters(in: .whitespacesAndNewlines),
            location: attachLocation ? nil : nil
        )
        if alertsVM.submissionState == .sent {
            // Tiny delay so the user sees the green tick.
            try? await Task.sleep(nanoseconds: 600_000_000)
            dismiss()
        }
    }
}
