import Foundation

/// A voltage level reached during a discharge cycle, with the time it was first reached.
/// `level` is the voltage multiplied by 10 and floored, e.g. 34 for 3.4V, 30 for 3.0V.
struct OrangeLinkLevelTime: JSON, Equatable {
    let level: Int
    let date: Date
}

/// A single voltage level's elapsed time from battery replacement, for a completed cycle.
struct OrangeLinkLevelOffset: JSON, Equatable {
    let level: Int
    let secondsFromReplacement: TimeInterval
}

/// A completed discharge cycle: from battery replacement to its death (next replacement).
struct OrangeLinkDischargeCycle: JSON, Equatable {
    let totalLifetime: TimeInterval
    let levelOffsets: [OrangeLinkLevelOffset]
}

/// Persisted state for OrangeLink/RileyLink battery voltage tracking. Lives in
/// `monitor/orangelink-battery.json` so it survives reboots.
struct OrangeLinkBatteryLog: JSON, Equatable {
    /// When the current battery was inserted. `nil` until the first replacement is detected.
    var replacementDate: Date?
    var lastVoltage: Double?
    var lastVoltageDate: Date?
    /// Levels reached so far in the current (in-progress) cycle.
    var currentLevelTimes: [OrangeLinkLevelTime]
    /// Completed cycles used to learn the discharge curve.
    var completedCycles: [OrangeLinkDischargeCycle]
    /// Estimated expiration of the current battery, recomputed on each reading. `nil` until a
    /// full cycle has been logged.
    var currentExpirationDate: Date?

    init(
        replacementDate: Date? = nil,
        lastVoltage: Double? = nil,
        lastVoltageDate: Date? = nil,
        currentLevelTimes: [OrangeLinkLevelTime] = [],
        completedCycles: [OrangeLinkDischargeCycle] = [],
        currentExpirationDate: Date? = nil
    ) {
        self.replacementDate = replacementDate
        self.lastVoltage = lastVoltage
        self.lastVoltageDate = lastVoltageDate
        self.currentLevelTimes = currentLevelTimes
        self.completedCycles = completedCycles
        self.currentExpirationDate = currentExpirationDate
    }
}

/// Pure logic for tracking the OrangeLink battery voltage over time and estimating time remaining.
enum OrangeLinkBatteryTracker {
    /// A reading is treated as a battery replacement when the previous reading was below this …
    static let replacementLowThreshold = 3.1
    /// … and the new reading is at or above this. (Fresh batteries read ~3.4V, dead ones ~2.x.)
    static let replacementHighThreshold = 3.2
    /// Cap on retained completed cycles, so the rolling average stays bounded.
    static let maxStoredCycles = 10

    /// Voltage rounded down to the nearest 0.1V, expressed as an integer (3.42V -> 34, 3.0V -> 30).
    static func level(for voltage: Double) -> Int {
        Int((voltage * 10).rounded(.down))
    }

    /// Record a new voltage reading: detect replacement, log new levels, finalize completed
    /// cycles, and recompute the current estimate. Mutates `log` in place.
    static func record(voltage: Double, at date: Date, into log: inout OrangeLinkBatteryLog) {
        defer {
            log.lastVoltage = voltage
            log.lastVoltageDate = date
            log.currentExpirationDate = estimatedExpiration(at: voltage, from: date, log: log)
        }

        let isReplacement = (log.lastVoltage ?? .greatestFiniteMagnitude) < replacementLowThreshold
            && voltage >= replacementHighThreshold

        if isReplacement {
            // Finalize the cycle that just ended, if it actually discharged.
            if let start = log.replacementDate,
               let death = log.lastVoltageDate,
               !log.currentLevelTimes.isEmpty
            {
                let lifetime = death.timeIntervalSince(start)
                if lifetime > 0 {
                    let offsets = log.currentLevelTimes.map {
                        OrangeLinkLevelOffset(level: $0.level, secondsFromReplacement: $0.date.timeIntervalSince(start))
                    }
                    log.completedCycles.append(OrangeLinkDischargeCycle(totalLifetime: lifetime, levelOffsets: offsets))
                    if log.completedCycles.count > maxStoredCycles {
                        log.completedCycles.removeFirst(log.completedCycles.count - maxStoredCycles)
                    }
                }
            }
            // Begin the new cycle.
            log.replacementDate = date
            log.currentLevelTimes = [OrangeLinkLevelTime(level: level(for: voltage), date: date)]
            return
        }

        // Only log levels once a replacement has been observed (so the first learned cycle is complete).
        guard log.replacementDate != nil else { return }

        let lvl = level(for: voltage)
        if !log.currentLevelTimes.contains(where: { $0.level == lvl }) {
            log.currentLevelTimes.append(OrangeLinkLevelTime(level: lvl, date: date))
        }
    }

    /// Average each level's elapsed-time-from-replacement and the total lifetime across all
    /// completed cycles. Returns `nil` when no full cycle has been logged yet.
    static func averagedProfile(_ cycles: [OrangeLinkDischargeCycle])
        -> (lifetime: TimeInterval, offsets: [Int: TimeInterval])?
    {
        guard !cycles.isEmpty else { return nil }
        let lifetime = cycles.map(\.totalLifetime).reduce(0, +) / Double(cycles.count)
        var sums: [Int: (total: TimeInterval, count: Int)] = [:]
        for cycle in cycles {
            for offset in cycle.levelOffsets {
                let current = sums[offset.level] ?? (0, 0)
                sums[offset.level] = (current.total + offset.secondsFromReplacement, current.count + 1)
            }
        }
        let offsets = sums.mapValues { $0.total / Double($0.count) }
        return (lifetime, offsets)
    }

    /// Estimated time remaining at the given voltage, from the learned (averaged) discharge curve.
    static func estimatedRemaining(at voltage: Double, log: OrangeLinkBatteryLog) -> TimeInterval? {
        guard let profile = averagedProfile(log.completedCycles) else { return nil }
        let elapsed = interpolatedOffset(forVoltage: voltage, offsets: profile.offsets)
        return max(0, profile.lifetime - elapsed)
    }

    static func estimatedExpiration(at voltage: Double, from date: Date, log: OrangeLinkBatteryLog) -> Date? {
        guard let remaining = estimatedRemaining(at: voltage, log: log) else { return nil }
        return date.addingTimeInterval(remaining)
    }

    /// Elapsed-time-from-replacement at a given voltage, linearly interpolating between the two
    /// nearest learned levels (offset decreases as voltage rises). Clamps outside the learned range.
    static func interpolatedOffset(forVoltage voltage: Double, offsets: [Int: TimeInterval]) -> TimeInterval {
        guard !offsets.isEmpty else { return 0 }
        let levels = offsets.keys.sorted()
        let v10 = voltage * 10

        if let highest = levels.last, v10 >= Double(highest) { return offsets[highest] ?? 0 }
        if let lowest = levels.first, v10 <= Double(lowest) { return offsets[lowest] ?? 0 }

        var lower = levels.first!
        var upper = levels.last!
        for level in levels {
            if Double(level) <= v10 { lower = level }
            if Double(level) >= v10 { upper = level; break }
        }
        guard lower != upper, let low = offsets[lower], let high = offsets[upper] else {
            return offsets[lower] ?? 0
        }
        let fraction = (v10 - Double(lower)) / Double(upper - lower)
        return low + (high - low) * fraction
    }
}
