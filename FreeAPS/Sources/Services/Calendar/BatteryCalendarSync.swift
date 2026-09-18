import Combine
import EventKit
import Foundation
import Swinject

/// A calendar the user can pick as the destination for an expiration event.
struct BatteryCalendarChoice: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Which expiring thing a calendar event tracks. Raw values double as the persisted-key
/// segment, so the battery keys stay what earlier builds wrote.
enum CalendarExpirationItem: String, CaseIterable, Identifiable {
    case pumpBattery = "pump"
    case orangeLinkBattery = "orangeLink"
    case insulin
    case cgmSensor = "sensor"

    var id: String { rawValue }

    init(_ kind: BatteryDeviceKind) {
        switch kind {
        case .pump: self = .pumpBattery
        case .orangeLink: self = .orangeLinkBattery
        }
    }

    var eventTitle: String {
        switch self {
        case .pumpBattery:
            return NSLocalizedString("Pump battery empty (est.)", comment: "Calendar event title")
        case .orangeLinkBattery:
            return NSLocalizedString("OrangeLink battery empty (est.)", comment: "Calendar event title")
        case .insulin:
            return NSLocalizedString("Insulin reservoir empty (est.)", comment: "Calendar event title")
        case .cgmSensor:
            return NSLocalizedString("CGM sensor expires", comment: "Calendar event title")
        }
    }

    var notesIntro: String {
        switch self {
        case .pumpBattery, .orangeLinkBattery:
            return NSLocalizedString(
                "Estimated by iAPS from this battery's discharge curve. This event moves as the estimate changes.",
                comment: "Calendar event notes"
            )
        case .insulin:
            return NSLocalizedString(
                "Estimated by iAPS from the reservoir level and average daily insulin use. This event moves as the estimate changes.",
                comment: "Calendar event notes"
            )
        case .cgmSensor:
            return NSLocalizedString(
                "From the sensor session start reported by the CGM and the session length iAPS uses for the sensor countdown.",
                comment: "Calendar event notes"
            )
        }
    }

    /// The insulin estimate is "now plus hours remaining" and is recomputed on every pump
    /// contact, so it drifts by a few minutes each cycle; only real movement rewrites its event.
    var moveTolerance: TimeInterval {
        switch self {
        case .pumpBattery, .orangeLinkBattery, .cgmSensor: return 60
        case .insulin: return 30 * 60
        }
    }
}

/// Mirrors each expiring item's end time — pump battery, OrangeLink battery, insulin reservoir,
/// CGM sensor — into a user-chosen calendar as a single event per item, moving that event
/// whenever the estimate changes and removing it when the item is switched off or has no
/// estimate.
protocol BatteryCalendarSync {
    func isEnabled(_ item: CalendarExpirationItem) -> Bool
    func calendarIdentifier(_ item: CalendarExpirationItem) -> String?
    func setEnabled(_ enabled: Bool, calendarIdentifier: String?, for item: CalendarExpirationItem)
    /// Recompute this item's expiration from its source and bring its event in line.
    func resync(_ item: CalendarExpirationItem)
    /// The insulin estimate lives in the Home model; it pushes each new value here (nil removes
    /// the event). `resync(.insulin)` re-applies the last value pushed.
    func syncInsulin(expiration: Date?)

    /// Writable calendars on the device, or empty when calendar access hasn't been granted.
    func availableCalendars() -> [BatteryCalendarChoice]
    /// The calendar to preselect when the user first turns an item on.
    func suggestedCalendarIdentifier() -> String?
    func requestAccessIfNeeded() -> AnyPublisher<Bool, Never>
}

/// Battery-kind conveniences for the battery detail screens.
extension BatteryCalendarSync {
    func isEnabled(_ kind: BatteryDeviceKind) -> Bool { isEnabled(CalendarExpirationItem(kind)) }
    func calendarIdentifier(_ kind: BatteryDeviceKind) -> String? { calendarIdentifier(CalendarExpirationItem(kind)) }
    func setEnabled(_ enabled: Bool, calendarIdentifier: String?, for kind: BatteryDeviceKind) {
        setEnabled(enabled, calendarIdentifier: calendarIdentifier, for: CalendarExpirationItem(kind))
    }

    func sync(_ kind: BatteryDeviceKind) { resync(CalendarExpirationItem(kind)) }
}

