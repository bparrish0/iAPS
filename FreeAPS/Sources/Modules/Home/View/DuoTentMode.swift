import SwiftUI
import UIKit

// The cover display can report status "closed" at a real 60-degree fold.
// Prefer the measured hinge angle over that coarse, display-specific status.
struct DuoTentPosture: Equatable {
    enum Hinge: Equatable { case unavailable, closed, partial, open }
    var hinge: Hinge = .unavailable
    var orientation: UIDeviceOrientation = .unknown
    var interfaceOrientation: UIInterfaceOrientation = .unknown
    var hingeAngleDegrees: Double?
    var windowBounds: CGRect = .zero

    var isSideways: Bool { interfaceOrientation.isLandscape || orientation.isLandscape }

    var suggestsTent: Bool {
        guard hinge != .unavailable,
              isSideways || interfaceOrientation == .portraitUpsideDown || orientation == .portraitUpsideDown
        else { return false }
        if let angle = hingeAngleDegrees {
            guard angle.isFinite else { return false }
            // Ignore a nearly shut or nearly flat device. This works on the
            // cover display even when its coarse status remains "closed".
            return angle > 10 && angle < 170
        }
        return hinge == .partial
    }

    func isActive(mode: Int) -> Bool {
        // Landscape always uses the large-glucose display, even with tent
        // detection disabled or with the Duo folded shut or fully open.
        if isSideways { return true }
        switch mode {
        case 1: return false
        case 2: return true
        default: return suggestsTent
        }
    }

    func shouldKeepScreenAwake(batteryLevel: Float, isAppActive: Bool) -> Bool {
        suggestsTent && isAppActive && batteryLevel.isFinite && batteryLevel >= 0.30 && batteryLevel <= 1
    }
}

struct TentModeSettings: View {
    @AppStorage("DuoTent.mode") private var mode = 0

    var body: some View {
        Section {
            Picker("Tent mode", selection: $mode) {
                Text("Automatic").tag(0)
                Text("Off").tag(1)
                Text("On").tag(2)
            }
        } header: {
            Text("Tent mode")
        } footer: {
            Text("Holding the phone horizontally always shows large glucose. Automatic also uses the Duo’s hinge angle to recognize tent posture. On keeps large glucose active in portrait; Off disables automatic tent detection.")
            Text("In physical tent posture, iAPS keeps the screen awake while the app is open and the phone battery is at least 30%. Below 30%, normal screen sleep resumes.")
        }
    }
}

struct DuoPostureObserver: UIViewRepresentable {
    var onChange: (DuoTentPosture) -> Void

    func makeUIView(context: Context) -> SensorView {
        let view = SensorView()
        view.onChange = onChange
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: SensorView, context: Context) { uiView.onChange = onChange }

    static func dismantleUIView(_ uiView: SensorView, coordinator: ()) { uiView.stop() }

