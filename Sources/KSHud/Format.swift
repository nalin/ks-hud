import Foundation

struct Format {
    let metric: Bool

    var speedUnit: String { metric ? "km/h" : "mph" }
    var distanceUnit: String { metric ? "km" : "mi" }

    func speed(_ kmh: Double) -> String {
        String(format: "%.1f", metric ? kmh : kmh / 1.609344)
    }

    /// `steps` steps up or down from `kmh` (one step is 0.1 mph or 0.2 km/h), snapped to the treadmill's 0.1 km/h grid.
    func nudged(_ kmh: Double, up: Bool, steps: Int = 1) -> Double {
        let perKmh = metric ? 1 : 1 / 1.609344
        let step = (metric ? 0.2 : 0.1) * Double(steps) * (up ? 1 : -1)
        let display = (kmh * perKmh * 10).rounded() / 10 + step
        var next = (display / perKmh * 10).rounded() / 10
        if next == (kmh * 10).rounded() / 10 { next += up ? 0.1 : -0.1 }
        return next
    }

    /// Ramp targets offered in the picker: 1.5–4.0 mph by 0.1, or 2.0–6.4 km/h by 0.2, within the treadmill's range.
    func rampTargets(within range: ClosedRange<Double>) -> [Double] {
        let values = metric
            ? stride(from: 2.0, through: 6.4001, by: 0.2).map { $0 }
            : stride(from: 1.5, through: 4.0001, by: 0.1).map { $0 * 1.609344 }
        return values.filter { range.contains(($0 * 10).rounded() / 10) }
    }

    /// Cool-down speeds offered in the goal menu, in km/h.
    var coolDownTargets: [Double] {
        metric ? [1.6, 2.0, 2.5, 3.0, 3.5, 4.0] : [1.0, 1.5, 2.0, 2.5, 3.0].map { $0 * 1.609344 }
    }

    /// Time goals offered in the menu, in seconds.
    static let timeGoals = [10, 15, 20, 30, 45, 60, 90].map { $0 * 60 }

    /// e.g. "45 min", "1 h 30 min".
    static func goalDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
    }

    /// Distance goals offered in the menu, in metres.
    var distanceGoals: [Double] {
        metric
            ? [1, 2, 3, 4, 5, 6, 8, 10, 12, 15].map { $0 * 1000 }
            : [0.5, 1, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10].map { $0 * 1609.344 }
    }

    func distance(_ meters: Int) -> String {
        String(format: "%.2f", Double(meters) / (metric ? 1000 : 1609.344))
    }

    /// Minutes per km or mile, e.g. "18:45 /mi".
    func pace(_ kmh: Double) -> String {
        guard kmh >= 0.5 else { return "–" }
        let secs = Int(((metric ? 1 : 1.609344) / kmh * 3600).rounded())
        return String(format: "%d:%02d /%@", secs / 60, secs % 60, distanceUnit)
    }

    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// e.g. "<1 min left", "18 min left", "1 h 12 min left".
    static func timeLeft(_ seconds: Int) -> String {
        let minutes = Int((Double(seconds) / 60).rounded(.up))
        if seconds < 60 { return "<1 min left" }
        return minutes < 60 ? "\(minutes) min left" : "\(minutes / 60) h \(minutes % 60) min left"
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }
}
