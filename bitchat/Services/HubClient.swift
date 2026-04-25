import Foundation

// MARK: - HubClient
//
// Talks to the NGO hub over HTTP and a WebSocket stream when the device has
// internet. Mesh fallback (encrypting a SightingPayload to the hub's bitchat
// pubkey and pushing it into the mesh) is *not* this client's job — that's
// owned by the BLE/Noise layer.
//
// Default base URL is read from `Info.plist`'s `AmberHubBaseURL` key when present,
// otherwise falls back to a configurable constant. Override at construction time
// for tests / staging.

final class HubClient {

    enum HubError: LocalizedError {
        case badResponse(Int)
        case decoding(String)
        case transport(Error)

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "Hub returned HTTP \(code)"
            case .decoding(let what): return "Could not decode hub response: \(what)"
            case .transport(let e): return e.localizedDescription
            }
        }
    }

    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL? = nil, session: URLSession = .shared) {
        if let baseURL = baseURL {
            self.baseURL = baseURL
        } else if let s = Bundle.main.object(forInfoDictionaryKey: "AmberHubBaseURL") as? String,
                  let url = URL(string: s) {
            self.baseURL = url
        } else {
            // Sensible default for local dev — override in Info.plist or at construction.
            self.baseURL = URL(string: "http://localhost:8000")!
        }
        self.session = session
    }

    // MARK: - HTTP

    func register(
        inviteCode: String,
        bitchatPublicKey: Data,
        region: String,
        language: String,
        apnsToken: String?
    ) async throws -> Registration {
        struct Body: Encodable {
            let invite_code: String
            let bitchat_pubkey: String
            let apns_token: String?
            let region: String
            let language: String
        }
        struct Reply: Decodable {
            let user_id: String
            let hub_pubkey: String   // hex
            let ngo_name: String
        }
        let body = Body(
            invite_code: inviteCode,
            bitchat_pubkey: bitchatPublicKey.hexString,
            apns_token: apnsToken,
            region: region,
            language: language
        )
        let reply: Reply = try await postJSON("/v1/register", body: body, auth: nil)
        guard let hubPubkey = Data(hexString: reply.hub_pubkey) else {
            throw HubError.decoding("hub_pubkey not hex")
        }
        return Registration(
            userId: reply.user_id,
            hubPubkey: hubPubkey,
            ngoName: reply.ngo_name
        )
    }

    func submitSighting(_ s: SightingDraft, userId: String) async throws {
        struct Body: Encodable {
            let case_id: String
            let free_text: String
            let location: [Double]?
            let client_msg_id: String
            let observed_at: TimeInterval
        }
        struct Reply: Decodable {
            let sighting_id: String
            let ack: Bool
        }
        let body = Body(
            case_id: s.caseId,
            free_text: s.freeText,
            location: s.location.map { [$0.0, $0.1] },
            client_msg_id: s.clientMsgId,
            observed_at: s.observedAt.timeIntervalSince1970
        )
        let _: Reply = try await postJSON("/v1/sighting", body: body, auth: userId)
    }

    func fetchActiveAlerts(userId: String) async throws -> [AmberAlert] {
        struct Reply: Decodable {
            struct Item: Decodable {
                let case_id: String
                let title: String
                let summary: String
                let issued_at: TimeInterval
                let version: Int
                let photo_url: String?
            }
            let alerts: [Item]
        }
        let reply: Reply = try await getJSON("/v1/alerts/active", auth: userId)
        return reply.alerts.map { item in
            AmberAlert(
                caseId: item.case_id,
                title: item.title,
                summary: item.summary,
                issuedAt: Date(timeIntervalSince1970: item.issued_at),
                version: UInt8(clamping: item.version),
                receivedVia: .internet,
                photoURL: item.photo_url.flatMap { URL(string: $0) }
            )
        }
    }

    // MARK: - WebSocket stream

    /// Opens a long-running stream of hub events. Caller is responsible for
    /// re-opening on disconnect.
    func openStream(userId: String) -> AsyncThrowingStream<HubEvent, Error> {
        let url = baseURL
            .appending(path: "/v1/stream")
        var request = URLRequest(url: url)
        request.setValue("Bearer \(userId)", forHTTPHeaderField: "Authorization")
        let task = session.webSocketTask(with: request)
        task.resume()

        return AsyncThrowingStream { continuation in
            func receive() {
                task.receive { result in
                    switch result {
                    case .failure(let err):
                        continuation.finish(throwing: err)
                    case .success(let message):
                        if let event = Self.parseStreamMessage(message) {
                            continuation.yield(event)
                        }
                        receive()
                    }
                }
            }
            receive()
            continuation.onTermination = { _ in task.cancel(with: .goingAway, reason: nil) }
        }
    }

    private static func parseStreamMessage(_ msg: URLSessionWebSocketTask.Message) -> HubEvent? {
        let data: Data
        switch msg {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return nil
        }
        struct Wire: Decodable {
            let type: String
            let case_id: String?
            let title: String?
            let summary: String?
            let issued_at: TimeInterval?
            let version: Int?
            let photo_url: String?
            let client_msg_id: String?
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return nil }
        switch wire.type {
        case "ALERT_ISSUED":
            guard let cid = wire.case_id,
                  let title = wire.title,
                  let summary = wire.summary,
                  let ts = wire.issued_at,
                  let v = wire.version
            else { return nil }
            return .alertIssued(AmberAlert(
                caseId: cid,
                title: title,
                summary: summary,
                issuedAt: Date(timeIntervalSince1970: ts),
                version: UInt8(clamping: v),
                receivedVia: .internet,
                photoURL: wire.photo_url.flatMap { URL(string: $0) }
            ))
        case "STATUS_UPDATE":
            if let cid = wire.case_id, let s = wire.summary {
                return .statusUpdate(caseId: cid, summary: s)
            }
            return nil
        case "ACK":
            if let cmid = wire.client_msg_id { return .ack(clientMsgId: cmid) }
            return nil
        default:
            return nil
        }
    }

    // MARK: - HTTP helpers

    private func postJSON<B: Encodable, R: Decodable>(_ path: String, body: B, auth: String?) async throws -> R {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONEncoder().encode(body)
        return try await sendDecoding(req)
    }

    private func getJSON<R: Decodable>(_ path: String, auth: String?) async throws -> R {
        var req = URLRequest(url: baseURL.appending(path: path))
        req.httpMethod = "GET"
        if let auth = auth { req.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization") }
        return try await sendDecoding(req)
    }

    private func sendDecoding<R: Decodable>(_ req: URLRequest) async throws -> R {
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw HubError.badResponse((resp as? HTTPURLResponse)?.statusCode ?? -1)
            }
            do {
                return try JSONDecoder().decode(R.self, from: data)
            } catch {
                throw HubError.decoding(String(describing: error))
            }
        } catch let e as HubError {
            throw e
        } catch {
            throw HubError.transport(error)
        }
    }
}

// MARK: - Hex helpers

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let cleaned = hexString.lowercased().filter { "0123456789abcdef".contains($0) }
        guard cleaned.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(cleaned.count / 2)
        var idx = cleaned.startIndex
        while idx < cleaned.endIndex {
            let next = cleaned.index(idx, offsetBy: 2)
            guard let b = UInt8(cleaned[idx..<next], radix: 16) else { return nil }
            bytes.append(b)
            idx = next
        }
        self.init(bytes)
    }
}

private extension URL {
    func appending(path: String) -> URL {
        if #available(iOS 16.0, macOS 13.0, *) {
            return self.appending(path: path.hasPrefix("/") ? String(path.dropFirst()) : path)
        } else {
            return self.appendingPathComponent(path.hasPrefix("/") ? String(path.dropFirst()) : path)
        }
    }
}
