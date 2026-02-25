import SwiftUI

struct OrangeLinkVoltageView: View {
    @Binding var voltage: Float?

    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        if let voltage = voltage {
            VStack(spacing: 1) {
                // Hinge notch at top
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.gray.opacity(0.6))
                    .frame(width: 10, height: 3)

                // Main body
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.orange)
                        .frame(width: 28, height: 24)
                        .shadow(radius: 1, x: 1, y: 1)

                    // Voltage text
                    Text(String(format: "%.1f", voltage))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .offset(y: -1)

                    // LED dot
                    Circle()
                        .fill(ledColor(for: voltage))
                        .frame(width: 4, height: 4)
                        .offset(x: 9, y: -8)
                        .shadow(color: ledColor(for: voltage).opacity(0.8), radius: 2)
                }
            }
            .frame(width: 28, height: 30)
        }
    }

    private func ledColor(for voltage: Float) -> Color {
        if voltage > 3.2 {
            return .green
        } else if voltage > 3.0 {
            return .yellow
        } else {
            return .red
        }
    }
}