final class BaseBatteryCalendarSync: BatteryCalendarSync, Injectable {
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var calendarManager: CalendarManager!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var appCoordinator: AppCoordinator!

    /// Same store and encoding as `@Persisted`, keyed per item so the battery keys written by
    /// earlier builds keep working.
    private let defaults: KeyValueStorage = UserDefaults.standard

    private lazy var eventStore = EKEventStore()
    private let queue = DispatchQueue(label: "BatteryCalendarSync.queue")
    private var lifetime = Lifetime()

    /// How long the event blocks out on the calendar.
    private static let eventDuration: TimeInterval = 30 * 60
    private static let insulinExpirationKey = "BatteryCalendar.insulin.lastExpiration"

    init(resolver: Resolver) {
        injectServices(resolver)
        broadcaster.register(PumpBatteryObserver.self, observer: self)
        broadcaster.register(GlucoseObserver.self, observer: self)
        Foundation.NotificationCenter.default.publisher(for: .orangeLinkBatteryUpdated)
            .sink { [weak self] _ in self?.resync(.orangeLinkBattery) }
            .store(in: &lifetime)
        appCoordinator.$sensorDays
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in self?.resync(.cgmSensor) }
            .store(in: &lifetime)
        CalendarExpirationItem.allCases.forEach(resync)
    }

    // MARK: - Settings

    private func key(_ item: CalendarExpirationItem, _ field: String) -> String {
        "BatteryCalendar.\(item.rawValue).\(field)"
    }

    func isEnabled(_ item: CalendarExpirationItem) -> Bool {
        defaults.getValue(Bool.self, forKey: key(item, "enabled")) ?? false
    }

    func calendarIdentifier(_ item: CalendarExpirationItem) -> String? {
        defaults.getValue(String.self, forKey: key(item, "calendarID"))
    }

    func setEnabled(_ enabled: Bool, calendarIdentifier: String?, for item: CalendarExpirationItem) {
        defaults.setValue(enabled, forKey: key(item, "enabled"))
        defaults.setValue(calendarIdentifier, forKey: key(item, "calendarID"))
    }

    private func eventIdentifier(_ item: CalendarExpirationItem) -> String? {
        defaults.getValue(String.self, forKey: key(item, "eventID"))
    }

    private func setEventIdentifier(_ id: String?, for item: CalendarExpirationItem) {
        defaults.setValue(id, forKey: key(item, "eventID"))
    }

    // MARK: - Calendar access

    func requestAccessIfNeeded() -> AnyPublisher<Bool, Never> {
        calendarManager.requestAccessIfNeeded()
            .handleEvents(receiveOutput: { [weak self] granted in
                // A store created before access was granted doesn't see the calendars.
                if granted { self?.queue.async { self?.eventStore.reset() } }
            })
            .eraseToAnyPublisher()
    }

    private var hasAccess: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized: return true
        #if swift(>=5.9)
            case .fullAccess: return true
        #endif
        default: return false
        }
    }

    func availableCalendars() -> [BatteryCalendarChoice] {
        guard hasAccess else { return [] }
        return eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)
            .map { BatteryCalendarChoice(id: $0.calendarIdentifier, title: $0.title) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func suggestedCalendarIdentifier() -> String? {
        guard hasAccess else { return nil }
        // Prefer a calendar already chosen for another expiration item, then the glucose
        // calendar, then the system default.
        for item in CalendarExpirationItem.allCases {
            if isEnabled(item), let id = calendarIdentifier(item), eventStore.calendar(withIdentifier: id) != nil {
                return id
            }
        }
        if let title = calendarManager.currentCalendarID,
           let shared = eventStore.calendars(for: .event).first(where: { $0.title == title && $0.allowsContentModifications })
        {
            return shared.calendarIdentifier
        }
        return eventStore.defaultCalendarForNewEvents?.calendarIdentifier
    }

    // MARK: - Sync

    func resync(_ item: CalendarExpirationItem) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let (expiration, notes) = self.expiration(for: item)
            self.upsert(item, expiration: expiration, notes: notes)
        }
    }

    func syncInsulin(expiration: Date?) {
        defaults.setValue(expiration, forKey: Self.insulinExpirationKey)
        resync(.insulin)
    }

    /// Each item's current end time and the event notes explaining it.
    private func expiration(for item: CalendarExpirationItem) -> (Date?, String) {
        var notes = [item.notesIntro]
        switch item {
        case .pumpBattery, .orangeLinkBattery:
            let kind: BatteryDeviceKind = item == .pumpBattery ? .pump : .orangeLink
            let log = storage.retrieve(kind.storageFile, as: BatteryDischargeLog.self)
            if let log = log, let installed = log.replacementDate, log.cycleIsLearnable {
                notes.append(String(
                    format: NSLocalizedString("Installed: %@", comment: "Calendar event notes"),
                    Self.noteDateFormatter.string(from: installed)
                ))
            }
            return (log?.currentExpirationDate, notes.joined(separator: "\n"))

        case .insulin:
            return (defaults.getValue(Date.self, forKey: Self.insulinExpirationKey), notes.joined(separator: "\n"))

        case .cgmSensor:
            // Same inputs as the header's sensor countdown: the latest reading's session start
            // and the plugin's session length (or the settings fallback).
            guard let start = glucoseStorage.retrieveRaw().last(where: { $0.sessionStartDate != nil })?.sessionStartDate
            else { return (nil, notes.joined(separator: "\n")) }
            let days = appCoordinator.sensorDays ?? settingsManager.settings.sensorDays
            notes.append(String(
                format: NSLocalizedString("Session started: %@ · %@-day session", comment: "Calendar event notes"),
                Self.noteDateFormatter.string(from: start),
                Self.daysFormatter.string(from: days as NSNumber) ?? "\(days)"
            ))
            return (start.addingTimeInterval(days * 86400), notes.joined(separator: "\n"))
        }
    }

    /// Create, move, or remove the single event for `item` so it matches `expiration`.
    private func upsert(_ item: CalendarExpirationItem, expiration: Date?, notes: String) {
        guard hasAccess else { return }

        let calendar = isEnabled(item)
            ? calendarIdentifier(item).flatMap { eventStore.calendar(withIdentifier: $0) }
            : nil

        guard let calendar = calendar, let expiration = expiration else {
            removeEvent(for: item)
            return
        }

        var event = eventIdentifier(item).flatMap { eventStore.event(withIdentifier: $0) }
        if let existing = event, existing.calendar.calendarIdentifier != calendar.calendarIdentifier {
            // User picked a different calendar: EventKit can't move events across calendars
            // reliably, so recreate it there.
            removeEvent(for: item)
            event = nil
        }

        let title = item.eventTitle
        let start = expiration
        let end = expiration.addingTimeInterval(Self.eventDuration)

        if let existing = event {
            let moved = abs(existing.startDate.timeIntervalSince(start)) > item.moveTolerance
                || abs(existing.endDate.timeIntervalSince(end)) > item.moveTolerance
            guard moved || existing.title != title || existing.notes != notes else { return }
            existing.title = title
            existing.notes = notes
            existing.startDate = start
            existing.endDate = end
            save(existing, for: item, action: "move")
            return
        }

        let created = EKEvent(eventStore: eventStore)
        created.calendar = calendar
        created.title = title
        created.notes = notes
        created.startDate = start
        created.endDate = end
        created.addAlarm(EKAlarm(relativeOffset: 0))
        save(created, for: item, action: "create")
    }

    private func save(_ event: EKEvent, for item: CalendarExpirationItem, action: String) {
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            setEventIdentifier(event.eventIdentifier, for: item)
            debug(.service, "Expiration calendar: \(action) \(item.rawValue) event at \(event.startDate)")
        } catch {
            warning(.service, "Expiration calendar: cannot \(action) \(item.rawValue) event", error: error)
        }
    }

    private func removeEvent(for item: CalendarExpirationItem) {
        guard let id = eventIdentifier(item) else { return }
        setEventIdentifier(nil, for: item)
        guard let event = eventStore.event(withIdentifier: id) else { return }
        do {
            try eventStore.remove(event, span: .thisEvent, commit: true)
            debug(.service, "Expiration calendar: removed \(item.rawValue) event")
        } catch {
            warning(.service, "Expiration calendar: cannot remove \(item.rawValue) event", error: error)
        }
    }

    private static var noteDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    private static var daysFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 1
        return formatter
    }
}

extension BaseBatteryCalendarSync: PumpBatteryObserver, GlucoseObserver {
    func pumpBatteryDidChange(_: Battery) {
        resync(.pumpBattery)
    }

    func glucoseDidUpdate(_: [BloodGlucose]) {
        resync(.cgmSensor)
    }
}
