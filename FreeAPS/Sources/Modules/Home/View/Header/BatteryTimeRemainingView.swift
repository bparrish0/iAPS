import SwiftUI

struct BatteryTimeRemainingView: View {
    @Binding var battery: Battery?
    @Binding var timerDate: Date

    var body: some View {
        if let expirationDate = battery?.batteryExpirationDate {
            let remaining = expirationDate.timeIntervalSince(timerDate)
            if remaining > 0 {
                let days = Int(remaining / 86400)
                let hours = Int(remaining.truncatingRemainder(dividingBy: 86400) / 3600)
                let minutes = Int(remaining.truncatingRemainder(dividingBy: 3600) / 60)

                HStack(spacing: 0) {
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
