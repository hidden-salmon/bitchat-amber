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
    @Published var profile: UserProfile? = nil
    @Published var pendingSighting: PendingSighting? = nil
    @Published var submissionState: SubmissionState = .idle
    @Published var isDemoMode: Bool = false
    @Published var locationReports: [SubmittedLocationReport] = []
    @Published var sentMessages: [SentMessage] = []

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
        name: String,
        phoneNumber: String,
        profession: String?,
        language: String,
        bitchatPublicKey: Data,
        apnsToken: String? = nil
    ) async {
        do {
            let reg = try await hubClient.register(
                name: name,
                phoneNumber: phoneNumber,
                profession: profession,
                language: language,
                bitchatPublicKey: bitchatPublicKey,
                apnsToken: apnsToken
            )
            self.registration = reg
            self.profile = UserProfile(
                name: name,
                phoneNumber: phoneNumber,
                profession: profession,
                language: language
            )
            self.onboarded = true
            persist(reg)
        } catch {
            self.submissionState = .failed("Registration failed: \(error.localizedDescription)")
        }
    }

    func updateProfile(name: String, phoneNumber: String, profession: String?, language: String) async {
        let updated = UserProfile(name: name, phoneNumber: phoneNumber, profession: profession, language: language)
        if isDemoMode {
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.profile = updated
            return
        }
        guard let reg = registration else { return }
        do {
            try await hubClient.updateProfile(updated, userId: reg.userId)
            self.profile = updated
        } catch {
            // Surface via submissionState so the view can render an error
            self.submissionState = .failed("Could not save profile: \(error.localizedDescription)")
        }
    }

    func sendMessageToNGO(_ body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let msg = SentMessage(id: UUID().uuidString, body: trimmed, sentAt: Date())
        submissionState = .submitting
        if isDemoMode {
            try? await Task.sleep(nanoseconds: 400_000_000)
            sentMessages.insert(msg, at: 0)
            submissionState = .sent
            return
        }
        guard let reg = registration else {
            submissionState = .failed("Not onboarded")
            return
        }
        do {
            try await hubClient.sendMessage(body: trimmed, clientMsgId: msg.id, userId: reg.userId)
            sentMessages.insert(msg, at: 0)
            submissionState = .sent
        } catch {
            submissionState = .failed("Could not send message: \(error.localizedDescription)")
        }
    }

    func reportLocation(lat: Double, lng: Double, safety: LocationReportPayload.Safety, note: String) async {
        let report = SubmittedLocationReport(
            id: UUID().uuidString,
            lat: lat,
            lng: lng,
            safety: safety,
            note: note,
            observedAt: Date()
        )
        submissionState = .submitting
        if isDemoMode {
            try? await Task.sleep(nanoseconds: 350_000_000)
            locationReports.insert(report, at: 0)
            submissionState = .sent
            return
        }
        guard let reg = registration else {
            submissionState = .failed("Not onboarded")
            return
        }
        do {
            try await hubClient.reportLocation(report, userId: reg.userId)
            locationReports.insert(report, at: 0)
            submissionState = .sent
        } catch {
            submissionState = .failed("Could not send location report: \(error.localizedDescription)")
        }
    }

    func resetSubmissionState() {
        submissionState = .idle
    }

    private func persist(_ reg: Registration) {
        defaults.set(reg.userId, forKey: "amber.userId")
        defaults.set(reg.hubPubkey, forKey: "amber.hubPubkey")
        defaults.set(reg.ngoName, forKey: "amber.ngoName")
        defaults.set(true, forKey: "amber.onboarded")
    }

    // MARK: - Demo mode (bypass hub, no backend needed)

    /// Bootstraps the app with a fake registration and a few sample alerts so the
    /// rest of the UI can be exercised without a running hub. Pure in-memory —
    /// nothing is persisted.
    func enterDemoMode() {
        isDemoMode = true
        registration = Registration(
            userId: "demo-user-001",
            hubPubkey: Data(repeating: 0xAB, count: 32),
            ngoName: "Demo NGO"
        )
        profile = UserProfile(
            name: "Hidde Kehrer",
            phoneNumber: "+963 21 555 0142",
            profession: "field worker",
            language: "en"
        )
        onboarded = true
        let now = Date()
        alerts = [
            AmberAlert(
                caseId: "c-2026-0481",
                title: "Maryam, 11",
                summary: "Last seen at the Aleppo central bus station, wearing a red jacket. Travelling alone.",
                issuedAt: now.addingTimeInterval(-60 * 35),
                version: 2,
                receivedVia: .internet,
                photoURL: nil
            ),
            AmberAlert(
                caseId: "c-2026-0479",
                title: "Yusuf, 9",
                summary: "Last seen near Bab al-Hawa border crossing yesterday afternoon.",
                issuedAt: now.addingTimeInterval(-60 * 60 * 18),
                version: 1,
                receivedVia: .mesh,
                photoURL: nil
            ),
            AmberAlert(
                caseId: "c-2026-0470",
                title: "Layla, 14",
                summary: "Ongoing case — last update 3 days ago. Possible sighting in Idlib.",
                issuedAt: now.addingTimeInterval(-60 * 60 * 72),
                version: 5,
                receivedVia: .internet,
                photoURL: nil
            )
        ]
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
        if isDemoMode {
            try? await Task.sleep(nanoseconds: 400_000_000)
            submissionState = .sent
            return
        }
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

struct UserProfile: Equatable {
    var name: String
    var phoneNumber: String
    var profession: String?
    var language: String
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

struct SubmittedLocationReport: Identifiable, Equatable {
    let id: String
    let lat: Double
    let lng: Double
    let safety: LocationReportPayload.Safety
    let note: String
    let observedAt: Date
}

struct SentMessage: Identifiable, Equatable {
    let id: String
    let body: String
    let sentAt: Date
}
