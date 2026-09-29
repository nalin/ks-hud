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
    /// Speed a ramp climbs to. Stored exactly (e.g. 3.0 mph); snapped to the treadmill's 0.1 km/h grid when used.
    @Published var rampTargetKmh: Double {
        didSet { UserDefaults.standard.set(rampTargetKmh, forKey: "rampTargetKmh") }
    }
    /// When the running ramp takes its next step; nil when no ramp is running.
    @Published private(set) var nextRampStepAt: Date?

    let store = SessionStore()
    private var treadmill: Treadmill!
    private var lastCheckpoint = Date.distantPast
    private var pendingSend: DispatchWorkItem?
    private var targetSetAt = Date.distantPast
    private var startRequestedAt = Date.distantPast
    private var rampTimer: Timer?
    private var rampStartKmh = 0.0
    /// Last speed the ramp itself asked for, to tell its own changes from ones made on the treadmill.
    private var rampCommandedKmh = 0.0

    /// Shorter sessions (accidental belt starts) are not saved.
    private static let minSavedS = 30
    static let rampIntervalS: TimeInterval = 15

    init() {
        useMetric = UserDefaults.standard.object(forKey: "useMetric") as? Bool
            ?? (Locale.current.measurementSystem == .metric)
        rampTargetKmh = UserDefaults.standard.object(forKey: "rampTargetKmh") as? Double ?? 3.0 * 1.609344
        treadmill = Treadmill()
        treadmill.onLink = { [weak self] link in
            self?.link = link
            if case .connected = link { return }
            self?.live = nil
            self?.stopRamp()
            self?.checkpoint()
        }
        treadmill.onSample = { [weak self] in self?.ingest($0) }
        treadmill.onMachineEvent = { [weak self] in self?.handle($0) }
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

    var speedRange: ClosedRange<Double> { treadmill.speedRange }

    var ramping: Bool { nextRampStepAt != nil }

    /// The ramp target as the treadmill can actually run it.
    private var rampGoalKmh: Double {
        min(max((rampTargetKmh * 10).rounded() / 10, speedRange.lowerBound), speedRange.upperBound)
    }

    /// Speed the belt is at or has been told to go to.
    private var commandedKmh: Double? { targetKmh ?? live?.speedKmh }

    var canRamp: Bool { canControlSpeed && (commandedKmh ?? 0) < rampGoalKmh - 0.05 }

    /// 0–1: how far the belt's actual speed has climbed from where the ramp started to its goal.
    var rampProgress: Double {
        guard let speed = live?.speedKmh, rampGoalKmh > rampStartKmh else { return 0 }
        return min(max((speed - rampStartKmh) / (rampGoalKmh - rampStartKmh), 0), 1)
    }

    func toggleRamp() {
        if ramping {
            stopRamp()
        } else if canRamp {
            rampStartKmh = live?.speedKmh ?? 0
            rampStep()
        }
    }

    /// Raises the speed one step now and schedules the next, until the goal is reached.
    private func rampStep() {
        guard canControlSpeed, let current = commandedKmh, current < rampGoalKmh - 0.05 else {
            stopRamp()
            return
        }
        let next = min(Format(metric: useMetric).nudged(current, up: true), rampGoalKmh)
        rampCommandedKmh = next
        requestSpeed(next, coalesce: false)
        guard next < rampGoalKmh - 0.05 else {
            stopRamp()
            return
        }
        nextRampStepAt = Date().addingTimeInterval(Self.rampIntervalS)
        rampTimer?.invalidate()
        rampTimer = Timer.scheduledTimer(withTimeInterval: Self.rampIntervalS, repeats: false) { [weak self] _ in
            self?.rampStep()
        }
    }

    private func stopRamp() {
        rampTimer?.invalidate()
        rampTimer = nil
        nextRampStepAt = nil
    }

    func start() {
        guard canStart else { return }
        controlError = nil
        starting = true
        startRequestedAt = Date()
        treadmill.start()
    }

    func nudgeSpeed(up: Bool) {
        guard canControlSpeed, let current = commandedKmh else { return }
        stopRamp()  // manual adjustment takes over from a running ramp
        let next = min(max(Format(metric: useMetric).nudged(current, up: up), speedRange.lowerBound), speedRange.upperBound)
        guard next != current else { return }
        requestSpeed(next, coalesce: true)
    }

    private func requestSpeed(_ kmh: Double, coalesce: Bool) {
        targetKmh = kmh
        targetSetAt = Date()
        controlError = nil
        pendingSend?.cancel()
        guard coalesce else {
            treadmill.setTargetSpeed(kmh)
            return
        }
        // Coalesce rapid clicks into one command.
        let send = DispatchWorkItem { [weak self] in self?.treadmill.setTargetSpeed(kmh) }
        pendingSend = send
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: send)
    }

    func pause() {
        guard canControlSpeed else { return }
        stopRamp()
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

    /// Pausing or changing speed on the treadmill itself cancels a ramp, so it never fights the user.
    private func handle(_ event: Treadmill.MachineEvent) {
        switch event {
        case .haltedByUser, .controlLost:
            stopRamp()
        case .targetSpeedChanged(let kmh):
            if ramping, abs(kmh - rampCommandedKmh) > 0.05 { stopRamp() }
        }
    }

    private func ingest(_ sample: TreadmillSample) {
        let previousKmh = live?.speedKmh
        live = sample
        // Backstop for treadmills that don't send status events: during a ramp the belt only ever
        // speeds up to what the ramp asked for, so slowing down or overshooting means someone else took over.
        if ramping, let previousKmh,
           sample.speedKmh < previousKmh - 0.05 || sample.speedKmh > rampCommandedKmh + 0.05 {
            stopRamp()
        }
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
