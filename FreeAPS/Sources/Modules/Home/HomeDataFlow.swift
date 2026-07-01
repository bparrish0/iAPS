import Foundation
import LoopKitUI

enum Home {
    enum Config {}
}

protocol HomeProvider: Provider {
    var suggestion: Suggestion? { get }
    var enactedSuggestion: Suggestion? { get }
    func heartbeatNow()
    func filteredGlucose(hours: Int) -> [BloodGlucose]
    func pumpHistory(hours: Int) -> [PumpHistoryEvent]
    func pumpSettings() -> PumpSettings
    func autotunedBasalProfile() -> [BasalProfileEntry]
    func basalProfile() -> [BasalProfileEntry]
    func tempTargets(hours: Int) -> [TempTarget]
    func carbs(hours: Int) -> [CarbsEntry]
    func pumpBattery() -> Battery?
    func savePumpBattery(_ battery: Battery)
    func orangeLinkBattery() -> BatteryDischargeLog?
    func batteryLog(for kind: BatteryDeviceKind) -> BatteryDischargeLog?
    func saveBatteryLog(_ log: BatteryDischargeLog, for kind: BatteryDeviceKind)
    func pumpReservoir() -> Decimal?
    func tempTarget() -> TempTarget?
    func announcement(_ hours: Int) -> [Announcement]
    func overrides() -> [Override]
}
