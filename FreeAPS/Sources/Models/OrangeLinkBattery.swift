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
    /// Voltage of a fresh cell — top of the default (unlearned) discharge table.
    let defaultFreshValue: Double
    /// Voltage where the cell is considered spent — bottom of the default discharge table.
    let defaultDepletedValue: Double

    /// OrangeLink/RileyLink CR2032-class cell: ~3.4V fresh, drops into the 2.x range when dying,
    /// ~29-day default lifetime.
    static let orangeLink = BatteryDischargeConfig(
        replacementLowThreshold: 3.0,
        replacementHighThreshold: 3.2,
        levelGranularity: 0.1,
        defaultLifetime: 29 * 86400,
        maxStoredCycles: 10,
        defaultFreshValue: 3.4,
        defaultDepletedValue: 2.8
    )

    /// Medtronic AA pump battery: fresh ≥1.5V, dying ~1.0V, ~15-day default lifetime. Same
    /// detection thresholds MinimedKit uses internally for `batteryInsertionDate`.
    static let pump = BatteryDischargeConfig(
        replacementLowThreshold: 1.5,
        replacementHighThreshold: 1.55,
        levelGranularity: 0.05,
        defaultLifetime: 15 * 86400,
        maxStoredCycles: 10,
        defaultFreshValue: 1.55,
        defaultDepletedValue: 1.1
    )
}

/// Which physical battery a discharge log belongs to. Carries the per-device config and
/// storage location so UI code can address either battery generically.
enum BatteryDeviceKind: String, Identifiable, CaseIterable {
    case pump
    case orangeLink

    var id: String { rawValue }

    var config: BatteryDischargeConfig {
        switch self {
        case .pump: return .pump
        case .orangeLink: return .orangeLink
        }
    }

    var storageFile: String {
        switch self {
        case .pump: return OpenAPS.Monitor.pumpBatteryLog
        case .orangeLink: return OpenAPS.Monitor.orangeLinkBattery
        }
    }

    var title: String {
        switch self {
        case .pump: return NSLocalizedString("Pump Battery", comment: "Battery detail title")
        case .orangeLink: return NSLocalizedString("OrangeLink Battery", comment: "Battery detail title")
        }
    }

    /// Decimal places that make sense for this battery's voltage granularity.
    var voltageFractionDigits: Int {
        switch self {
        case .pump: return 2
        case .orangeLink: return 1
        }
    }
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
    /// When this battery was installed. Optional because cycles recorded before this field
    /// existed have no date.
    var startDate: Date?
}

/// A user-editable estimate: "when the battery first reads at `level`, it has
/// `secondsRemaining` left". Stored per-level in the log and applied on top of the learned
/// (or default) discharge curve.
struct BatteryLevelRemaining: JSON, Equatable {
    let level: Int
    var secondsRemaining: TimeInterval
}

/// One raw voltage observation, kept whenever the reading changes so debug reports can show
/// the full measured history. `kind` is "first" for the first-ever reading, "replacement"
/// when a fresh-battery jump was detected, nil for an ordinary change.
struct BatteryVoltageEvent: JSON, Equatable {
    let value: Double
    let date: Date
    let kind: String?
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
    /// User edits to the per-level time-remaining table. Optional so logs persisted before
    /// this field existed still decode.
    var levelOverrides: [BatteryLevelRemaining]?
    /// Raw reading history (voltage changes, replacement detections), capped, for debugging.
    /// Optional so logs persisted before this field existed still decode.
    var readingHistory: [BatteryVoltageEvent]?
    /// When the current voltage value was first seen (i.e. the moment of the last raw voltage
    /// change). Display/debug info only — the expiration estimate anchors on the lowest
    /// level's first-seen time instead, because raw values bounce with measurement noise.
    /// Optional for backward compatibility.
    var currentValueSince: Date?

    init(
        replacementDate: Date? = nil,
        cycleIsLearnable: Bool = false,
        lastValue: Double? = nil,
        lastValueDate: Date? = nil,
        currentLevelTimes: [BatteryLevelTime] = [],
        completedCycles: [BatteryDischargeCycle] = [],
        currentExpirationDate: Date? = nil,
        levelOverrides: [BatteryLevelRemaining]? = nil,
        readingHistory: [BatteryVoltageEvent]? = nil,
        currentValueSince: Date? = nil
    ) {
        self.replacementDate = replacementDate
        self.cycleIsLearnable = cycleIsLearnable
        self.lastValue = lastValue
        self.lastValueDate = lastValueDate
        self.currentLevelTimes = currentLevelTimes
        self.completedCycles = completedCycles
        self.currentExpirationDate = currentExpirationDate
        self.levelOverrides = levelOverrides
        self.readingHistory = readingHistory
        self.currentValueSince = currentValueSince
    }
}

