import SwiftUI

extension Home {
    /// Detail sheet for one battery (pump or OrangeLink): current voltage, the per-voltage
    /// time-remaining table driving the estimate, and the history of completed battery
    /// sessions — tap a session to correct when it actually ended (e.g. the pump died hours
    /// before the swap), swipe to delete an outlier.
    struct BatteryDetailView: View {
        let kind: BatteryDeviceKind
        @ObservedObject var state: StateModel

        /// A completed cycle staged for editing, addressed by its index in the stored array.
        private struct CycleEditTarget: Identifiable {
            let id: Int
            let cycle: BatteryDischargeCycle
        }

        @State private var editingCycle: CycleEditTarget?

        private enum DebugEmailStatus: Equatable {
            case idle
            case sending
            case result(String)
        }

        @State private var debugEmailStatus: DebugEmailStatus = .idle

        private var log: BatteryDischargeLog {
            state.batteryDetailLog ?? BatteryDischargeLog()
        }

        private var profileRows: [BatteryLevelEstimate] {
            BatteryDischargeTracker.displayProfile(log: log, config: kind.config)
        }

        /// Completed cycles newest-first, keeping each row's index into the stored array so
        /// edits and deletion target the right cycle.
        private var historyRows: [(originalIndex: Int, cycle: BatteryDischargeCycle)] {
            log.completedCycles.enumerated().map { ($0.offset, $0.element) }.reversed()
        }

        var body: some View {
            NavigationView {
                Form {
                    currentSection
                    profileSection
                    historySection
                    debugSection
                }
                .navigationTitle(kind.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { state.batteryDetailKind = nil }
                    }
                }
                .sheet(item: $editingCycle) { target in
                    BatteryCycleEditView(
                        cycle: target.cycle,
                        onSaveEnd: { endDate in
                            state.setBatteryCycleEnd(kind: kind, at: target.id, endDate: endDate)
                        },
                        onSaveLifetime: { lifetime in
                            state.setBatteryCycleLifetime(kind: kind, at: target.id, lifetime: lifetime)
                        }
                    )
                }
            }
        }

