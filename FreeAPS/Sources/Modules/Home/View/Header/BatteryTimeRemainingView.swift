import SwiftUI

/// Shows estimated battery time remaining (e.g. "2d4h" or "8h20m" under a day) prefixed by a
/// colored single-letter label. Used for both the pump battery ("P") and the OrangeLink ("O").
struct BatteryTimeRemainingView: View {
    let expirationDate: Date?
    let label: String
    let labelColor: Color
    @Binding var timerDate: Date

    var body: some View {
        if let expirationDate = expirationDate {
            let remaining = expirationDate.timeIntervalSince(timerDate)
            if remaining > 0 {
                let days = Int(remaining / 86400)
                let hours = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)
                let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)

                HStack(spacing: 0) {
                    Text(label)
                        .foregroundStyle(labelColor)
                        .fontWeight(.bold)
                    if days >= 1 {
                        Text("\(days)")
                        Text("d").foregroundStyle(.secondary)
                        Text("\(hours)")
                        Text("h").foregroundStyle(.secondary)
                    } else {
                        Text("\(hours)")
                        Text("h").foregroundStyle(.secondary)
                        Text("\(minutes)")
                        Text("m").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(remaining < 86400 ? .red : .primary)
            }
        }
    }
}
