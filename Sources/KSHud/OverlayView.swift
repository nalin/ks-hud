import AppKit
import SwiftUI

enum HudAnimation {
    /// Used for every change to the HUD's height; OverlayPanel waits this long before shrinking the window.
    static let duration = 0.3
    static let resize = Animation.easeInOut(duration: duration)
}

private struct HudInkKey: EnvironmentKey {
    static let defaultValue = Color.white
}

extension EnvironmentValues {
    /// Foreground colour of the HUD: white on the dark tone, black on the light one.
    var hudInk: Color {
        get { self[HudInkKey.self] }
        set { self[HudInkKey.self] = newValue }
    }
}

struct OverlayView: View {
    @ObservedObject var model: HudModel
    @ObservedObject var backdrop: Backdrop
    /// Reports the HUD's natural size so the panel can resize around it.
    let onResize: (CGSize) -> Void
    /// Plain state rather than @AppStorage: AppStorage's update can land outside withAnimation, so the change
    /// would snap instead of animating. Persisted by hand in toggleHistory().
    @State private var historyOpen = UserDefaults.standard.bool(forKey: "inlineHistoryOpen")

    private var ink: Color { backdrop.hudIsLight ? .black : .white }

    private var fmt: Format { Format(metric: model.useMetric) }
    private var speed: Double { model.live?.speedKmh ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Text(Format.duration(model.session?.elapsedS ?? 0))
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(model.session == nil ? ink.opacity(0.35) : ink)
            if let goal = model.goal {
                goalBar(goal)
                    .padding(.top, -6)  // reads as part of the timer block
            }
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow(alignment: .top) {
                    Stat(label: "Speed", value: fmt.speed(speed), unit: fmt.speedUnit, detail: "Pace \(fmt.pace(speed))")
                    Stat(label: "Distance", value: fmt.distance(model.session?.distanceM ?? 0), unit: fmt.distanceUnit)
                }
                GridRow {
                    Stat(label: "Steps", value: Format.count(model.session?.steps ?? 0), unit: "")
                    Stat(label: "Calories", value: "\(model.session?.kcal ?? 0)", unit: "kcal")
                }
            }
            speedControl
            rampControl
            if let error = model.controlError {
                Text(error)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.red)
                    .lineLimit(1)
            }
            Rectangle().fill(ink.opacity(0.12)).frame(height: 1)
            today
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
        .foregroundStyle(ink)
        .background(RoundedRectangle(cornerRadius: 16).fill(backdrop.hudIsLight ? Color.white.opacity(0.85) : .black.opacity(0.82)))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ink.opacity(0.1)))
        // Content is revealed as the card grows instead of spilling past its bottom edge mid-animation.
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .environment(\.hudInk, ink)
        .animation(.easeInOut(duration: 0.4), value: backdrop.hudIsLight)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { onResize(geo.size) }
                .onChange(of: geo.size) { _, size in onResize(size) }
        })
    }

    private var header: some View {
        HStack(spacing: 6) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(ink.opacity(0.6))
                .lineLimit(1)
            Spacer(minLength: 0)
            HeaderIconButton(symbol: "flag.checkered", active: model.goal != nil, action: showGoalMenu)
                .help("Session goal")
        }
    }

    /// "1.20 of 3.00 mi" or "22:10 of 45:00", time left on the right, over a thin progress line.
    /// For distance goals the time left assumes the current belt speed; time goals follow the session timer.
    private func goalBar(_ goal: HudModel.SessionGoal) -> some View {
        let covered = goal.amount(in: model.session)
        let progress = min(covered / goal.total, 1)
        let reached = covered >= goal.total
        let summary = switch goal {
        case .distance(let meters): "\(fmt.distance(Int(covered))) of \(fmt.distance(Int(meters.rounded()))) \(fmt.distanceUnit)"
        case .time(let seconds): "\(Format.duration(Int(covered))) of \(Format.duration(seconds))"
        }
        let status: String? = if reached {
            "Goal reached"
        } else if speed > 0 {
            switch goal {
            case .distance: Format.timeLeft(Int((goal.total - covered) / (speed / 3.6)))
            case .time: Format.timeLeft(Int(goal.total - covered))
            }
        } else if model.session != nil {
            "Paused"
        } else {
            nil
        }
        return Button(action: showGoalMenu) {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(summary)
                        .foregroundStyle(ink.opacity(0.7))
                    Spacer(minLength: 4)
                    if let status {
                        HStack(spacing: 3) {
                            if reached { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
                            Text(status)
                        }
                        .foregroundStyle(reached ? Color.green : ink.opacity(0.7))
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                ZStack(alignment: .leading) {
                    Capsule().fill(ink.opacity(0.12))
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.green)
                            .frame(width: geo.size.width * progress)
                            .animation(.easeInOut(duration: 0.6), value: progress)
                    }
                }
                .frame(height: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Change distance goal")
    }

    private func showGoalMenu() {
        let menu = NSMenu()
        func choose(_ goal: HudModel.SessionGoal?) {
            withAnimation(HudAnimation.resize) { model.goal = goal }
        }

        menu.addItem(.sectionHeader(title: "Distance"))
        var currentDistance: String?
        if case .distance(let meters) = model.goal { currentDistance = fmt.distance(Int(meters.rounded())) }
        for meters in fmt.distanceGoals {
            let label = fmt.distance(Int(meters.rounded()))
            menu.addItem(ActionMenuItem(title: "\(label) \(fmt.distanceUnit)", checked: label == currentDistance) {
                choose(.distance(meters: meters))
            })
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Time"))
        for seconds in Format.timeGoals {
            menu.addItem(ActionMenuItem(title: Format.goalDuration(seconds), checked: model.goal == .time(seconds: seconds)) {
                choose(.time(seconds: seconds))
            })
        }

        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(title: "No Goal", checked: model.goal == nil) { choose(nil) })

        // Cool-down: after the goal, step the speed down like a reverse ramp.
        let coolDown = NSMenu()
        let currentCoolDown = model.coolDownTargetKmh.map { fmt.speed($0) }
        for kmh in fmt.coolDownTargets {
            let label = fmt.speed(kmh)
            coolDown.addItem(ActionMenuItem(title: "To \(label) \(fmt.speedUnit)", checked: label == currentCoolDown) {
                model.coolDownTargetKmh = kmh
            })
        }
        coolDown.addItem(.separator())
        coolDown.addItem(ActionMenuItem(title: "Off", checked: model.coolDownTargetKmh == nil) {
            model.coolDownTargetKmh = nil
        })
        menu.addItem(.separator())
        let coolDownItem = NSMenuItem(title: "Cool Down After Goal", action: nil, keyEquivalent: "")
        coolDownItem.submenu = coolDown
        menu.addItem(coolDownItem)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private var speedControl: some View {
        HStack {
            SpeedButton(symbol: "minus") { model.nudgeSpeed(up: false) }
                .disabled(!model.canControlSpeed)
            Spacer()
            Group {
                if let target = model.targetKmh {
                    Text("→ \(fmt.speed(target)) \(fmt.speedUnit)")
                } else {
                    Text(model.starting ? (model.session == nil ? "Starting…" : "Resuming…")
                         : model.beltMoving ? "Speed" : (model.session == nil ? "Stopped" : "Paused"))
                        .foregroundStyle(ink.opacity(0.5))
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .monospacedDigit()
            Spacer()
            SpeedButton(symbol: "plus") { model.nudgeSpeed(up: true) }
                .disabled(!model.canControlSpeed)
            if model.beltMoving {
                SpeedButton(symbol: "pause.fill", tint: .orange) { model.pause() }
                    .disabled(!model.canControlSpeed)
                    .help("Pause the belt")
            } else {
                SpeedButton(symbol: "play.fill", tint: .green) { model.start() }
                    .disabled(!model.canStart)
                    .help(model.session == nil ? "Start the belt" : "Resume")
            }
        }
        .padding(4)
        .background(Capsule().fill(ink.opacity(0.06)))
    }

    @ViewBuilder
    private var rampControl: some View {
        if let program = model.program, let next = model.nextProgramStepAt {
            programProgress(program, nextStepAt: next)
        } else {
            // Two equal-width pills, matching the height of the round speed buttons.
            HStack(spacing: 8) {
                PillButton(action: model.toggleRamp) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 10, weight: .bold))
                    Text("Ramp")
                }
                .disabled(!model.canRamp)
                .help("Raise speed \(model.useMetric ? "0.2 km/h" : "0.1 mph") every \(Int(HudModel.programIntervalS)) s up to the target")
                PillButton(action: showRampTargets) {
                    Text("to \(fmt.speed(model.rampTargetKmh)) \(fmt.speedUnit)")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .help("Ramp target")
            }
        }
    }

    /// While a ramp or cool-down runs, the whole row becomes one progress bar plus a cancel button.
    private func programProgress(_ program: HudModel.SpeedProgram, nextStepAt next: Date) -> some View {
        let tint: Color = program.up ? .blue : .teal
        let goal = program.up ? model.rampTargetKmh : (model.coolDownTargetKmh ?? 0)
        return HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.14))
                GeometryReader { geo in
                    Capsule()
                        .fill(tint.opacity(0.4))
                        .frame(width: max(geo.size.height, geo.size.width * model.programProgress))
                        .animation(.easeInOut(duration: 0.6), value: model.programProgress)
                }
                HStack(spacing: 5) {
                    Image(systemName: program.up ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                        .font(.system(size: 10, weight: .bold))
                    Text("\(program.up ? "Ramping" : "Cooling down") to \(fmt.speed(goal)) \(fmt.speedUnit)")
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(max(0, Int(next.timeIntervalSince(context.date).rounded(.up))))s")
                            .foregroundStyle(ink.opacity(0.6))
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .padding(.horizontal, 10)
            }
            .frame(height: HudMetrics.controlHeight)
            SpeedButton(symbol: "xmark") { model.cancelProgram() }
                .help(program.up ? "Stop ramping" : "Stop cooling down")
        }
    }

    private func showRampTargets() {
        let menu = NSMenu()
        let current = fmt.speed(model.rampTargetKmh)
        for kmh in fmt.rampTargets(within: model.speedRange) {
            let label = fmt.speed(kmh)
            menu.addItem(ActionMenuItem(title: "\(label) \(fmt.speedUnit)", checked: label == current) {
                model.rampTargetKmh = kmh
            })
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func toggleHistory() {
        withAnimation(HudAnimation.resize) { historyOpen.toggle() }
        UserDefaults.standard.set(historyOpen, forKey: "inlineHistoryOpen")
    }

    private var today: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Today")
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(0.6)
                    .foregroundStyle(ink.opacity(0.45))
                Spacer()
                HeaderIconButton(symbol: "clock.arrow.circlepath", active: historyOpen, action: toggleHistory)
                    .help(historyOpen ? "Hide history" : "Show history")
            }
            Text("\(fmt.distance(model.today.distanceM)) \(fmt.distanceUnit) · \(Format.count(model.today.steps)) steps · \(model.today.elapsedS / 60) min")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ink.opacity(0.85))
            if historyOpen {
                InlineHistory(store: model.store, fmt: fmt)
                    .padding(.top, 8)
                    .transition(.opacity)
            }
        }
    }

    private var statusText: String {
        switch model.link {
        case .searching: "Looking for treadmill"
        case .connecting(let name): "Connecting to \(name)"
        case .connected: model.session == nil ? "Connected · idle" : (speed > 0 ? "Walking" : "Paused")
        case .unavailable(let reason): reason
        }
    }

    private var statusColor: Color {
        switch model.link {
        case .connected: speed > 0 ? .green : .yellow
        case .unavailable: .red
        default: .gray
        }
    }
}

