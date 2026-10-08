import SwiftUI

/// Sheet for adding a walk the app didn't record, e.g. when the phone app held the treadmill connection.
struct ManualSessionForm: View {
    @ObservedObject var model: HudModel
    /// Called with the new session's start date after it is saved.
    let onAdded: (Date) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var start = Calendar.current.date(byAdding: .minute, value: -30, to: Date()) ?? Date()
    // Plain text fields, parsed as you type, so validation and the Add button update live
    // (value-formatted fields only commit when editing ends).
    @State private var minutes = "30"
    @State private var distance = ""
    @State private var steps = ""
    @State private var calories = ""

    private var fmt: Format { Format(metric: model.useMetric) }

    private var durationS: Int { (Self.int(minutes) ?? 0) * 60 }
    private var distanceM: Int {
        Int(((Self.double(distance) ?? 0) * (model.useMetric ? 1000 : 1609.344)).rounded())
    }
    private var end: Date { start.addingTimeInterval(Double(durationS)) }

    /// Why the entry can't be saved yet; nil when it can.
    private var problem: String? {
        if durationS <= 0 { return "Enter how many minutes you walked." }
        if distanceM <= 0 { return "Enter the distance walked." }
        if !steps.isEmpty, Self.int(steps) == nil { return "Steps should be a whole number." }
        if !calories.isEmpty, Self.int(calories) == nil { return "Calories should be a whole number." }
        if end > Date() { return "The walk can't end in the future." }
        if let other = model.store.overlapping(start: start, end: end) {
            let when = other.start.formatted(date: .abbreviated, time: .shortened)
            return "Overlaps the \(when) session already saved."
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    DatePicker("Started", selection: $start, in: ...Date(), displayedComponents: [.date, .hourAndMinute])
                    TextField("Duration (min)", text: $minutes, prompt: Text("30"))
                    TextField("Distance (\(fmt.distanceUnit))", text: $distance, prompt: Text(model.useMetric ? "2.50" : "1.50"))
                } header: {
                    Text("Add a walk the app missed")
                }
                Section {
                    TextField("Steps", text: $steps, prompt: Text("Optional"))
                    TextField("Calories (kcal)", text: $calories, prompt: Text("Optional"))
                }
            }
            .formStyle(.grouped)

            HStack {
                Group {
                    if let problem {
                        Text(problem)
                    } else {
                        let avgKmh = Double(distanceM) / Double(durationS) * 3.6
                        Text("Ends \(end.formatted(date: .omitted, time: .shortened)) · avg \(fmt.speed(avgKmh)) \(fmt.speedUnit)")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Session", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
    }

    private func save() {
        guard problem == nil else { return }
        model.addManualSession(start: start, durationS: durationS, distanceM: distanceM,
                               steps: Self.int(steps), kcal: Self.int(calories))
        onAdded(start)
        dismiss()
    }

    private static func int(_ text: String) -> Int? {
        Int(text.filter { !$0.isWhitespace && $0 != "," })
    }

    private static func double(_ text: String) -> Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
    }
}
