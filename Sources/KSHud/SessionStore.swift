import Foundation

struct SessionRecord: Codable, Identifiable {
    var id: String
    var start: Date
    var end: Date
    var elapsedS: Int
    var distanceM: Int
    var kcal: Int
    var steps: Int?
    var maxSpeedKmh: Double
    /// Roughly every 10 s of elapsed time: [elapsed s, speed km/h, distance m].
    var trace: [[Double]]

    var avgSpeedKmh: Double { elapsedS > 0 ? Double(distanceM) / Double(elapsedS) * 3.6 : 0 }
}

struct Totals {
    var sessions = 0
    var elapsedS = 0
    var distanceM = 0
    var kcal = 0
    var steps = 0

    mutating func add(_ r: SessionRecord) {
        sessions += 1
        elapsedS += r.elapsedS
        distanceM += r.distanceM
        kcal += r.kcal
        steps += r.steps ?? 0
    }
}

struct DaySummary: Identifiable {
    let date: Date
    /// Newest first.
    let sessions: [SessionRecord]
    let totals: Totals

    var id: Date { date }
}

/// One JSON file per session in ~/Library/Application Support/KSHud/sessions.
final class SessionStore: ObservableObject {
    let directory: URL
    @Published private(set) var sessions: [SessionRecord] = []

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("KSHud/sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        sessions = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(SessionRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.start < $1.start }
    }

    func save(_ record: SessionRecord) {
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: directory.appendingPathComponent("\(record.id).json"), options: .atomic)
        if let i = sessions.firstIndex(where: { $0.id == record.id }) {
            sessions[i] = record
        } else {
            sessions.append(record)
        }
    }

    /// Sessions grouped by the local day they started on, newest day first.
    var days: [DaySummary] {
        Dictionary(grouping: sessions) { Calendar.current.startOfDay(for: $0.start) }
            .map { date, records in
                var totals = Totals()
                records.forEach { totals.add($0) }
                return DaySummary(date: date, sessions: records.sorted { $0.start > $1.start }, totals: totals)
            }
            .sorted { $0.date > $1.date }
    }

    func totals(on day: Date, excluding id: String? = nil) -> Totals {
        var t = Totals()
        for s in sessions where s.id != id && Calendar.current.isDate(s.start, inSameDayAs: day) {
            t.add(s)
        }
        return t
    }
}