    final class SensorView: UIView {
        var onChange: ((DuoTentPosture) -> Void)?
        private var posture = DuoTentPosture()
        private var hingeInteraction: UIInteraction?
        private weak var hingeHost: UIView?
        private var lastDiagnostic: [String: String] = [:]
        private var orientationObserver: NSObjectProtocol?
        private var foregroundObserver: NSObjectProtocol?
        private var observing = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { stop(); return }
            guard !observing else { return }
            observing = true
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            updateOrientation()
            orientationObserver = Foundation.NotificationCenter.default.addObserver(
                forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.updateOrientation() }
            foregroundObserver = Foundation.NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.updateOrientation()
                // Re-enabling requests the current hinge state, including folds
                // that happened while the app was suspended.
                if #available(iOS 27.1, *), let interaction = self.hingeInteraction as? UIHingeInteraction {
                    interaction.isEnabled = false
                    interaction.isEnabled = true
                }
            }
            if #available(iOS 27.1, *) {
                let interaction = UIHingeInteraction { [weak self] _, update in
                    guard let self else { return }
                    self.posture.hingeAngleDegrees = update.hinge.map { Double($0.angle) * 180 / .pi }
                    switch update.hinge?.status {
                    case .closed: self.posture.hinge = .closed
                    case .partiallyOpen: self.posture.hinge = .partial
                    case .fullyOpen: self.posture.hinge = .open
                    default: self.posture.hinge = .unavailable
                    }
                    self.publish()
                }
                // Observe the visible root, not the representable's otherwise
                // empty background. Hinge updates belong to a view hierarchy.
                let host = window?.rootViewController?.view ?? window ?? self
                hingeHost = host
                hingeInteraction = interaction
                host.addInteraction(interaction)
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if observing { updateOrientation() }
        }

        private func updateOrientation() {
            posture.windowBounds = window?.bounds ?? .zero
            posture.interfaceOrientation = window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .unknown
            let orientation = UIDevice.current.orientation
            // Ignore transient face-up/unknown samples so the layout does not
            // flicker while the user adjusts the tent angle.
            if orientation.isValidInterfaceOrientation { posture.orientation = orientation }
            publish()
        }

        private func publish() {
            // Keep a bounded, device-only trace so failed automatic detection
            // can be diagnosed without collecting glucose or therapy data.
            let diagnostic = [
                "hinge": String(describing: posture.hinge),
                "hingeAngleDegrees": posture.hingeAngleDegrees.map { String(format: "%.1f", $0) } ?? "unknown",
                "deviceOrientation": String(posture.orientation.rawValue),
                "interfaceOrientation": String(posture.interfaceOrientation.rawValue),
                "hingeHost": hingeHost.map { String(describing: type(of: $0)) } ?? "none",
                "automaticCandidate": String(posture.suggestsTent)
            ]
            if diagnostic != lastDiagnostic {
                lastDiagnostic = diagnostic
                var trace = UserDefaults.standard.array(forKey: "DuoTent.detectionTrace") as? [[String: String]] ?? []
                var entry = diagnostic
                entry["date"] = ISO8601DateFormatter().string(from: Date())
                trace.append(entry)
                UserDefaults.standard.set(Array(trace.suffix(32)), forKey: "DuoTent.detectionTrace")
            }
            let value = posture
            DispatchQueue.main.async { [weak self] in
                guard let self, self.observing else { return }
                self.onChange?(value)
            }
        }

        func stop() {
            guard observing else { return }
            observing = false
            if let orientationObserver { Foundation.NotificationCenter.default.removeObserver(orientationObserver) }
            orientationObserver = nil
            if let foregroundObserver { Foundation.NotificationCenter.default.removeObserver(foregroundObserver) }
            foregroundObserver = nil
            if let hingeInteraction { hingeHost?.removeInteraction(hingeInteraction) }
            hingeInteraction = nil
            hingeHost = nil
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
    }
}

struct TentScreenAwake: View {
    var posture: DuoTentPosture
    var isAppActive: Bool
    @State private var batteryLevel = UIDevice.current.batteryLevel

    private func refreshBatteryLevel() {
        batteryLevel = UIDevice.current.batteryLevel
    }

    var body: some View {
        TentIdleTimerControl(enabled: posture.shouldKeepScreenAwake(batteryLevel: batteryLevel, isAppActive: isAppActive))
            .onAppear { refreshBatteryLevel() }
            .onReceive(Foundation.NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in
                refreshBatteryLevel()
            }
            .onReceive(Foundation.NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                refreshBatteryLevel()
            }
    }
}

private struct TentIdleTimerControl: UIViewRepresentable {
    var enabled: Bool
    func makeUIView(context: Context) -> AwakeView { AwakeView() }
    func updateUIView(_ uiView: AwakeView, context: Context) { uiView.setEnabled(enabled) }
    static func dismantleUIView(_ uiView: AwakeView, coordinator: ()) { uiView.setEnabled(false) }

    final class AwakeView: UIView {
        private var previousValue: Bool?
        func setEnabled(_ enabled: Bool) {
            if enabled {
                guard previousValue == nil else { return }
                previousValue = UIApplication.shared.isIdleTimerDisabled
                UIApplication.shared.isIdleTimerDisabled = true
            } else if let previousValue {
                UIApplication.shared.isIdleTimerDisabled = previousValue
                self.previousValue = nil
            }
        }
    }
}

