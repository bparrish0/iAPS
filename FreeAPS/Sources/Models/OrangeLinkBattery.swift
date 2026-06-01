import Foundation

/// Tuning for a particular battery's discharge tracker. Keeps the per-battery thresholds and
/// defaults out of the tracker logic so the same engine can drive multiple batteries.
struct BatteryDischargeConfig: Sendable {
    /// Below this reading, the battery is "low" — eligible for replacement-jump detection.
    let replacementLowThreshold: Double
    /// At or above this reading after a low reading, treat as a fresh-battery replacement.
    let replacementHighThreshold: Double
    /// Bucket size for the discharge curve. 0.1 → 0.1V bands (OrangeLink) or 10% bands (pump).
    let levelGranularity: Double
    /// Fallback lifetime to use until at least one complete discharge cycle has been learned.
    let defaultLifetime: TimeInterval
    /// Cap on retained completed cycles, so the rolling average stays bounded.
    let maxStoredCycles: Int

    /// OrangeLink/RileyLink CR2032-class cell: ~3.4V fresh, drops into the 2.x range when dying,
    /// ~29-day default lifetime.
    static let orangeLink = BatteryDischargeConfig(
        replacementLowThreshold: 3.0,
        replacementHighThreshold: 3.2,
        levelGranularity: 0.1,
        defaultLifetime: 29 * 86400,
        maxStoredCycles: 10
    )

    /// Medtronic AA pump battery: fresh ≥1.5V, dying ~1.0V, ~15-day default lifetime. Same
    /// detection thresholds MinimedKit uses internally for `batteryInsertionDate`.
    static let pump = BatteryDischargeConfig(
        replacementLowThreshold: 1.5,
        replacementHighThreshold: 1.55,
        levelGranularity: 0.05,
        defaultLifetime: 15 * 86400,
        maxStoredCycles: 10
    )
}

struct BatteryLevelTime: JSON, Equatable {
    let level: Int
    let date: Date
}

struct BatteryLevelOffset: JSON, Equatable {
    let level: Int
    let secondsFromReplacement: TimeInterval
}

struct BatteryDischargeCycle: JSON, Equatable {
    let totalLifetime: TimeInterval
    let levelOffsets: [BatteryLevelOffset]
}

/// Persisted state for a single battery's discharge tracking, kept in a JSON file under
/// `monitor/` so it survives reboots.
struct BatteryDischargeLog: JSON, Equatable {
    var replacementDate: Date?
    /// True when the current cycle began from a detected fresh-battery jump, so it can be saved
    /// to `completedCycles` on the next replacement. False for the synthetic cycle anchored on
    /// the first reading we ever observed for this battery (used only to show a default-lifetime
    /// countdown — not learnable data).
    var cycleIsLearnable: Bool
    var lastValue: Double?
    var lastValueDate: Date?
    var currentLevelTimes: [BatteryLevelTime]
    var completedCycles: [BatteryDischargeCycle]
    var currentExpirationDate: Date?

    init(
        replacementDate: Date? = nil,
        cycleIsLearnable: Bool = false,
        lastValue: Double? = nil,
        lastValueDate: Date? = nil,
        currentLevelTimes: [BatteryLevelTime] = [],
        completedCycles: [BatteryDischargeCycle] = [],
        currentExpirationDate: Date? = nil
    ) {
        self.replacementDate = replacementDate
        self.cycleIsLearnable = cycleIsLearnable
        self.lastValue = lastValue
        self.lastValueDate = lastValueDate
        self.currentLevelTimes = currentLevelTimes
        self.completedCycles = completedCycles
        self.currentExpirationDate = currentExpirationDate
    }
}

/// Pure logic for tracking a battery's discharge curve and estimating time remaining.
/// Records a new reading, detects fresh-battery replacements, finalizes learnable cycles, and
/// recomputes the running expiration estimate.
enum BatteryDischargeTracker {
    static func level(for value: Double, config: BatteryDischargeConfig) -> Int {
        Int((value / config.levelGranularity).rounded(.down))
    }

