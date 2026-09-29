import Foundation

/// Turns the treadmill's per-second samples into sessions and today's totals.
final class HudModel: ObservableObject {
    @Published private(set) var link: Treadmill.Link = .searching
    @Published private(set) var live: TreadmillSample?
    @Published private(set) var session: SessionRecord?
    @Published private(set) var today = Totals()
    /// Speed the user asked for, shown until the belt reaches it.
    @Published private(set) var targetKmh: Double?
    @Published private(set) var controlError: String?
    /// Start was sent and the belt hasn't begun moving yet (KingSmith counts down first).
    @Published private(set) var starting = false
    @Published var useMetric: Bool {
        didSet { UserDefaults.standard.set(useMetric, forKey: "useMetric") }
    }

    let store = SessionStore()
    private var treadmill: Treadmill!
    private var lastCheckpoint = Date.distantPast
    private var pendingSend: DispatchWorkItem?
    private var targetSetAt = Date.distantPast
    private var startRequestedAt = Date.distantPast

    /// Shorter sessions (accidental belt starts) are not saved.
    private static let minSavedS = 30

    init() {
        useMetric = UserDefaults.standard.object(forKey: "useMetric") as? Bool
            ?? (Locale.current.measurementSystem == .metric)
        treadmill = Treadmill()
        treadmill.onLink = { [weak self] link in
            self?.link = link
            if case .connected = link { return }
            self?.live = nil
            self?.checkpoint()
        }
        treadmill.onSample = { [weak self] in self?.ingest($0) }
        treadmill.onControlResult = { [weak self] error in
            self?.controlError = error
            if error != nil {
                self?.targetKmh = nil
                self?.starting = false
            }
        }
        refreshToday()
    }

    var beltMoving: Bool { (live?.speedKmh ?? 0) > 0 }

    private var canSendCommands: Bool {
        if case .connected = link, treadmill.canControl { return true }
        return false
    }

    /// Speed changes are only allowed while the belt is moving, so only the play button can start it.
    var canControlSpeed: Bool { canSendCommands && beltMoving }

    var canStart: Bool { canSendCommands && live != nil && !beltMoving && !starting }

    func start() {
        guard canStart else { return }
        controlError = nil
        starting = true
        startRequestedAt = Date()
        treadmill.start()
    }

    func nudgeSpeed(up: Bool) {
        guard canControlSpeed, let current = targetKmh ?? live?.speedKmh else { return }
        let range = treadmill.speedRange
        let next = min(max(Format(metric: useMetric).nudged(current, up: up), range.lowerBound), range.upperBound)
        guard next != current else { return }
        targetKmh = next
        targetSetAt = Date()
        controlError = nil
        // Coalesce rapid clicks into one command.
        pendingSend?.cancel()
        let send = DispatchWorkItem { [weak self] in self?.treadmill.setTargetSpeed(next) }
        pendingSend = send
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: send)
    }

    func pause() {
        guard canControlSpeed else { return }
        pendingSend?.cancel()
        targetKmh = nil
        controlError = nil
        treadmill.pause()
    }

    func checkpoint() {
        guard let s = session, s.elapsedS >= Self.minSavedS else { return }
        store.save(s)
        lastCheckpoint = Date()
    }

    private func ingest(_ sample: TreadmillSample) {
        live = sample
        let now = Date()
        if let target = targetKmh,
           abs(sample.speedKmh - target) < 0.05 || sample.speedKmh == 0 || now.timeIntervalSince(targetSetAt) > 15 {
            targetKmh = nil
        }
        if starting, sample.speedKmh > 0 || now.timeIntervalSince(startRequestedAt) > 8 {
            starting = false
        }

        if var s = session, sample.elapsedS > 0, sample.elapsedS >= s.elapsedS {
            update(&s, with: sample, at: now)
            session = s
        } else if sample.elapsedS > 0 {
            // Counters went backwards (or we just connected): the treadmill is on a different session.
            checkpoint()
            session = resumedSession(for: sample, at: now) ?? newSession(for: sample, at: now)
        } else if session != nil {
            checkpoint()
            session = nil
        }

        if now.timeIntervalSince(lastCheckpoint) >= 30 { checkpoint() }
        refreshToday()
    }

    private func update(_ s: inout SessionRecord, with sample: TreadmillSample, at now: Date) {
        s.end = now
        s.elapsedS = sample.elapsedS
        s.distanceM = sample.distanceM
        s.kcal = sample.kcal
        s.steps = sample.steps
        s.maxSpeedKmh = max(s.maxSpeedKmh, sample.speedKmh)
        if Double(sample.elapsedS) - (s.trace.last?[0] ?? -10) >= 10 {
            s.trace.append([Double(sample.elapsedS), sample.speedKmh, Double(sample.distanceM)])
        }
    }

    private func newSession(for sample: TreadmillSample, at now: Date) -> SessionRecord {
        let start = now.addingTimeInterval(-Double(sample.elapsedS))
        let id = start.formatted(.iso8601.year().month().day().dateSeparator(.dash)
            .time(includingFractionalSeconds: false).timeSeparator(.omitted))
        var s = SessionRecord(id: id, start: start, end: now, elapsedS: 0, distanceM: 0, kcal: 0,
                              steps: nil, maxSpeedKmh: 0, trace: [])
        update(&s, with: sample, at: now)
        return s
    }

    /// After an app restart or dropped link, pick up the saved session the treadmill is still counting.
    private func resumedSession(for sample: TreadmillSample, at now: Date) -> SessionRecord? {
        guard var s = store.sessions.last,
              now.timeIntervalSince(s.end) < 600,
              s.elapsedS <= sample.elapsedS, s.distanceM <= sample.distanceM else { return nil }
        update(&s, with: sample, at: now)
        return s
    }

    private func refreshToday() {
        var t = store.totals(on: Date(), excluding: session?.id)
        if let s = session { t.add(s) }
        today = t
    }
}