/// Pure logic for tracking a battery's discharge curve and estimating time remaining.
/// Records a new reading, detects fresh-battery replacements, finalizes learnable cycles, and
/// recomputes the running expiration estimate.
enum BatteryDischargeTracker {
    /// Cap on the raw reading-history debug log.
    static let maxReadingHistory = 1000

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
            // The estimate anchors itself on the lowest level's first-seen time inside
            // `estimatedExpiration`; the value/date here only serve as a fallback anchor.
            log.currentExpirationDate = estimatedExpiration(at: value, from: date, log: log, config: config)
        }

        let priorWasLow = (log.lastValue ?? .greatestFiniteMagnitude) < config.replacementLowThreshold
        let isReplacement = priorWasLow && value >= config.replacementHighThreshold

        // Debug history: keep a timestamped event for the first-ever reading, every detected
        // replacement, and every reading whose value differs from the previous one. The same
        // condition marks a voltage change, which re-anchors the countdown.
        if log.lastValue == nil || isReplacement || value != log.lastValue {
            log.currentValueSince = date
            let kind: String? = log.lastValue == nil ? "first" : (isReplacement ? "replacement" : nil)
            var history = log.readingHistory ?? []
            history.append(BatteryVoltageEvent(value: value, date: date, kind: kind))
            if history.count > maxReadingHistory {
                history.removeFirst(history.count - maxReadingHistory)
            }
            log.readingHistory = history
        }

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
                    log.completedCycles
                        .append(BatteryDischargeCycle(totalLifetime: lifetime, levelOffsets: offsets, startDate: start))
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

    /// Expiration estimate. Uses the effective per-level time-remaining table (learned curve
    /// merged with any user edits) when one exists; otherwise falls back to
    /// `replacementDate + defaultLifetime` (which can produce a negative remaining-time once
    /// elapsed, surfacing as e.g. "P-1d1h" in the UI).
    ///
    /// Anchored at the *lowest voltage level reached this cycle* (its first-seen time), not at
    /// the latest reading or the last raw voltage change: readings bounce by ±0.01–0.02 V
    /// between polls, so any anchor tied to raw value changes gets reset constantly and the
    /// displayed countdown never advances. The lowest-level-first-seen anchor is monotonic
    /// under noise and uses the exact same "first time the reading dipped into this band"
    /// semantics as the learned per-level offsets, so anchor and curve stay comparable. The
    /// expiration is therefore a fixed date between level transitions (a true countdown) and
    /// re-syncs to the learned pace each time a new level is first reached.
    static func estimatedExpiration(
        at value: Double,
        from date: Date,
        log: BatteryDischargeLog,
        config: BatteryDischargeConfig
    ) -> Date? {
        if let table = effectiveRemainingTable(log: log, config: config) {
            let anchor = log.currentLevelTimes.min { $0.level < $1.level }
            let anchorLevel = anchor?.level ?? level(for: value, config: config)
            let anchorDate = anchor?.date ?? date
            let remaining = table[anchorLevel] ?? interpolated(
                forValue: Double(anchorLevel) * config.levelGranularity,
                table: table,
                granularity: config.levelGranularity
            )
            return anchorDate.addingTimeInterval(remaining)
        }
        if let start = log.replacementDate {
            return start.addingTimeInterval(config.defaultLifetime)
        }
        return nil
    }

    /// The per-level time-remaining table currently driving the estimate: the learned averaged
    /// curve with any user overrides applied. When nothing has been learned yet but the user
    /// has made edits, the edits sit on top of the default linear table so interpolation still
    /// has endpoints. Returns `nil` when there's nothing learned and nothing edited — the
    /// caller should use the plain default-lifetime countdown in that case.
    static func effectiveRemainingTable(
        log: BatteryDischargeLog,
        config: BatteryDischargeConfig
    ) -> [Int: TimeInterval]? {
        var table: [Int: TimeInterval]
        if let learned = averagedRemainingTable(log.completedCycles) {
            table = learned
        } else if !(log.levelOverrides ?? []).isEmpty {
            table = defaultRemainingTable(config)
        } else {
            return nil
        }
        for override in log.levelOverrides ?? [] {
            table[override.level] = override.secondsRemaining
        }
        return table
    }

    /// Average time-remaining per level across completed cycles, computed *within each cycle
    /// first* (that cycle's lifetime minus that cycle's offset) and then averaged. Averaging
    /// lifetimes and offsets separately mixes cycle subsets: levels get skipped when the
    /// voltage drops more than one band between readings, and the lowest bands are only
    /// reached in some cycles, so a level recorded only in a short cycle would be measured
    /// against the all-cycle average lifetime and could show MORE time remaining than a
    /// higher voltage. A final sweep clamps the table monotonic (remaining never increases as
    /// voltage drops) so residual subset effects can't invert the display or the estimate.
    static func averagedRemainingTable(_ cycles: [BatteryDischargeCycle]) -> [Int: TimeInterval]? {
        guard !cycles.isEmpty else { return nil }
        var sums: [Int: (total: TimeInterval, count: Int)] = [:]
        for cycle in cycles {
            for offset in cycle.levelOffsets {
                let remaining = max(0, cycle.totalLifetime - offset.secondsFromReplacement)
                let current = sums[offset.level] ?? (0, 0)
                sums[offset.level] = (current.total + remaining, current.count + 1)
            }
        }
        var table = sums.mapValues { $0.total / Double($0.count) }
        var cap = TimeInterval.greatestFiniteMagnitude
        for level in table.keys.sorted(by: >) {
            let clamped = min(table[level] ?? 0, cap)
            table[level] = clamped
            cap = clamped
        }
        return table
    }

    /// Linear default discharge table: fresh voltage → full default lifetime, depleted
    /// voltage → zero. Used as the editable seed before any full cycle has been learned.
    static func defaultRemainingTable(_ config: BatteryDischargeConfig) -> [Int: TimeInterval] {
        let fresh = level(for: config.defaultFreshValue, config: config)
        let depleted = level(for: config.defaultDepletedValue, config: config)
        guard fresh > depleted else { return [fresh: config.defaultLifetime] }
        var table: [Int: TimeInterval] = [:]
        for lvl in depleted ... fresh {
            let fraction = Double(lvl - depleted) / Double(fresh - depleted)
            table[lvl] = config.defaultLifetime * fraction
        }
        return table
    }

    /// Rows for the battery-detail screen: every level from the default range plus any learned
    /// or overridden levels, highest voltage first, each with the time-remaining the estimator
    /// would use at that level.
    static func displayProfile(
        log: BatteryDischargeLog,
        config: BatteryDischargeConfig
    ) -> [BatteryLevelEstimate] {
        let table = effectiveRemainingTable(log: log, config: config) ?? defaultRemainingTable(config)
        let overrideLevels = Set((log.levelOverrides ?? []).map(\.level))
        let levels = Set(table.keys).union(defaultRemainingTable(config).keys).sorted(by: >)
        return levels.map { lvl in
            let remaining = table[lvl] ?? interpolated(
                forValue: Double(lvl) * config.levelGranularity,
                table: table,
                granularity: config.levelGranularity
            )
            return BatteryLevelEstimate(
                level: lvl,
                voltage: Double(lvl) * config.levelGranularity,
                secondsRemaining: remaining,
                isOverridden: overrideLevels.contains(lvl)
            )
        }
    }

    /// Value at a given reading, linearly interpolating between the two nearest table levels.
    /// Clamps outside the table's range.
    static func interpolated(
        forValue value: Double,
        table: [Int: TimeInterval],
        granularity: Double
    ) -> TimeInterval {
        guard !table.isEmpty else { return 0 }
        let levels = table.keys.sorted()
        let scaled = value / granularity
        if let highest = levels.last, scaled >= Double(highest) { return table[highest] ?? 0 }
        if let lowest = levels.first, scaled <= Double(lowest) { return table[lowest] ?? 0 }
        var lower = levels.first!
        var upper = levels.last!
        for lvl in levels {
            if Double(lvl) <= scaled { lower = lvl }
            if Double(lvl) >= scaled { upper = lvl; break }
        }
        guard lower != upper, let low = table[lower], let high = table[upper] else {
            return table[lower] ?? 0
        }
        let fraction = (scaled - Double(lower)) / Double(upper - lower)
        return low + (high - low) * fraction
    }
}

/// One row of the battery-detail discharge table, ready for display.
struct BatteryLevelEstimate: Identifiable {
    var id: Int { level }
    let level: Int
    let voltage: Double
    let secondsRemaining: TimeInterval
    let isOverridden: Bool
}
