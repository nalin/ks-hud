import SwiftUI

/// Saved sessions grouped by day; each day expands to its individual sessions.
struct HistoryView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var model: HudModel
    @State private var expanded: Set<Date> = []

    private var fmt: Format { Format(metric: model.useMetric) }

    var body: some View {
        let days = store.days
        Group {
            if days.isEmpty {
                ContentUnavailableView("No sessions yet", systemImage: "figure.walk",
                                       description: Text("Walks of 30 seconds or longer are saved automatically."))
            } else {
                List {
                    ForEach(days) { day in
                        DisclosureGroup(isExpanded: isExpanded(day.date)) {
                            ForEach(day.sessions) { SessionRow(session: $0, live: $0.id == model.session?.id, fmt: fmt) }
                        } label: {
                            DayRow(day: day, fmt: fmt)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func isExpanded(_ date: Date) -> Binding<Bool> {
        Binding(get: { expanded.contains(date) },
                set: { if $0 { expanded.insert(date) } else { expanded.remove(date) } })
    }
}

private struct DayRow: View {
    let day: DaySummary
    let fmt: Format

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(day.totals.sessions == 1 ? "1 session" : "\(day.totals.sessions) sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Metrics(elapsedS: day.totals.elapsedS, distanceM: day.totals.distanceM,
                    steps: day.totals.steps, kcal: day.totals.kcal, fmt: fmt)
        }
        .padding(.vertical, 4)
    }

    private var title: String {
        let cal = Calendar.current
        if cal.isDateInToday(day.date) { return "Today" }
        if cal.isDateInYesterday(day.date) { return "Yesterday" }
        let sameYear = cal.isDate(day.date, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
            : day.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }
}

private struct SessionRow: View {
    let session: SessionRecord
    let live: Bool
    let fmt: Format

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(session.start.formatted(date: .omitted, time: .shortened)) – \(session.end.formatted(date: .omitted, time: .shortened))")
                    if live {
                        Text("LIVE")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.green.opacity(0.2)))
                            .foregroundStyle(.green)
                    }
                }
                Text("Avg \(fmt.speed(session.avgSpeedKmh)) · max \(fmt.speed(session.maxSpeedKmh)) \(fmt.speedUnit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Metrics(elapsedS: session.elapsedS, distanceM: session.distanceM,
                    steps: session.steps ?? 0, kcal: session.kcal, fmt: fmt)
        }
        .padding(.vertical, 2)
    }
}

/// Fixed-width columns so day and session rows line up.
private struct Metrics: View {
    let elapsedS: Int
    let distanceM: Int
    let steps: Int
    let kcal: Int
    let fmt: Format

    var body: some View {
        HStack(spacing: 0) {
            column(Format.duration(elapsedS), "time")
            column(fmt.distance(distanceM), fmt.distanceUnit)
            column(Format.count(steps), "steps")
            column("\(kcal)", "kcal")
        }
    }

    private func column(_ value: String, _ unit: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).monospacedDigit()
            Text(unit).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(width: 72, alignment: .trailing)
    }
}