/// Small icon toggle used in section headers; highlighted with a soft circle while its feature is on.
/// Negative padding keeps the 24 pt hit area from making the header line taller.
private struct HeaderIconButton: View {
    let symbol: String
    let active: Bool
    let action: () -> Void
    @Environment(\.hudInk) private var ink

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ink.opacity(active ? 0.9 : 0.55))
                .frame(width: 24, height: 24)
                .background(Circle().fill(ink.opacity(active ? 0.14 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -6)
    }
}

private struct SpeedButton: View {
    let symbol: String
    /// nil for the neutral buttons, which follow the HUD tone.
    var tint: Color?
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.hudInk) private var ink

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .frame(width: HudMetrics.controlHeight, height: HudMetrics.controlHeight)
                .background(Circle().fill((tint ?? ink).opacity(isEnabled ? (tint == nil ? 0.16 : 0.75) : 0.05)))
                .foregroundStyle((tint == nil ? ink : .white).opacity(isEnabled ? 1 : 0.3))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private enum HudMetrics {
    /// Height of every tappable control: SpeedButton's circles and the pills.
    static let controlHeight: CGFloat = 30
}

/// Capsule button that fills its share of a row.
private struct PillButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.hudInk) private var ink

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) { label }
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: HudMetrics.controlHeight)
                .background(Capsule().fill(ink.opacity(isEnabled ? 0.16 : 0.05)))
                .foregroundStyle(ink.opacity(isEnabled ? 1 : 0.3))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Menu item that runs a closure, for menus popped up from SwiftUI.
private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, checked: Bool, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func run() {
        handler()
    }
}

private struct Stat: View {
    let label: String
    let value: String
    let unit: String
    /// Optional small line under the value, e.g. pace under speed.
    var detail: String?
    @Environment(\.hudInk) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ink.opacity(0.5))
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink.opacity(0.5))
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(ink.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(width: 100, alignment: .leading)
    }
}
