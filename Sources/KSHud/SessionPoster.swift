import Combine
import Foundation

/// Posts finished sessions as JSON to an endpoint the user sets up (their own tracker, a home server, an
/// automation service), so walks don't have to be logged twice. Nothing is sent until it is configured.
///
/// Each session is sent with a stable `id`, and sent again if it changes later (a paused walk that resumes),
/// so the endpoint should treat a repeated id as an update. The payload is documented in the README.
@MainActor
final class SessionPoster: ObservableObject {
    struct Settings: Equatable {
        var enabled: Bool
        var endpoint: String
        /// Sessions that started before this day are never sent, so turning posting on doesn't replay all history.
        var since: Date
    }

    struct Status {
        let date: Date
        let ok: Bool
        let message: String
    }

    @Published private(set) var settings: Settings
    @Published private(set) var status: Status?
    /// Finished sessions not yet accepted by the endpoint.
    @Published private(set) var waiting = 0
    @Published private(set) var sending = false

    private let model: HudModel
    private let stateURL: URL
    /// Session id → fingerprint of what the endpoint last accepted.
    private var posted: [String: String]
    /// Sessions the endpoint refused (HTTP 400/422), skipped until they change or the user sends again.
    private var rejected: [String: String] = [:]
    /// After a network or server error, automatic sends wait until this time.
    private var retryAt: Date?
    private var failures = 0
    /// Set when the endpoint refuses the request itself (bad token, wrong URL); cleared by new settings or Send Now.
    private var blocked = false
    private var timer: Timer?
    private var storeChanges: AnyCancellable?

    private static let tokenAccount = "endpoint-token"