        private var currentSection: some View {
            Section(header: Text("Current")) {
                HStack {
                    Text("Voltage")
                    Spacer()
                    Text(log.lastValue.map { voltageString($0) } ?? "—")
                        .foregroundStyle(.secondary)
                }
                if let lastDate = log.lastValueDate {
                    HStack {
                        Text("Last pump contact")
                        Spacer()
                        Text(relativeString(lastDate)).foregroundStyle(.secondary)
                    }
                }
                if let since = log.currentValueSince {
                    HStack {
                        Text("At this voltage since")
                        Spacer()
                        Text(relativeString(since)).foregroundStyle(.secondary)
                    }
                }
                if let replaced = log.replacementDate {
                    HStack {
                        Text(log.cycleIsLearnable ? "Installed" : "Tracking since")
                        Spacer()
                        Text(dateFormatter.string(from: replaced)).foregroundStyle(.secondary)
                    }
                }
                if let expiration = log.currentExpirationDate {
                    HStack {
                        Text("Estimated empty")
                        Spacer()
                        Text(
                            dateFormatter.string(from: expiration) + " (" +
                                durationString(expiration.timeIntervalSinceNow) + ")"
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Estimate source")
                    Spacer()
                    Text(estimateSource).foregroundStyle(.secondary)
                }
            }
        }

        private var estimateSource: String {
            if log.completedCycles.isEmpty {
                return log.cycleIsLearnable
                    ? NSLocalizedString("Default curve (learning this session)", comment: "Battery estimate source")
                    : NSLocalizedString("Default curve", comment: "Battery estimate source")
            }
            return String(
                format: NSLocalizedString("Learned from %d session(s)", comment: "Battery estimate source"),
                log.completedCycles.count
            )
        }

        private var profileSection: some View {
            Section(
                header: Text("Time remaining at each voltage"),
                footer: Text("Learned from completed sessions. To correct it, edit or delete sessions below.")
            ) {
                ForEach(profileRows) { row in
                    HStack {
                        Text(voltageString(row.voltage))
                        Spacer()
                        Text(durationString(row.secondsRemaining)).foregroundStyle(.secondary)
                    }
                }
            }
        }

        private var historySection: some View {
            Section(
                header: Text("Battery History"),
                footer: Text(
                    log.completedCycles.isEmpty
                        ? "Each fully used battery is recorded here and averaged into the estimate."
                        : "Tap a session to correct when it actually ended — e.g. when the loop lost contact with the pump. Swipe to delete an outlier."
                )
            ) {
                if historyRows.isEmpty {
                    Text("No completed sessions yet").foregroundStyle(.secondary)
                } else {
                    ForEach(historyRows, id: \.originalIndex) { row in
                        Button {
                            editingCycle = CycleEditTarget(id: row.originalIndex, cycle: row.cycle)
                        } label: {
                            HStack {
                                Text(sessionDatesString(row.cycle)).foregroundStyle(.primary)
                                Spacer()
                                Text(durationString(row.cycle.totalLifetime)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { indexSet in
                        let rows = historyRows
                        for index in indexSet {
                            state.deleteBatteryCycle(kind: kind, at: rows[index].originalIndex)
                        }
                    }
                }
            }
        }

        private var debugSection: some View {
            Section(
                header: Text("Debugging"),
                footer: Text(
                    "Emails the full tracking logs for both batteries — sessions, per-level timestamps, raw voltage readings, and replacement detections — to the developer."
                )
            ) {
                Button {
                    debugEmailStatus = .sending
                    Task {
                        let result = await state.sendBatteryDebugEmail(for: kind)
                        debugEmailStatus = .result(result)
                    }
                } label: {
                    HStack {
                        Text("Send Debug Email")
                        Spacer()
                        switch debugEmailStatus {
                        case .idle:
                            EmptyView()
                        case .sending:
                            ProgressView()
                        case let .result(text):
                            Text(text).foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(debugEmailStatus == .sending)
            }
        }

        private func sessionDatesString(_ cycle: BatteryDischargeCycle) -> String {
            guard let start = cycle.startDate, let end = cycle.endDate else {
                return NSLocalizedString("Session", comment: "Battery session without a date")
            }
            return dateFormatter.string(from: start) + " – " + dateFormatter.string(from: end)
        }

        private func voltageString(_ value: Double) -> String {
            String(format: "%.\(kind.voltageFractionDigits)f V", value)
        }

        private func durationString(_ interval: TimeInterval) -> String {
            let absInterval = abs(interval)
            let days = Int(absInterval / 86400)
            let hours = Int(absInterval.truncatingRemainder(dividingBy: 86400) / 3600)
            let minutes = Int(absInterval.truncatingRemainder(dividingBy: 3600) / 60)
            let sign = interval < 0 ? "-" : ""
            return days >= 1 ? "\(sign)\(days)d \(hours)h" : "\(sign)\(hours)h \(minutes)m"
        }

        private func relativeString(_ date: Date) -> String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }

        private var dateFormatter: DateFormatter {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }
    }
}

/// Editor for one completed battery session. Sessions with a known start date get a date/time
/// picker for the true end (runtime follows); legacy sessions without one edit the total
/// runtime directly with day/hour wheels.
struct BatteryCycleEditView: View {
    let cycle: BatteryDischargeCycle
    let onSaveEnd: (Date) -> Void
    let onSaveLifetime: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var endDate: Date
    @State private var days: Int
    @State private var hours: Int

    init(
        cycle: BatteryDischargeCycle,
        onSaveEnd: @escaping (Date) -> Void,
        onSaveLifetime: @escaping (TimeInterval) -> Void
    ) {
        self.cycle = cycle
        self.onSaveEnd = onSaveEnd
        self.onSaveLifetime = onSaveLifetime
        _endDate = State(initialValue: cycle.endDate ?? Date())
        let clamped = max(0, cycle.totalLifetime)
        _days = State(initialValue: Int(clamped / 86400))
        _hours = State(initialValue: Int(clamped.truncatingRemainder(dividingBy: 86400) / 3600))
    }

    private var newLifetime: TimeInterval {
        if let start = cycle.startDate {
            return endDate.timeIntervalSince(start)
        }
        return TimeInterval(days * 86400 + hours * 3600)
    }

    var body: some View {
        NavigationView {
            Form {
                if let start = cycle.startDate {
                    Section(
                        footer: Text(
                            "Set when this battery actually died — e.g. when the loop last talked to the pump — so dead time before the swap doesn't count as runtime."
                        )
                    ) {
                        HStack {
                            Text("Started")
                            Spacer()
                            Text(start.formatted(date: .abbreviated, time: .shortened))
                                .foregroundStyle(.secondary)
                        }
                        DatePicker(
                            "Ended",
                            selection: $endDate,
                            in: start.addingTimeInterval(60) ... Date(),
                            displayedComponents: [.date, .hourAndMinute]
                        )
                        HStack {
                            Text("Runtime")
                            Spacer()
                            Text(durationString(newLifetime)).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Section(
                        header: Text("Total runtime"),
                        footer: Text("This session predates start-date tracking, so only its total runtime can be corrected.")
                    ) {
                        HStack(spacing: 0) {
                            Picker("Days", selection: $days) {
                                ForEach(0 ..< 91, id: \.self) { Text("\($0)d") }
                            }
                            .pickerStyle(.wheel)
                            .frame(maxWidth: .infinity)
                            .clipped()
                            Picker("Hours", selection: $hours) {
                                ForEach(0 ..< 24, id: \.self) { Text("\($0)h") }
                            }
                            .pickerStyle(.wheel)
                            .frame(maxWidth: .infinity)
                            .clipped()
                        }
                    }
                }
            }
            .navigationTitle("Battery Session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if cycle.startDate != nil {
                            onSaveEnd(endDate)
                        } else {
                            onSaveLifetime(TimeInterval(days * 86400 + hours * 3600))
                        }
                        dismiss()
                    }
                    .disabled(newLifetime <= 0)
                }
            }
        }
    }

    private func durationString(_ interval: TimeInterval) -> String {
        let absInterval = abs(interval)
        let days = Int(absInterval / 86400)
        let hours = Int(absInterval.truncatingRemainder(dividingBy: 86400) / 3600)
        let minutes = Int(absInterval.truncatingRemainder(dividingBy: 3600) / 60)
        let sign = interval < 0 ? "-" : ""
        return days >= 1 ? "\(sign)\(days)d \(hours)h" : "\(sign)\(hours)h \(minutes)m"
    }
}
