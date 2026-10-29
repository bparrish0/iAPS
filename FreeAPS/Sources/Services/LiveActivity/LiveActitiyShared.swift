import ActivityKit
import Foundation

struct LiveActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        let bg: String
        let direction: String?
        let change: String
        let date: Date
        let iob: String
        let cob: String
        let loopDate: Date
        let eventual: String
        let mmol: Bool
        let readings: ValueSeries?
        let predictions: ActivityPredictions?
        let showChart: Bool
        let chartLowThreshold: Int16
        let chartHighThreshold: Int16
        var bolusDelivered: Double? = nil
        var bolusUpdatedAt: Date? = nil

        var bolusDeliveryLabel: String? {
            guard let bolusDelivered, bolusDelivered.isFinite, bolusDelivered >= 0 else { return nil }
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            // Never round up to insulin that has not yet been delivered.
            formatter.roundingMode = .down
            return formatter.string(from: NSNumber(value: bolusDelivered))
        }

        func withBolusDelivery(_ units: Double?, updatedAt: Date?) -> ContentState {
            var copy = self
            copy.bolusDelivered = units
            copy.bolusUpdatedAt = updatedAt
            return copy
        }

        func withoutPredictions() -> ContentState {
            ContentState(
                bg: bg,
                direction: direction,
                change: change,
                date: date,
                iob: iob,
                cob: cob,
                loopDate: loopDate,
                eventual: eventual,
                mmol: mmol,
                readings: readings,
                predictions: nil,
                showChart: showChart,
                chartLowThreshold: chartLowThreshold,
                chartHighThreshold: chartHighThreshold,
                bolusDelivered: bolusDelivered,
                bolusUpdatedAt: bolusUpdatedAt
            )
        }
    }

    struct ValueSeries: Codable, Hashable {
        let dates: [Date]
        let values: [Int16]
    }

    struct ActivityPredictions: Codable, Hashable {
        let iob: ValueSeries?
        let zt: ValueSeries?
        let cob: ValueSeries?
        let uam: ValueSeries?
    }

    let startDate: Date
}
