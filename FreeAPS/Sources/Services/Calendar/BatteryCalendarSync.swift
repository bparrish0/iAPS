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
enum CalendarExpirationItem: String, CaseIterable {
    case pumpBattery = "pump"
    case orangeLinkBattery = "orangeLink"
    case insulin

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
        }
    }

    /// The insulin estimate is "now plus hours remaining" and is recomputed on every pump
    /// contact, so it drifts by a few minutes each cycle; only real movement rewrites its event.
    var moveTolerance: TimeInterval {
        switch self {
        case .pumpBattery, .orangeLinkBattery: return 60
        case .insulin: return 30 * 60
        }
    }
}

/// Mirrors each battery's estimated-empty time, and the insulin reservoir's, into a
/// user-chosen calendar as a single event per item, moving that event whenever the estimate
/// changes and removing it when the feature is switched off or the estimate disappears.
protocol BatteryCalendarSync {
    func isEnabled(_ kind: BatteryDeviceKind) -> Bool
    func calendarIdentifier(_ kind: BatteryDeviceKind) -> String?
    func setEnabled(_ enabled: Bool, calendarIdentifier: String?, for kind: BatteryDeviceKind)
    /// Bring the calendar event for this battery in line with its persisted log.
    func sync(_ kind: BatteryDeviceKind)

    func isInsulinEnabled() -> Bool
    func insulinCalendarIdentifier() -> String?
    func setInsulinEnabled(_ enabled: Bool, calendarIdentifier: String?)
    /// Bring the insulin event in line with the latest estimate (nil removes it).
    func syncInsulin(expiration: Date?)
    /// Re-apply the insulin settings using the last estimate seen (after a toggle or calendar change).
    func resyncInsulin()

    /// Writable calendars on the device, or empty when calendar access hasn't been granted.
    func availableCalendars() -> [BatteryCalendarChoice]
    /// The calendar to preselect when the user first turns the feature on.
    func suggestedCalendarIdentifier() -> String?
    func requestAccessIfNeeded() -> AnyPublisher<Bool, Never>
}

final class BaseBatteryCalendarSync: BatteryCalendarSync, Injectable {
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var calendarManager: CalendarManager!

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
        Foundation.NotificationCenter.default.publisher(for: .orangeLinkBatteryUpdated)
            .sink { [weak self] _ in self?.sync(.orangeLink) }
            .store(in: &lifetime)
        sync(.pump)
        sync(.orangeLink)
        syncInsulin(expiration: defaults.getValue(Date.self, forKey: Self.insulinExpirationKey))
    }

    // MARK: - Settings

    private func key(_ item: CalendarExpirationItem, _ field: String) -> String {
        "BatteryCalendar.\(item.rawValue).\(field)"
    }

    private func isEnabled(_ item: CalendarExpirationItem) -> Bool {
        defaults.getValue(Bool.self, forKey: key(item, "enabled")) ?? false
    }

    private func calendarIdentifier(_ item: CalendarExpirationItem) -> String? {
        defaults.getValue(String.self, forKey: key(item, "calendarID"))
    }

    private func setEnabled(_ enabled: Bool, calendarIdentifier: String?, for item: CalendarExpirationItem) {
        defaults.setValue(enabled, forKey: key(item, "enabled"))
        defaults.setValue(calendarIdentifier, forKey: key(item, "calendarID"))
    }

    private func eventIdentifier(_ item: CalendarExpirationItem) -> String? {
        defaults.getValue(String.self, forKey: key(item, "eventID"))
    }

    private func setEventIdentifier(_ id: String?, for item: CalendarExpirationItem) {
        defaults.setValue(id, forKey: key(item, "eventID"))
    }

    func isEnabled(_ kind: BatteryDeviceKind) -> Bool { isEnabled(CalendarExpirationItem(kind)) }
    func calendarIdentifier(_ kind: BatteryDeviceKind) -> String? { calendarIdentifier(CalendarExpirationItem(kind)) }
    func setEnabled(_ enabled: Bool, calendarIdentifier: String?, for kind: BatteryDeviceKind) {
        setEnabled(enabled, calendarIdentifier: calendarIdentifier, for: CalendarExpirationItem(kind))
    }

    func isInsulinEnabled() -> Bool { isEnabled(.insulin) }
    func insulinCalendarIdentifier() -> String? { calendarIdentifier(.insulin) }
    func setInsulinEnabled(_ enabled: Bool, calendarIdentifier: String?) {
        setEnabled(enabled, calendarIdentifier: calendarIdentifier, for: .insulin)
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

    func sync(_ kind: BatteryDeviceKind) {
        queue.async { [weak self] in
            guard let self = self else { return }
            let log = self.storage.retrieve(kind.storageFile, as: BatteryDischargeLog.self)
            var notes = [CalendarExpirationItem(kind).notesIntro]
            if let log = log, let installed = log.replacementDate, log.cycleIsLearnable {
                notes.append(String(
                    format: NSLocalizedString("Installed: %@", comment: "Calendar event notes"),
                    Self.noteDateFormatter.string(from: installed)
                ))
            }
            self.upsert(
                CalendarExpirationItem(kind),
                expiration: log?.currentExpirationDate,
                notes: notes.joined(separator: "\n")
            )
        }
    }

    func syncInsulin(expiration: Date?) {
        defaults.setValue(expiration, forKey: Self.insulinExpirationKey)
        queue.async { [weak self] in
            self?.upsert(.insulin, expiration: expiration, notes: CalendarExpirationItem.insulin.notesIntro)
        }
    }

    func resyncInsulin() {
        syncInsulin(expiration: defaults.getValue(Date.self, forKey: Self.insulinExpirationKey))
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
}

extension BaseBatteryCalendarSync: PumpBatteryObserver {
    func pumpBatteryDidChange(_: Battery) {
        sync(.pump)
    }
}
