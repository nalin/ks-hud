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
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                GridRow {
                    Stat(label: "Speed", value: fmt.speed(speed), unit: fmt.speedUnit)
                    Stat(label: "Distance", value: fmt.distance(model.session?.distanceM ?? 0), unit: fmt.distanceUnit)
                }
                GridRow {
                    Stat(label: "Steps", value: Format.count(model.session?.steps ?? 0), unit: "")
                    Stat(label: "Calories", value: "\(model.session?.kcal ?? 0)", unit: "kcal")
                }
            }
            speedControl
            rampControl
            Text(model.controlError ?? "Pace \(fmt.pace(speed))")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(model.controlError == nil ? ink.opacity(0.6) : .red)
                .lineLimit(1)
            Rectangle().fill(ink.opacity(0.12)).frame(height: 1)
            today
        }
        .padding(16)
        .frame(width: 260, alignment: .leading)
        .foregroundStyle(ink)
        .background(RoundedRectangle(cornerRadius: 16).fill(backdrop.hudIsLight ? Color.white.opacity(0.85) : .black.opacity(0.72)))
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
        }
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
        if let next = model.nextRampStepAt {
            rampProgress(nextStepAt: next)
        } else {
            HStack(spacing: 8) {
                RampButton { model.toggleRamp() }
                    .disabled(!model.canRamp)
                    .help("Raise speed \(model.useMetric ? "0.2 km/h" : "0.1 mph") every \(Int(HudModel.rampIntervalS)) s up to the target")
                Spacer(minLength: 0)
                rampTargetButton
            }
        }
    }

    /// While ramping, the whole row becomes one progress bar plus a cancel button.
    private func rampProgress(nextStepAt next: Date) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.blue.opacity(0.14))
                GeometryReader { geo in
                    Capsule()
                        .fill(Color.blue.opacity(0.4))
                        .frame(width: max(geo.size.height, geo.size.width * model.rampProgress))
                        .animation(.easeInOut(duration: 0.6), value: model.rampProgress)
                }
                HStack(spacing: 5) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 10, weight: .bold))
                    Text("Ramping to \(fmt.speed(model.rampTargetKmh)) \(fmt.speedUnit)")
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
            .frame(height: 26)
            SpeedButton(symbol: "xmark") { model.toggleRamp() }
                .help("Stop ramping")
        }
    }

    private var rampTargetButton: some View {
        Button(action: showRampTargets) {
            HStack(spacing: 4) {
                Text("to \(fmt.speed(model.rampTargetKmh)) \(fmt.speedUnit)")
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(ink.opacity(0.8))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(Capsule().fill(ink.opacity(0.08)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Ramp target")
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
                Button(action: toggleHistory) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ink.opacity(historyOpen ? 0.9 : 0.55))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(ink.opacity(historyOpen ? 0.14 : 0)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
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
                .frame(width: 30, height: 30)
                .background(Circle().fill((tint ?? ink).opacity(isEnabled ? (tint == nil ? 0.16 : 0.75) : 0.05)))
                .foregroundStyle((tint == nil ? ink : .white).opacity(isEnabled ? 1 : 0.3))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct RampButton: View {
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.hudInk) private var ink

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 10, weight: .bold))
                Text("Ramp")
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .frame(height: 26)
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
        }
        .frame(width: 100, alignment: .leading)
    }
}
