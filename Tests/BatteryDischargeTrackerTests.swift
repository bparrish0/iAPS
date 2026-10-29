// Synthetic regression data only. An optional local JSON argument can replay a private
// debug report; no patient readings belong in the repository or CI fixtures.
private let start = Date(timeIntervalSince1970: 1_700_000_000)
private let hour: TimeInterval = 3600
private let day: TimeInterval = 86400

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

private func startupLog() -> BatteryDischargeLog {
    BatteryDischargeLog(
        replacementDate: start,
        cycleIsLearnable: true,
        lastValue: 1.60,
        lastValueDate: start.addingTimeInterval(3 * hour),
        currentLevelTimes: [
            BatteryLevelTime(level: 32, date: start),
            BatteryLevelTime(level: 31, date: start.addingTimeInterval(0.25 * hour)),
            BatteryLevelTime(level: 30, date: start.addingTimeInterval(hour))
        ],
        completedCycles: [BatteryDischargeCycle(totalLifetime: 15 * day, levelOffsets: [
            BatteryLevelOffset(level: 32, secondsFromReplacement: 0),
            BatteryLevelOffset(level: 31, secondsFromReplacement: hour),
            BatteryLevelOffset(level: 30, secondsFromReplacement: 7 * day)
        ], startDate: start.addingTimeInterval(-16 * day))],
        readingHistory: [
            BatteryVoltageEvent(value: 1.63, date: start, kind: "replacement"),
            BatteryVoltageEvent(value: 1.57, date: start.addingTimeInterval(0.25 * hour), kind: nil),
            BatteryVoltageEvent(value: 1.50, date: start.addingTimeInterval(hour), kind: nil),
            BatteryVoltageEvent(value: 1.59, date: start.addingTimeInterval(2 * hour), kind: nil),
            BatteryVoltageEvent(value: 1.60, date: start.addingTimeInterval(3 * hour), kind: nil)
        ],
        recentRawValues: [1.60, 1.60, 1.60],
        lastSmoothedValue: 1.60,
        smoothingMigrationDone: true,
        lowSeenThisCycle: false
    )
}

private func hasDip(_ log: BatteryDischargeLog) -> Bool {
    log.currentLevelTimes.contains { $0.level == 30 }
}

var recovered = startupLog()
let learned = recovered.completedCycles
let history = recovered.readingHistory
BatteryDischargeTracker.record(value: 1.60, at: start.addingTimeInterval(3 * hour), into: &recovered, config: .pump)
require(!hasDip(recovered), "Persisted startup dip was not repaired")
require(recovered.completedCycles == learned, "Learned cycles changed")
require(recovered.readingHistory == history, "Raw history changed")
require(recovered.replacementDate == start, "Replacement date changed")
let expiration = recovered.currentExpirationDate
require(expiration == start.addingTimeInterval(15 * day - 0.75 * hour), "Fresh estimate did not recover")
BatteryDischargeTracker.record(value: 1.60, at: start.addingTimeInterval(4 * hour), into: &recovered, config: .pump)
require(recovered.currentExpirationDate == expiration, "Repeated high readings extended the countdown")
for i in 0 ..< 3 {
    BatteryDischargeTracker.record(value: 1.50, at: start.addingTimeInterval(7 * day + Double(i) * 300), into: &recovered, config: .pump)
}
require(hasDip(recovered), "Genuine later discharge was ignored")
require(recovered.currentLevelTimes.first { $0.level == 30 }!.date >= start.addingTimeInterval(7 * day), "Later crossing reused the bad date")

for scenario in ["briefRecovery", "stillLow", "longDip", "lateCrossing", "genuinelyLow", "missingHistory", "partialHistory", "syntheticCycle", "orangeLink"] {
    var log = startupLog()
    var date = start.addingTimeInterval(3 * hour)
    var smoothed = 1.60
    var config = BatteryDischargeConfig.pump
    switch scenario {
    case "briefRecovery": date = start.addingTimeInterval(2.5 * hour)
    case "stillLow": smoothed = 1.50
    case "longDip": log.readingHistory = Array(log.readingHistory!.prefix(3)) + [BatteryVoltageEvent(value: 1.60, date: start.addingTimeInterval(4 * hour), kind: nil)]; date = start.addingTimeInterval(5 * hour)
    case "lateCrossing":
        log.currentLevelTimes[2] = BatteryLevelTime(level: 30, date: start.addingTimeInterval(7 * day))
        log.readingHistory = [BatteryVoltageEvent(value: 1.50, date: start.addingTimeInterval(7 * day), kind: nil), BatteryVoltageEvent(value: 1.60, date: start.addingTimeInterval(7 * day + hour), kind: nil)]
        date = start.addingTimeInterval(7 * day + 2 * hour)
    case "genuinelyLow": log.lowSeenThisCycle = true
    case "missingHistory": log.readingHistory = nil
    case "partialHistory": log.readingHistory = Array(log.readingHistory!.suffix(2))
    case "syntheticCycle": log.cycleIsLearnable = false
    case "orangeLink": config = .orangeLink
    default: break
    }
    BatteryDischargeTracker.repairRecoveredStartupDip(&log, smoothed: smoothed, at: date, config: config)
    require(hasDip(log), "Unsafe dip removal: \(scenario)")
}

var swap = startupLog()
swap.lastValue = 1.20
swap.lastValueDate = start.addingTimeInterval(15 * day)
swap.lastLowValueDate = swap.lastValueDate
swap.lastSmoothedValue = 1.20
swap.recentRawValues = [1.20, 1.20, 1.20]
swap.lowSeenThisCycle = true
let installed = start.addingTimeInterval(15 * day + hour)
for (i, value) in [1.54, 1.56, 1.57].enumerated() {
    BatteryDischargeTracker.record(value: value, at: installed.addingTimeInterval(Double(i) * 300), into: &swap, config: .pump)
}
require(swap.replacementDate == installed, "Dead-zone replacement regressed")
require(swap.completedCycles.count == learned.count + 1, "Replacement cycle was not finalized once")
require(swap.completedCycles.last!.totalLifetime == 15 * day, "Dead gap counted as battery runtime")

if CommandLine.arguments.count > 1 {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    var log = try decoder.decode(BatteryDischargeLog.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
    let cycles = log.completedCycles
    let rawHistory = log.readingHistory
    let oldExpiration = log.currentExpirationDate!
    BatteryDischargeTracker.record(value: log.lastValue!, at: log.lastValueDate!.addingTimeInterval(300), into: &log, config: .pump)
    require(!hasDip(log), "Private report still has startup dip")
    require(log.completedCycles == cycles && log.readingHistory == rawHistory, "Private report history changed")
    require(log.currentExpirationDate!.timeIntervalSince(oldExpiration) > 6 * day, "Private report estimate was not corrected")
    print("PASS: private persisted-state replay; learned cycles and raw history preserved")
}
print("PASS: startup recovery, stable countdown, later discharge, nine exclusion cases, and replacement detection")