struct TentGlucoseView: View {
    @ObservedObject var data: ChartModel
    var recentGlucose: BloodGlucose?
    var inspectedGlucose: BloodGlucose?
    var delta: Int?
    var fontSize: CGFloat

    private var reading: BloodGlucose? { inspectedGlucose ?? recentGlucose }
    private var value: Decimal? {
        guard let reading else { return nil }
        if inspectedGlucose == nil, let unfiltered = reading.unfiltered { return unfiltered }
        return reading.glucose.map { Decimal($0) }
    }
    private var stale: Bool {
        guard let reading else { return false }
        return inspectedGlucose == nil && data.timerDate.timeIntervalSince(reading.dateString) > 12 * 60
    }
    private var color: Color {
        guard let value, data.lowGlucose < data.highGlucose else { return .primary }
        if value < data.lowGlucose { return .loopRed }
        if value >= data.highGlucose { return .loopYellow }
        return .loopGreen
    }
    private func format(_ value: Decimal, signed: Bool = false) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = data.units == .mmolL ? 1 : 0
        formatter.minimumFractionDigits = data.units == .mmolL ? 1 : 0
        if signed { formatter.positivePrefix = "+" }
        return formatter.string(from: (data.units == .mmolL ? value.asMmolL : value) as NSNumber) ?? "--"
    }
    private var readingTime: String {
        guard let reading else { return "No glucose reading" }
        if inspectedGlucose != nil { return reading.dateString.formatted(date: .omitted, time: .shortened) }
        let age = max(0, Int(data.timerDate.timeIntervalSince(reading.dateString) / 60))
        return age < 1 ? "Now" : "\(age) min ago"
    }

    var body: some View {
        VStack(spacing: 1) {
            Text(value.map { format($0) } ?? "--")
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .strikethrough(stale)
                .minimumScaleFactor(0.4)
                .lineLimit(1)
                .accessibilityLabel("Glucose, \(data.units.rawValue)")
                .overlay(alignment: .trailing) {
                    if let direction = reading?.direction {
                        Text(direction.symbol)
                            .font(.system(size: fontSize * 0.28, weight: .semibold))
                            .fixedSize()
                            .offset(x: fontSize * 0.38)
                            .accessibilityLabel(direction.rawValue)
                    }
                }
                .foregroundStyle(color)
                .padding(.bottom, -12)
            if inspectedGlucose == nil, let delta {
                Text(format(Decimal(delta), signed: true))
                    .font(.system(size: 28, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.bottom, -5)
            }
            Text(readingTime)
                .font(.system(size: 22, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(stale ? Color.orange : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

// Uses the app's existing UIDevice battery monitoring and change notifications;
// no polling or extra background work is needed for the tent display.
struct TentPhoneBatteryView: View {
    var compact = false
    @State private var level = UIDevice.current.batteryLevel

    private var percentage: Int? {
        level >= 0 ? Int((level * 100).rounded()) : nil
    }
    private func refresh() {
        level = UIDevice.current.batteryLevel
    }

    var body: some View {
        Text(percentage.map { "\($0)%" } ?? "—%")
            .monospacedDigit()
        .font(.system(size: compact ? 24 : 28, weight: .semibold))
        .fixedSize()
        .foregroundStyle(percentage.map { $0 <= 20 } == true ? Color.red : Color.white)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Phone battery")
        .accessibilityValue(percentage.map { "\($0) percent" } ?? "Unavailable")
        .onAppear { refresh() }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in refresh() }
        .onReceive(Foundation.NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refresh() }
    }
}

// Share measured positions between the tent header and action column so the
// chart starts at the toolbar's top in every window size and orientation.
struct TentLayoutFramesKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct TentIOBView: View {
    @ObservedObject var data: ChartModel

    private var valueText: String {
        guard let iob = data.iob else { return "--" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter.string(from: iob as NSNumber) ?? "--"
    }

    var body: some View {
        Text("IOB \(valueText) U")
            .font(.system(size: 20, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.insulin)
            .fixedSize()
            .accessibilityLabel("Insulin on board")
            .accessibilityValue(data.iob == nil ? "Unavailable" : "\(valueText) units")
    }
}