    /// Record a new reading; mutates `log` in place.
    static func record(
        value: Double,
        at date: Date,
        into log: inout BatteryDischargeLog,
        config: BatteryDischargeConfig
    ) {
        defer {
            log.lastValue = value
            log.lastValueDate = date
            log.currentExpirationDate = estimatedExpiration(at: value, from: date, log: log, config: config)
        }

        let priorWasLow = (log.lastValue ?? .greatestFiniteMagnitude) < config.replacementLowThreshold
        let isReplacement = priorWasLow && value >= config.replacementHighThreshold

        if isReplacement {
            // Finalize the prior cycle if it began from a detected replacement (not synthetic).
            if log.cycleIsLearnable,
               let start = log.replacementDate,
               let death = log.lastValueDate,
               !log.currentLevelTimes.isEmpty
            {
                let lifetime = death.timeIntervalSince(start)
                if lifetime > 0 {
                    let offsets = log.currentLevelTimes.map {
                        BatteryLevelOffset(level: $0.level, secondsFromReplacement: $0.date.timeIntervalSince(start))
                    }
                    log.completedCycles.append(BatteryDischargeCycle(totalLifetime: lifetime, levelOffsets: offsets))
                    if log.completedCycles.count > config.maxStoredCycles {
                        log.completedCycles.removeFirst(log.completedCycles.count - config.maxStoredCycles)
                    }
                }
            }
            log.replacementDate = date
            log.cycleIsLearnable = true
            log.currentLevelTimes = [BatteryLevelTime(level: level(for: value, config: config), date: date)]
            return
        }

        // First-ever reading: anchor a synthetic cycle here so a default-lifetime countdown shows
        // until the user replaces the battery for real (which starts a learnable cycle).
        if log.replacementDate == nil {
            log.replacementDate = date
            log.cycleIsLearnable = false
            log.currentLevelTimes = [BatteryLevelTime(level: level(for: value, config: config), date: date)]
            return
        }

        let lvl = level(for: value, config: config)
        if !log.currentLevelTimes.contains(where: { $0.level == lvl }) {
            log.currentLevelTimes.append(BatteryLevelTime(level: lvl, date: date))
        }
    }

    /// Average each level's elapsed-time-from-replacement and the total lifetime across all
    /// completed cycles. Returns `nil` when no full cycle has been logged yet.
    static func averagedProfile(_ cycles: [BatteryDischargeCycle])
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

    /// Expiration estimate: learned curve when we have completed cycles, otherwise
    /// `replacementDate + defaultLifetime` (which can produce a negative remaining-time once
    /// elapsed, surfacing as e.g. "P-1d1h" in the UI).
    static func estimatedExpiration(
        at value: Double,
        from date: Date,
        log: BatteryDischargeLog,
        config: BatteryDischargeConfig
    ) -> Date? {
        if let profile = averagedProfile(log.completedCycles) {
            let elapsed = interpolatedOffset(
                forValue: value,
                offsets: profile.offsets,
                granularity: config.levelGranularity
            )
            return date.addingTimeInterval(profile.lifetime - elapsed)
        }
        if let start = log.replacementDate {
            return start.addingTimeInterval(config.defaultLifetime)
        }
        return nil
    }

    /// Elapsed-time-from-replacement at a given reading, linearly interpolating between the two
    /// nearest learned levels (offset decreases as the reading rises). Clamps outside the
    /// learned range.
    static func interpolatedOffset(
        forValue value: Double,
        offsets: [Int: TimeInterval],
        granularity: Double
    ) -> TimeInterval {
        guard !offsets.isEmpty else { return 0 }
        let levels = offsets.keys.sorted()
        let scaled = value / granularity
        if let highest = levels.last, scaled >= Double(highest) { return offsets[highest] ?? 0 }
        if let lowest = levels.first, scaled <= Double(lowest) { return offsets[lowest] ?? 0 }
        var lower = levels.first!
        var upper = levels.last!
        for lvl in levels {
            if Double(lvl) <= scaled { lower = lvl }
            if Double(lvl) >= scaled { upper = lvl; break }
        }
        guard lower != upper, let low = offsets[lower], let high = offsets[upper] else {
            return offsets[lower] ?? 0
        }
        let fraction = (scaled - Double(lower)) / Double(upper - lower)
        return low + (high - low) * fraction
    }
}
