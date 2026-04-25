import SwiftUI

/// First-launch flow: collect invite code + region + language, then POST to the hub.
/// On success, persists the registration and the rest of the app switches to AlertsListView.
struct OnboardingView: View {
    @EnvironmentObject var alertsVM: AlertsViewModel
    @EnvironmentObject var chatVM: ChatViewModel

    @State private var inviteCode: String = ""
    @State private var region: String = ""
    @State private var language: String = Locale.current.language.languageCode?.identifier ?? "en"
    @State private var isSubmitting: Bool = false
    @State private var errorText: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Register with your NGO")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Enter the invite code your NGO shared with you. You'll only receive amber alerts from that organisation.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)

                Section("Invite code") {
                    TextField("e.g. NGO-ALEPPO-1234", text: $inviteCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                }

                Section("Region") {
                    TextField("e.g. Aleppo, Syria", text: $region)
                        .autocorrectionDisabled()
                }

                Section("Language") {
                    TextField("e.g. en, ar, uk", text: $language)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if let err = errorText {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                            .font(.callout)
                    }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Register")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(inviteCode.isEmpty || region.isEmpty || isSubmitting)
                }
            }
            .navigationTitle("Welcome")
        }
    }

    private func submit() async {
        isSubmitting = true
        errorText = nil
        let pubkey = chatVM.meshService.getNoiseService().getStaticPublicKeyData()
        await alertsVM.register(
            inviteCode: inviteCode.trimmingCharacters(in: .whitespaces),
            bitchatPublicKey: pubkey,
            region: region.trimmingCharacters(in: .whitespaces),
            language: language.trimmingCharacters(in: .whitespaces)
        )
        isSubmitting = false
        if !alertsVM.onboarded {
            // Pull the failure message out of submissionState if we landed there.
            if case .failed(let msg) = alertsVM.submissionState {
                errorText = msg
            } else {
                errorText = "Registration did not complete. Try again."
            }
        }
    }
}
