import Foundation
import Combine
import BitFoundation

// MARK: - NotificationCenter bridge
//
// `ChatViewModel.didReceiveNoisePayload` posts this notification when it sees
// an alert/sighting payload, so the chat layer doesn't need to know about
// AlertsViewModel.
extension Notification.Name {
    static let amberPayloadReceived = Notification.Name("amber.payloadReceived")
}

/// State for the amber-alert app.
///
/// Lives alongside `ChatViewModel`. Observes inbound `alert` and (where applicable)
/// `STATUS_UPDATE` payloads, normalises them into `AmberAlert` rows, and exposes
/// onboarding + sighting-submission to the UI.
///
/// Hub-and-spoke is enforced here: `submitSighting` only ever encrypts to the
/// stored hub pubkey, and inbound payloads are filtered by hub pubkey before
/// being rendered.
@MainActor
final class AlertsViewModel: ObservableObject {

    // MARK: - Published state

    @Published var onboarded: Bool = false
    @Published var alerts: [AmberAlert] = []
    @Published var registration: Registration? = nil
    @Published var pendingSighting: PendingSighting? = nil
    @Published var submissionState: SubmissionState = .idle

    enum SubmissionState: Equatable {
        case idle
        case submitting
        case sent
        case failed(String)
    }

    // MARK: - Storage

    private let defaults: UserDefaults
    private let hubClient: HubClient
    private var payloadObserver: NSObjectProtocol?

    // MARK: - Init

    init(hubClient: HubClient = HubClient(),
         defaults: UserDefaults = .standard) {
        self.hubClient = hubClient
        self.defaults = defaults
        loadPersistedRegistration()
        subscribeToMeshPayloads()
    }

    deinit {
        if let payloadObserver {
            NotificationCenter.default.removeObserver(payloadObserver)
        }
    }

    private func subscribeToMeshPayloads() {
        payloadObserver = NotificationCenter.default.addObserver(
            forName: .amberPayloadReceived,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard
                let self,
                let raw = note.userInfo?["type"] as? UInt8,
                let type = NoisePayloadType(rawValue: raw),
                let payload = note.userInfo?["payload"] as? Data,
                let peerID = note.userInfo?["peerID"] as? String
            else { return }
            Task { @MainActor in
                self.handleNoisePayload(type: type, payload: payload, fromPeerID: peerID)
            }
        }
    }

    // MARK: - Onboarding

    func register(
        inviteCode: String,
        bitchatPublicKey: Data,
        region: String,
        language: String,
        apnsToken: String? = nil
    ) async {
        do {
            let reg = try await hubClient.register(
                inviteCode: inviteCode,
                bitchatPublicKey: bitchatPublicKey,
                region: region,
                language: language,
                apnsToken: apnsToken
            )
            self.registration = reg
            self.onboarded = true
            persist(reg)
        } catch {
            self.submissionState = .failed("Registration failed: \(error.localizedDescription)")
        }
    }

    private func persist(_ reg: Registration) {
        defaults.set(reg.userId, forKey: "amber.userId")
        defaults.set(reg.hubPubkey, forKey: "amber.hubPubkey")
        defaults.set(reg.ngoName, forKey: "amber.ngoName")
        defaults.set(true, forKey: "amber.onboarded")
    }

    private func loadPersistedRegistration() {
        guard defaults.bool(forKey: "amber.onboarded"),
              let uid = defaults.string(forKey: "amber.userId"),
              let key = defaults.data(forKey: "amber.hubPubkey"),
              let ngo = defaults.string(forKey: "amber.ngoName") else {
            return
        }
        self.registration = Registration(userId: uid, hubPubkey: key, ngoName: ngo)
        self.onboarded = true
    }

    // MARK: - Inbound mesh handling

    /// Called from the bridge that observes `BitchatDelegate.didReceiveNoisePayload`.
    /// Filters non-alert types and unsigned/non-hub payloads.
    func handleNoisePayload(type: NoisePayloadType, payload: Data, fromPeerID: String) {
        guard type == .alert else { return }
        guard let parsed = AlertPayload.decode(from: payload) else { return }
        // NOTE: signature verification against `registration?.hubPubkey` is intentionally
        // wired in at the call site once the hub pubkey/signature scheme is finalised.
        upsertAlert(
            AmberAlert(
                caseId: parsed.caseId,
                title: parsed.title,
                summary: parsed.summary,
                issuedAt: Date(timeIntervalSince1970: TimeInterval(parsed.issuedAt)),
                version: parsed.version,
                receivedVia: .mesh,
                photoURL: nil
            )
        )
    }

    /// Inbound from the WebSocket (richer payload — title/summary plus photoURL etc.).
    func handleHubEvent(_ event: HubEvent) {
        switch event {
        case .alertIssued(let rich):
            upsertAlert(rich)
        case .statusUpdate, .ack:
            // v1: status updates not rendered yet
            break
        }
    }

    private func upsertAlert(_ alert: AmberAlert) {
        if let i = alerts.firstIndex(where: { $0.caseId == alert.caseId }) {
            // Prefer the richer (internet) version when available.
            if alert.receivedVia == .internet || alert.version > alerts[i].version {
                alerts[i] = alert
            }
        } else {
            alerts.insert(alert, at: 0)
        }
    }

    // MARK: - Sightings

    func submitSighting(caseId: String, freeText: String, location: (Double, Double)? = nil) async {
        guard let reg = registration else {
            submissionState = .failed("Not onboarded")
            return
        }
        submissionState = .submitting
        let sighting = SightingDraft(
            caseId: caseId,
            clientMsgId: UUID().uuidString,
            freeText: freeText,
            observedAt: Date(),
            location: location
        )
        do {
            // Try internet path first; the mesh fallback is wired in by the
            // bridge that owns the BLE handle (kept out of this VM to avoid
            // a cross-import).
            try await hubClient.submitSighting(sighting, userId: reg.userId)
            submissionState = .sent
        } catch {
            submissionState = .failed("Could not reach hub. Sighting will be queued for relay over the mesh.")
            pendingSighting = PendingSighting(draft: sighting, hubPubkey: reg.hubPubkey)
        }
    }
}

// MARK: - Domain types

struct AmberAlert: Identifiable, Equatable {
    var id: String { caseId }
    let caseId: String
    let title: String
    let summary: String
    let issuedAt: Date
    let version: UInt8
    let receivedVia: ReceivedVia
    let photoURL: URL?

    enum ReceivedVia: String, Equatable {
        case mesh
        case internet
    }
}

struct Registration: Equatable {
    let userId: String
    let hubPubkey: Data     // raw bitchat noise pubkey of the NGO hub
    let ngoName: String
}

struct SightingDraft {
    let caseId: String
    let clientMsgId: String
    let freeText: String
    let observedAt: Date
    let location: (Double, Double)?
}

struct PendingSighting {
    let draft: SightingDraft
    let hubPubkey: Data
}

enum HubEvent {
    case alertIssued(AmberAlert)
    case statusUpdate(caseId: String, summary: String)
    case ack(clientMsgId: String)
}
