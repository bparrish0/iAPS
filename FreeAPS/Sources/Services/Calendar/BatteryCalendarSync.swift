import Combine
import EventKit
import Foundation
import Swinject

/// A calendar the user can pick as the destination for a battery's expiration event.
struct BatteryCalendarChoice: Identifiable, Equatable {
    let id: String
    let title: String
}

/// Mirrors each battery's estimated-empty time into a user-chosen calendar as a single event,
/// moving that event whenever the estimate changes and removing it when the feature is
/// switched off or the estimate disappears.
protocol BatteryCalendarSync {
    func isEnabled(_ kind: BatteryDeviceKind) -> Bool
    func calendarIdentifier(_ kind: BatteryDeviceKind) -> String?
    func setEnabled(_ enabled: Bool, calendarIdentifier: String?, for kind: BatteryDeviceKind)
    /// Writable calendars on the device, or empty when calendar access hasn't been granted.
    func availableCalendars() -> [BatteryCalendarChoice]
    /// The calendar to preselect when the user first turns the feature on.
    func suggestedCalendarIdentifier() -> String?
    func requestAccessIfNeeded() -> AnyPublisher<Bool, Never>
    /// Bring the calendar event for this battery in line with its persisted log.
    func sync(_ kind: BatteryDeviceKind)
}

final class BaseBatteryCalendarSync: BatteryCalendarSync, Injectable {
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var calendarManager: CalendarManager!

    @Persisted(key: "BatteryCalendar.pump.enabled") private var pumpEnabled = false
    @Persisted(key: "BatteryCalendar.pump.calendarID") private var pumpCalendarID: String? = nil
    @Persisted(key: "BatteryCalendar.pump.eventID") private var pumpEventID: String? = nil
    @Persisted(key: "BatteryCalendar.orangeLink.enabled") private var orangeLinkEnabled = false
    @Persisted(key: "BatteryCalendar.orangeLink.calendarID") private var orangeLinkCalendarID: String? = nil
    @Persisted(key: "BatteryCalendar.orangeLink.eventID") private var orangeLinkEventID: String? = nil

    private lazy var eventStore = EKEventStore()
    private let queue = DispatchQueue(label: "BatteryCalendarSync.queue")
    private var lifetime = Lifetime()

    /// How long the event blocks out on the calendar.
    private static let eventDuration: TimeInterval = 30 * 60
    /// Estimate movements smaller than this don't rewrite the event (readings jitter; the
    /// estimate is a fixed date between level transitions anyway).
    private static let moveTolerance: TimeInterval = 60

    init(resolver: Resolver) {
        injectServices(resolver)
        broadcaster.register(PumpBatteryObserver.self, observer: self)
        Foundation.NotificationCenter.default.publisher(for: .orangeLinkBatteryUpdated)
            .sink { [weak self] _ in self?.sync(.orangeLink) }
            .store(in: &lifetime)
        sync(.pump)
        sync(.orangeLink)
    }

    // MARK: - Settings

    func isEnabled(_ kind: BatteryDeviceKind) -> Bool {
        switch kind {
        case .pump: return pumpEnabled
        case .orangeLink: return orangeLinkEnabled
        }
    }

    func calendarIdentifier(_ kind: BatteryDeviceKind) -> String? {
        switch kind {
        case .pump: return pumpCalendarID
        case .orangeLink: return orangeLinkCalendarID
        }
    }

    func setEnabled(_ enabled: Bool, calendarIdentifier: String?, for kind: BatteryDeviceKind) {
        switch kind {
        case .pump:
            pumpEnabled = enabled
            pumpCalendarID = calendarIdentifier
        case .orangeLink:
            orangeLinkEnabled = enabled
            orangeLinkCalendarID = calendarIdentifier
        }
    }

    private func eventIdentifier(_ kind: BatteryDeviceKind) -> String? {
        switch kind {
        case .pump: return pumpEventID
        case .orangeLink: return orangeLinkEventID
        }
    }