    init(model: HudModel) {
        self.model = model
        let defaults = UserDefaults.standard
        settings = Settings(
            enabled: defaults.bool(forKey: "postEnabled"),
            endpoint: defaults.string(forKey: "postEndpoint") ?? "",
            since: defaults.object(forKey: "postSince") as? Date ?? Calendar.current.startOfDay(for: Date()))
        stateURL = model.store.directory.deletingLastPathComponent().appendingPathComponent("posted.json")
        token = Keychain.read(Self.tokenAccount) ?? ""
        posted = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: stateURL))) ?? [:]

        // A session is saved when it ends, and every 30 s while it runs; the short delay lets a burst settle.
        storeChanges = model.store.$sessions
            .debounce(for: .seconds(2), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.sync() }
        // Catches sessions that become finished without a save (the belt left idle) and retries after errors.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sync() }
        }
        sync()
    }

    /// Read from the Keychain once; sent as a bearer token when not empty.
    private(set) var token: String

    static func endpointURL(_ text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host != nil
        else { return nil }
        return url
    }

    /// Returns false if the token couldn't be stored in the Keychain.
    func apply(_ new: Settings, token newToken: String) -> Bool {
        let tokenSaved = newToken == token || Keychain.write(newToken, for: Self.tokenAccount)
        if tokenSaved { token = newToken }
        if Self.endpointURL(new.endpoint) != Self.endpointURL(settings.endpoint) {
            // A different endpoint hasn't received anything yet.
            posted = [:]
            savePosted()
        }
        settings = new
        let defaults = UserDefaults.standard
        defaults.set(new.enabled, forKey: "postEnabled")
        defaults.set(new.endpoint, forKey: "postEndpoint")
        defaults.set(new.since, forKey: "postSince")
        if !new.enabled { status = nil }
        sendNow()
        return tokenSaved
    }

    /// Clears any backoff or earlier refusals and sends whatever is waiting.
    func sendNow() {
        rejected = [:]
        retryAt = nil
        failures = 0
        blocked = false
        sync()
    }

    private func sync() {
        let queue = pending()
        waiting = queue.count
        guard settings.enabled, !sending, !blocked, Date() >= retryAt ?? .distantPast,
              let url = Self.endpointURL(settings.endpoint), !queue.isEmpty else { return }
        sending = true
        Task {
            await send(queue, to: url, token: token)
            sending = false
            waiting = pending().count
        }
    }

    private func send(_ queue: [SessionRecord], to url: URL, token: String) async {
        for session in queue {
            let fingerprint = Self.fingerprint(session)
            let label = Self.label(session)
            switch await post(session, to: url, token: token) {
            case .accepted(let code):
                posted[session.id] = fingerprint
                savePosted()
                failures = 0
                status = Status(date: Date(), ok: true, message: "Sent the \(label) walk (HTTP \(code)).")
            case .refusedSession(let code, let detail):
                rejected[session.id] = fingerprint
                status = Status(date: Date(), ok: false, message: "The \(label) walk was refused (HTTP \(code))\(detail).")
            case .refusedRequest(let code, let detail):
                blocked = true
                status = Status(date: Date(), ok: false, message: "The endpoint refused the request (HTTP \(code))\(detail). Check the URL and token.")
                return
            case .failed(let reason):
                failures += 1
                let delays: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60]
                let delay = delays[min(failures, delays.count) - 1]
                retryAt = Date().addingTimeInterval(delay)
                status = Status(date: Date(), ok: false, message: "\(reason) Retrying in \(Int(delay / 60)) min.")
                return
            }
        }
    }

    private enum Outcome {
        case accepted(Int)
        case refusedSession(Int, String)
        case refusedRequest(Int, String)
        case failed(String)
    }

    private func post(_ session: SessionRecord, to url: URL, token: String) async -> Outcome {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try? Self.encoder.encode(Payload(session))
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // The body usually says what was wrong; keep the first line of it.
            let body = String(decoding: data.prefix(300), as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map { ": \($0)" } ?? ""
            switch code {
            case 200..<300: return .accepted(code)
            case 400, 422: return .refusedSession(code, body)
            case 408, 429, 500...: return .failed("The endpoint returned HTTP \(code)\(body).")
            default: return .refusedRequest(code, body)
            }
        } catch {
            return .failed("Couldn't reach the endpoint (\(error.localizedDescription)).")
        }
    }

    /// Finished sessions in the configured range that the endpoint doesn't have in their current form, oldest first.
    private func pending() -> [SessionRecord] {
        let unsettled = model.unsettledSessionID
        return model.store.sessions
            .filter { s in
                let fingerprint = Self.fingerprint(s)
                return s.start >= settings.since && s.id != unsettled
                    && posted[s.id] != fingerprint && rejected[s.id] != fingerprint
            }
            .sorted { $0.start < $1.start }
    }

    private func savePosted() {
        guard let data = try? JSONEncoder().encode(posted) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    /// What counts as a change worth resending. The end time is left out: it creeps forward while a paused
    /// session sits on the treadmill without anything else changing.
    private static func fingerprint(_ s: SessionRecord) -> String {
        "\(s.elapsedS)|\(s.distanceM)|\(s.kcal)|\(s.steps ?? -1)|\(Int(s.maxSpeedKmh * 10))|\(s.start.timeIntervalSince1970)"
    }

    private static func label(_ s: SessionRecord) -> String {
        s.start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// The JSON body for one session. Field names are part of the app's public behaviour; see the README.
    struct Payload: Encodable {
        let id: String
        let start: String
        let end: String
        let durationSec: Int
        let miles: Double
        let km: Double
        let avgMph: Double
        let maxMph: Double
        let calories: Int
        let steps: Int?
        let manual: Bool

        init(_ s: SessionRecord) {
            let iso = ISO8601DateFormatter()
            iso.timeZone = .current  // local offset, e.g. 2026-01-15T09:30:00+01:00
            func round(_ value: Double, _ places: Double) -> Double {
                let scale = pow(10, places)
                return (value * scale).rounded() / scale
            }
            let km = Double(s.distanceM) / 1000
            id = s.id
            start = iso.string(from: s.start)
            end = iso.string(from: s.end)
            durationSec = s.elapsedS
            miles = round(km / 1.609344, 3)
            self.km = round(km, 3)
            avgMph = round(s.avgSpeedKmh / 1.609344, 2)
            maxMph = round(s.maxSpeedKmh / 1.609344, 2)
            calories = s.kcal
            steps = s.steps
            manual = s.isManual
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = .sortedKeys
        return e
    }()
}
