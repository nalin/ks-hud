import Foundation

/// One Treadmill Data (0x2ACD) notification. The treadmill resets these counters at the start of each session.
struct TreadmillSample: Equatable {
    var speedKmh: Double = 0
    var distanceM: Int = 0
    var kcal: Int = 0
    var elapsedS: Int = 0
    /// KingSmith appends a non-standard 3-byte field under flag bit 13; assumed to be a step count (unverified).
    var steps: Int?
}

enum FTMS {
    /// (flag bit, size in bytes) for every optional field after instantaneous speed, in wire order.
    private static let layout: [(bit: Int, size: Int)] = [
        (1, 2),   // average speed
        (2, 3),   // total distance (m)
        (3, 4),   // inclination + ramp angle
        (4, 4),   // elevation gain
        (5, 1),   // instantaneous pace
        (6, 1),   // average pace
        (7, 5),   // total energy (kcal, uint16) + per hour + per minute
        (8, 1),   // heart rate
        (9, 1),   // metabolic equivalent
        (10, 2),  // elapsed time (s)
        (11, 2),  // remaining time
        (12, 4),  // force on belt + power output
        (13, 3),  // KingSmith extension (steps?)
    ]

    static func parseTreadmillData(_ data: Data) -> TreadmillSample? {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { return nil }
        let flags = Int(bytes[0]) | Int(bytes[1]) << 8
        var i = 2
        func read(_ n: Int) -> Int? {
            guard i + n <= bytes.count else { return nil }
            defer { i += n }
            return (0..<n).reduce(0) { $0 | Int(bytes[i + $1]) << (8 * $1) }
        }

        var sample = TreadmillSample()
        // Bit 0 is "more data": speed is present when it is clear.
        if flags & 1 == 0 {
            guard let v = read(2) else { return nil }
            sample.speedKmh = Double(v) / 100
        }
        var fields: [Int: Int] = [:]
        for f in layout where flags & (1 << f.bit) != 0 {
            guard let v = read(f.size) else { return nil }
            fields[f.bit] = v
        }
        sample.distanceM = fields[2] ?? 0
        if let energy = fields[7], energy & 0xFFFF != 0xFFFF { sample.kcal = energy & 0xFFFF }
        sample.elapsedS = fields[10] ?? 0
        sample.steps = fields[13]
        return sample
    }
}
