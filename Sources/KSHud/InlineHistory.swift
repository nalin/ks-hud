import SwiftUI

/// History inside the HUD: one compact row per day, sized so a week fits without scrolling. Older days are
/// paged in as the list scrolls, and clicking a day reveals its individual sessions.
struct InlineHistory: View {
    @ObservedObject var store: SessionStore
    let fmt: Format
    @Environment(\.hudInk) private var ink
    @State private var loadedDays = Self.pageSize
    @State private var expanded: Set<Date> = []

    private static let pageSize = 14
    private static let visibleDays = 7
    private static let headerHeight: CGFloat = 16
    private static let dayHeight: CGFloat = 26
    private static let sessionHeight: CGFloat = 22

    var body: some View {
        let days = store.days
        if days.isEmpty {
            Text("No saved sessions yet")
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.5))
        } else {
            VStack(spacing: 0) {
                columns(Text("Day"), Text("Dist"), Text("Time"), Text("Steps"))
                    .font(.system(size: 10, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(ink.opacity(0.4))
                    .frame(height: Self.headerHeight)
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(days.prefix(loadedDays).enumerated()), id: \.element.id) { index, day in
                            dayRow(day)
                                .onAppear {
                                    if index >= loadedDays - 3, loadedDays < days.count { loadedDays += Self.pageSize }
                                }
                            if expanded.contains(day.date) {
                                ForEach(day.sessions) { sessionRow($0) }
                            }
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(height: viewportHeight(days))
            }
        }
    }

    /// A week of collapsed days; shorter when there's less history, so the list never shows empty space.
    private func viewportHeight(_ days: [DaySummary]) -> CGFloat {
        var height: CGFloat = 0
        for day in days.prefix(loadedDays) {
            height += Self.dayHeight
            if expanded.contains(day.date) { height += CGFloat(day.sessions.count) * Self.sessionHeight }
        }
        return min(height, CGFloat(Self.visibleDays) * Self.dayHeight)
    }

    private func dayRow(_ day: DaySummary) -> some View {
        let isOpen = expanded.contains(day.date)
        return Button {
            withAnimation(HudAnimation.resize) {
                if isOpen { expanded.remove(day.date) } else { expanded.insert(day.date) }
            }
        } label: {
            columns(
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(ink.opacity(0.4))
                    Text(title(for: day.date))
                },
                Text("\(fmt.distance(day.totals.distanceM)) \(fmt.distanceUnit)"),
                Text(Self.shortDuration(day.totals.elapsedS)),
                Text(Self.compactCount(day.totals.steps))
            )
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(ink.opacity(0.85))
            .frame(height: Self.dayHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ s: SessionRecord) -> some View {
        columns(
            Text(s.start.formatted(date: .omitted, time: .shortened)).padding(.leading, 13),
            Text("\(fmt.distance(s.distanceM)) \(fmt.distanceUnit)"),
            Text(Self.shortDuration(s.elapsedS)),
            Text(Self.compactCount(s.steps ?? 0))
        )
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(ink.opacity(0.6))
        .frame(height: Self.sessionHeight)
    }

    /// Fixed-width numeric columns so every row lines up with the header.
    private func columns(_ label: some View, _ distance: some View, _ time: some View, _ steps: some View) -> some View {
        HStack(spacing: 6) {
            label.lineLimit(1)
            Spacer(minLength: 0)
            distance.frame(width: 54, alignment: .trailing)
            time.frame(width: 44, alignment: .trailing)
            steps.frame(width: 38, alignment: .trailing)
        }
        .monospacedDigit()
    }

    private func title(for date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: date, to: cal.startOfDay(for: Date())).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static func shortDuration(_ seconds: Int) -> String {
        let minutes = seconds / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }

    private static func compactCount(_ n: Int) -> String {
        switch n {
        case ..<1000: "\(n)"
        case ..<10_000: String(format: "%.1fk", Double(n) / 1000)
        default: "\(n / 1000)k"
        }
    }
}
