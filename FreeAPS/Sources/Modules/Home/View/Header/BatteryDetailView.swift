import SwiftUI

extension Home {
    /// Detail sheet for one battery (pump or OrangeLink): current voltage, the editable
    /// per-voltage time-remaining table driving the estimate, and the history of completed
    /// battery sessions (deletable, so outliers can be dropped from the learned average).
    struct BatteryDetailView: View {
        let kind: BatteryDeviceKind
        @ObservedObject var state: StateModel

        @State private var editingRow: BatteryLevelEstimate?

        private var log: BatteryDischargeLog {
            state.batteryDetailLog ?? BatteryDischargeLog()
        }

        private var profileRows: [BatteryLevelEstimate] {
            BatteryDischargeTracker.displayProfile(log: log, config: kind.config)
        }

        /// Completed cycles newest-first, keeping each row's index into the stored array so
        /// deletion targets the right cycle.
        private var historyRows: [(originalIndex: Int, cycle: BatteryDischargeCycle)] {
            log.completedCycles.enumerated().map { ($0.offset, $0.element) }.reversed()
        }

        var body: some View {
            NavigationView {
                Form {
                    currentSection
                    profileSection
                    historySection
                }
                .navigationTitle(kind.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { state.batteryDetailKind = nil }
                    }
                }
                .sheet(item: $editingRow) { row in
                    BatteryLevelEditView(
                        voltageLabel: voltageString(row.voltage),
                        initialSeconds: row.secondsRemaining,
                        isOverridden: row.isOverridden,
                        onSave: { seconds in
                            state.setBatteryLevelOverride(
                                kind: kind,
                                level: row.level,
                                secondsRemaining: seconds
                            )
                        },
                        onReset: {
                            state.setBatteryLevelOverride(kind: kind, level: row.level, secondsRemaining: nil)
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
                        Text("Last reading")
                        Spacer()
                        Text(relativeString(lastDate)).foregroundStyle(.secondary)
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
            var source: String
            if log.completedCycles.isEmpty {
                source = NSLocalizedString("Default curve", comment: "Battery estimate source")
            } else {
                source = String(
                    format: NSLocalizedString("Learned from %d session(s)", comment: "Battery estimate source"),
                    log.completedCycles.count
                )
            }
            if !(log.levelOverrides ?? []).isEmpty {
                source += NSLocalizedString(", edited", comment: "Battery estimate source suffix")
            }
            return source
        }

        private var profileSection: some View {
            Section(
                header: Text("Time remaining at each voltage"),
                footer: Text("Tap a level to edit its time remaining. Edited levels override the learned curve.")
            ) {
                ForEach(profileRows) { row in
                    Button {
                        editingRow = row
                    } label: {
                        HStack {
                            Text(voltageString(row.voltage)).foregroundStyle(.primary)
                            Spacer()
                            Text(durationString(row.secondsRemaining))
                                .foregroundStyle(row.isOverridden ? Color.accentColor : .secondary)
                                .italic(row.isOverridden)
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        if row.isOverridden {
                            Button("Reset") {
                                state.setBatteryLevelOverride(kind: kind, level: row.level, secondsRemaining: nil)
                            }
                            .tint(.orange)
                        }
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
                        : "Swipe to delete an outlier session so it no longer skews the average."
                )
            ) {
                if historyRows.isEmpty {
                    Text("No completed sessions yet").foregroundStyle(.secondary)
                } else {
                    ForEach(historyRows, id: \.originalIndex) { row in
                        HStack {
                            Text(sessionDatesString(row.cycle))
                            Spacer()
                            Text(durationString(row.cycle.totalLifetime)).foregroundStyle(.secondary)
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

        private func sessionDatesString(_ cycle: BatteryDischargeCycle) -> String {
            guard let start = cycle.startDate else {
                return NSLocalizedString("Session", comment: "Battery session without a date")
            }
            let end = start.addingTimeInterval(cycle.totalLifetime)
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

/// Day/hour wheel editor for one voltage level's time-remaining.
struct BatteryLevelEditView: View {
    let voltageLabel: String
    let initialSeconds: TimeInterval
    let isOverridden: Bool
    let onSave: (TimeInterval) -> Void
    let onReset: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var days: Int
    @State private var hours: Int

    init(
        voltageLabel: String,
        initialSeconds: TimeInterval,
        isOverridden: Bool,
        onSave: @escaping (TimeInterval) -> Void,
        onReset: @escaping () -> Void
    ) {
        self.voltageLabel = voltageLabel
        self.initialSeconds = initialSeconds
        self.isOverridden = isOverridden
        self.onSave = onSave
        self.onReset = onReset
        let clamped = max(0, initialSeconds)
        _days = State(initialValue: Int(clamped / 86400))
        _hours = State(initialValue: Int(clamped.truncatingRemainder(dividingBy: 86400) / 3600))
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Time remaining at \(voltageLabel)")) {
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
                if isOverridden {
                    Section {
                        Button("Reset to learned value", role: .destructive) {
                            onReset()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(voltageLabel)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(TimeInterval(days * 86400 + hours * 3600))
                        dismiss()
                    }
                }
            }
        }
    }
}
