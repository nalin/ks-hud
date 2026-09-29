import SwiftUI

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
        .environment(\.hudInk, ink)
        .animation(.easeInOut(duration: 0.4), value: backdrop.hudIsLight)
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

    private var today: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Today")
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(ink.opacity(0.45))
            Text("\(fmt.distance(model.today.distanceM)) \(fmt.distanceUnit) · \(Format.count(model.today.steps)) steps · \(model.today.elapsedS / 60) min")
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(ink.opacity(0.85))
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
