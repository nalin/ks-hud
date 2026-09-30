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
    /// What the current session is working toward.
    enum SessionGoal: Equatable {
        case distance(meters: Double)
        case time(seconds: Int)

        /// The goal's size, in the same units as `amount(in:)`.
        var total: Double {
            switch self {
            case .distance(let meters): meters
            case .time(let seconds): Double(seconds)
            }
        }

        /// How much of the goal a session has covered: metres walked or seconds on the treadmill's timer.
        func amount(in session: SessionRecord?) -> Double {
            switch self {
            case .distance: Double(session?.distanceM ?? 0)
            case .time: Double(session?.elapsedS ?? 0)
            }
        }
    }

    /// Goal for the current session; nil for none.
    @Published var goal: SessionGoal? {
        didSet {
            let defaults = UserDefaults.standard
            switch goal {
            case .distance(let meters):
                defaults.set("distance", forKey: "goalKind")
                defaults.set(meters, forKey: "goalValue")
            case .time(let seconds):
                defaults.set("time", forKey: "goalKind")
                defaults.set(Double(seconds), forKey: "goalValue")
            case nil:
                defaults.set("none", forKey: "goalKind")
            }
        }
    }
    /// Speed the automatic cool-down after a distance goal slows to; nil turns cool-down off.
    @Published var coolDownTargetKmh: Double? {
        didSet { UserDefaults.standard.set(coolDownTargetKmh ?? 0, forKey: "coolDownTargetKmh") }
    }

    /// A timed series of speed steps: up to the ramp target, or down to the cool-down speed.
    enum SpeedProgram {
        case ramp
        case coolDown

        var up: Bool { self == .ramp }
        /// Speed steps per tick: ramp climbs 0.1 mph (0.2 km/h); cool-down drops twice that.
        var stepsPerTick: Int { self == .ramp ? 1 : 2 }
    }

    @Published private(set) var program: SpeedProgram?
    /// When the running program takes its next step.
    @Published private(set) var nextProgramStepAt: Date?

    let store = SessionStore()
    private var treadmill: Treadmill!
    private var lastCheckpoint = Date.distantPast
    private var pendingSend: DispatchWorkItem?
    private var targetSetAt = Date.distantPast
    private var startRequestedAt = Date.distantPast
    private var programTimer: Timer?
    private var programStartKmh = 0.0
    /// Last speed the program itself asked for, to tell its own changes from ones made on the treadmill.
    private var programCommandedKmh = 0.0
    /// Session whose distance goal has already triggered a cool-down, so it only happens once.
    private var coolDownSessionID: String?

    /// Shorter sessions (accidental belt starts) are not saved.
    private static let minSavedS = 30
    static let programIntervalS: TimeInterval = 15

    init() {
        useMetric = UserDefaults.standard.object(forKey: "useMetric") as? Bool
            ?? (Locale.current.measurementSystem == .metric)
        rampTargetKmh = UserDefaults.standard.object(forKey: "rampTargetKmh") as? Double ?? 3.0 * 1.609344
        goal = Self.savedGoal()
        let savedCoolDown = UserDefaults.standard.object(forKey: "coolDownTargetKmh") as? Double
        coolDownTargetKmh = savedCoolDown.map { $0 > 0 ? $0 : nil } ?? 2.0 * 1.609344
        treadmill = Treadmill()
        treadmill.onLink = { [weak self] link in
            self?.link = link
            if case .connected = link { return }
            self?.live = nil
            self?.stopProgram()
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

    private static func savedGoal() -> SessionGoal? {
        let defaults = UserDefaults.standard
        let value = defaults.double(forKey: "goalValue")
        switch defaults.string(forKey: "goalKind") {
        case "distance": return .distance(meters: value)
        case "time": return .time(seconds: Int(value))
        case "none": return nil
        default:
            // Before time goals existed only a distance goal was stored.
            return (defaults.object(forKey: "distanceGoalM") as? Double).map { .distance(meters: $0) }
        }
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

    /// A speed as the treadmill can actually run it.
    private func onGrid(_ kmh: Double) -> Double {
        min(max((kmh * 10).rounded() / 10, speedRange.lowerBound), speedRange.upperBound)
    }

    private func goalKmh(for program: SpeedProgram) -> Double? {
        switch program {
        case .ramp: onGrid(rampTargetKmh)
        case .coolDown: coolDownTargetKmh.map(onGrid)
        }
    }

    /// Speed the belt is at or has been told to go to.
    private var commandedKmh: Double? { targetKmh ?? live?.speedKmh }

    /// Whether the program would change the speed at all from where the belt is (or is headed).
    private func hasRoom(_ program: SpeedProgram) -> Bool {
        guard canControlSpeed, let current = commandedKmh, let goal = goalKmh(for: program) else { return false }
        return program.up ? current < goal - 0.05 : current > goal + 0.05
    }

    var canRamp: Bool { hasRoom(.ramp) }

    /// 0–1: how far the belt's actual speed has moved from where the program started toward its goal.
    var programProgress: Double {
        guard let program, let speed = live?.speedKmh, let goal = goalKmh(for: program),
              abs(goal - programStartKmh) > 0.01 else { return 0 }
        return min(max((speed - programStartKmh) / (goal - programStartKmh), 0), 1)
    }

    func toggleRamp() {
        if program == .ramp {
            stopProgram()
        } else if canRamp {
            startProgram(.ramp)
        }
    }

    func cancelProgram() {
        stopProgram()
    }

    private func startProgram(_ program: SpeedProgram) {
        stopProgram()
        guard hasRoom(program) else { return }
        self.program = program
        programStartKmh = live?.speedKmh ?? 0
        programStep()
    }

    /// Moves the speed one step now and schedules the next, until the goal is reached.
    private func programStep() {
        guard let program, hasRoom(program), let current = commandedKmh, let goal = goalKmh(for: program) else {
            stopProgram()
            return
        }
        let stepped = Format(metric: useMetric).nudged(current, up: program.up, steps: program.stepsPerTick)
        let next = program.up ? min(stepped, goal) : max(stepped, goal)
        programCommandedKmh = next
        requestSpeed(next, coalesce: false)
        guard abs(next - goal) > 0.05 else {
            stopProgram()
            return
        }
        nextProgramStepAt = Date().addingTimeInterval(Self.programIntervalS)
        programTimer?.invalidate()
        programTimer = Timer.scheduledTimer(withTimeInterval: Self.programIntervalS, repeats: false) { [weak self] _ in
            self?.programStep()
        }
    }

    private func stopProgram() {
        programTimer?.invalidate()
        programTimer = nil
        program = nil
        nextProgramStepAt = nil
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
        stopProgram()  // manual adjustment takes over from a running ramp or cool-down
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
        stopProgram()
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

    /// Pausing or changing speed on the treadmill itself cancels a program, so it never fights the user.
    private func handle(_ event: Treadmill.MachineEvent) {
        switch event {
        case .haltedByUser, .controlLost:
            stopProgram()
        case .targetSpeedChanged(let kmh):
            if program != nil, abs(kmh - programCommandedKmh) > 0.05 { stopProgram() }
        }
    }

    private func ingest(_ sample: TreadmillSample) {
        let previousKmh = live?.speedKmh
        let previousSession = session
        live = sample
        // Backstop for treadmills that don't send status events: during a program the belt only moves
        // toward what the program asked for, so moving the other way or past it means someone else took over.
        if let program, let previousKmh {
            let wrongWay = program.up ? sample.speedKmh < previousKmh - 0.05 : sample.speedKmh > previousKmh + 0.05
            let overshot = program.up ? sample.speedKmh > programCommandedKmh + 0.05
                                      : sample.speedKmh < programCommandedKmh - 0.05
            if wrongWay || overshot { stopProgram() }
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

        startCoolDownIfGoalJustReached(previous: previousSession)

        if now.timeIntervalSince(lastCheckpoint) >= 30 { checkpoint() }
        refreshToday()
    }

    /// Starts the cool-down when this sample carried the session across its goal (once per session).
    private func startCoolDownIfGoalJustReached(previous: SessionRecord?) {
        guard let goal, let s = session, let previous, previous.id == s.id,
              goal.amount(in: previous) < goal.total, goal.amount(in: s) >= goal.total,
              coolDownSessionID != s.id else { return }
        coolDownSessionID = s.id
        startProgram(.coolDown)
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
