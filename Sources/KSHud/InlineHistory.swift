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
                if contentHeight(days) <= viewportLimit {
                    // Everything fits: a plain stack, whose height animates smoothly with the rest of the HUD.
                    VStack(spacing: 0) {
                        ForEach(days) { day in
                            dayRows(day)
                        }
                    }
                } else {
                    // More than a week: a scroll view locked at a week's height. On macOS a ScrollView that
                    // changes height repositions its content every frame, which made rows jitter while animating.
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(days.prefix(loadedDays).enumerated()), id: \.element.id) { index, day in
                                dayRows(day)
                                    .onAppear {
                                        if index >= loadedDays - 3, loadedDays < days.count { loadedDays += Self.pageSize }
                                    }
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: viewportLimit)
                }
            }
        }
    }

    private var viewportLimit: CGFloat { CGFloat(Self.visibleDays) * Self.dayHeight }

    /// Height of every day row plus the session rows of expanded days.
    private func contentHeight(_ days: [DaySummary]) -> CGFloat {
        days.reduce(0) { height, day in
            height + Self.dayHeight + (expanded.contains(day.date) ? CGFloat(day.sessions.count) * Self.sessionHeight : 0)
        }
    }

    /// A day's row followed by its sessions when expanded.
    @ViewBuilder
    private func dayRows(_ day: DaySummary) -> some View {
        dayRow(day)
        if expanded.contains(day.date) {
            ForEach(day.sessions) { sessionRow($0) }
        }
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
                        .animation(HudAnimation.resize, value: isOpen)
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
