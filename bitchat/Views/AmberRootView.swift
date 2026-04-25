import SwiftUI

/// Top-level view for the amber-alert app. Switches between onboarding and
/// the alerts list based on `AlertsViewModel.onboarded`.
///
/// The original bitchat `ContentView` is intentionally not used — this app
/// is a hub-and-spoke amber alert receiver, not a chat client.
struct AmberRootView: View {
    @EnvironmentObject var alertsVM: AlertsViewModel

    var body: some View {
        Group {
            if alertsVM.onboarded {
                AlertsListView()
            } else {
                OnboardingView()
            }
        }
    }
}