    private func setEventIdentifier(_ id: String?, for kind: BatteryDeviceKind) {
        switch kind {
        case .pump: pumpEventID = id
        case .orangeLink: orangeLinkEventID = id
        }
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
        // Prefer the calendar already used for glucose events, then the system default.
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
            self?.performSync(kind)
        }
    }

    private func performSync(_ kind: BatteryDeviceKind) {
        guard hasAccess else { return }

        let log = storage.retrieve(kind.storageFile, as: BatteryDischargeLog.self)
        let calendar = isEnabled(kind)
            ? calendarIdentifier(kind).flatMap { eventStore.calendar(withIdentifier: $0) }
            : nil
        let expiration = log?.currentExpirationDate

        guard let calendar = calendar, let expiration = expiration else {
            removeEvent(for: kind)
            return
        }

        var event = eventIdentifier(kind).flatMap { eventStore.event(withIdentifier: $0) }
        if let existing = event, existing.calendar.calendarIdentifier != calendar.calendarIdentifier {
            // User picked a different calendar: EventKit can't move events across calendars
            // reliably, so recreate it there.
            removeEvent(for: kind)
            event = nil
        }

        let title = Self.title(for: kind)
        let notes = Self.notes(log: log)
        let start = expiration
        let end = expiration.addingTimeInterval(Self.eventDuration)

        if let existing = event {
            let moved = abs(existing.startDate.timeIntervalSince(start)) > Self.moveTolerance
                || abs(existing.endDate.timeIntervalSince(end)) > Self.moveTolerance
            guard moved || existing.title != title || existing.notes != notes else { return }
            existing.title = title
            existing.notes = notes
            existing.startDate = start
            existing.endDate = end
            save(existing, for: kind, action: "move")
            return
        }

        let created = EKEvent(eventStore: eventStore)
        created.calendar = calendar
        created.title = title
        created.notes = notes
        created.startDate = start
        created.endDate = end
        created.addAlarm(EKAlarm(relativeOffset: 0))
        save(created, for: kind, action: "create")
    }

    private func save(_ event: EKEvent, for kind: BatteryDeviceKind, action: String) {
        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            setEventIdentifier(event.eventIdentifier, for: kind)
            debug(.service, "Battery calendar: \(action) \(kind.rawValue) event at \(event.startDate)")
        } catch {
            warning(.service, "Battery calendar: cannot \(action) \(kind.rawValue) event", error: error)
        }
    }

    private func removeEvent(for kind: BatteryDeviceKind) {
        guard let id = eventIdentifier(kind) else { return }
        setEventIdentifier(nil, for: kind)
        guard let event = eventStore.event(withIdentifier: id) else { return }
        do {
            try eventStore.remove(event, span: .thisEvent, commit: true)
            debug(.service, "Battery calendar: removed \(kind.rawValue) event")
        } catch {
            warning(.service, "Battery calendar: cannot remove \(kind.rawValue) event", error: error)
        }
    }

    private static func title(for kind: BatteryDeviceKind) -> String {
        switch kind {
        case .pump:
            return NSLocalizedString("Pump battery empty (est.)", comment: "Battery calendar event title")
        case .orangeLink:
            return NSLocalizedString("OrangeLink battery empty (est.)", comment: "Battery calendar event title")
        }
    }

    private static func notes(log: BatteryDischargeLog?) -> String {
        var lines = [
            NSLocalizedString(
                "Estimated by iAPS from this battery's discharge curve. This event moves as the estimate changes.",
                comment: "Battery calendar event notes"
            )
        ]
        if let log = log, let installed = log.replacementDate, log.cycleIsLearnable {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append(String(
                format: NSLocalizedString("Installed: %@", comment: "Battery calendar event notes"),
                formatter.string(from: installed)
            ))
        }
        return lines.joined(separator: "\n")
    }
}

extension BaseBatteryCalendarSync: PumpBatteryObserver {
    func pumpBatteryDidChange(_: Battery) {
        sync(.pump)
    }
}
