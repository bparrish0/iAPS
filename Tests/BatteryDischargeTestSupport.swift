import Foundation

// Compile the production tracker without the app's storage and UI dependencies.
protocol JSON: Codable {}
enum OpenAPS {
    enum Monitor {
        static let pumpBatteryLog = "pump"
        static let orangeLinkBattery = "orangeLink"
    }
}
