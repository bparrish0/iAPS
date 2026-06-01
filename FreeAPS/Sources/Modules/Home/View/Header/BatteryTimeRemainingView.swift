import SwiftUI

/// Shows estimated time remaining for a battery (or insulin reservoir) as e.g. "2d4h" /
/// "8h20m" / "-1d1h" when overdue. Prefixed by a colored single-letter label so multiple
/// instances on the same screen are distinguishable: "P" pump, "O" OrangeLink, "I" insulin.
struct BatteryTimeRemainingView: View {
    let expirationDate: Date?
    let label: String
    let labelColor: Color
    @Binding var timerDate: Date

    var body: some View {
        if let expirationDate = expirationDate {
            let remaining = expirationDate.timeIntervalSince(timerDate)
            let absRemaining = abs(remaining)
            let days = Int(absRemaining / 86400)
            let hours = Int(absRemaining.truncatingRemainder(dividingBy: 86400) / 3600)
            let minutes = Int(absRemaining.truncatingRemainder(dividingBy: 3600) / 60)
            let overdue = remaining < 0
            let warn = overdue || remaining < 86400

            HStack(spacing: 0) {
                Text(label)
                    .foregroundStyle(labelColor)
                    .fontWeight(.bold)
                if overdue { Text("-") }
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
            .foregroundStyle(warn ? .red : .primary)
        }
    }
}
