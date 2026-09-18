import Foundation

import CGMBLEKit
import Combine
import G7SensorKit
import LoopKitUI
import SwiftUI
import UIKit

extension CalendarShare {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var calendarManager: CalendarManager!
        @Injected() var batteryCalendarSync: BatteryCalendarSync!

        @Published var createCalendarEvents = false
        @Published var displayCalendarIOBandCOB = false
        @Published var displayCalendarEmojis = false
        @Published var calendarIDs: [String] = []
        @Published var currentCalendarID: String = ""
        @Persisted(key: "CalendarManager.currentCalendarID") var storedCalendarID: String? = nil

        /// Insulin-remaining expiration event (batteries are configured on their own screens).
        @Published var insulinCalendarEnabled = false
        @Published var insulinCalendarID = ""
        @Published var insulinCalendars: [BatteryCalendarChoice] = []

        /// Turn the insulin reservoir-empty calendar event on or off. Turning it on asks for
        /// calendar access (first time), loads the calendar list, preselects a calendar, and
        /// creates the event from the latest estimate; turning it off deletes the event.
        func setInsulinCalendarEnabled(_ enabled: Bool) {
            insulinCalendarEnabled = enabled
            guard enabled else {
                batteryCalendarSync.setInsulinEnabled(false, calendarIdentifier: batteryCalendarSync.insulinCalendarIdentifier())
                batteryCalendarSync.resyncInsulin()
                return
            }
            batteryCalendarSync.requestAccessIfNeeded()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] granted in
                    guard let self = self else { return }
                    self.insulinCalendars = granted ? self.batteryCalendarSync.availableCalendars() : []
                    if granted, !self.insulinCalendars.contains(where: { $0.id == self.insulinCalendarID }) {
                        self.insulinCalendarID = self.batteryCalendarSync.suggestedCalendarIdentifier()
                            ?? self.insulinCalendars.first?.id ?? ""
                    }
                    self.batteryCalendarSync.setInsulinEnabled(
                        true,
                        calendarIdentifier: self.insulinCalendarID.isEmpty ? nil : self.insulinCalendarID
                    )
                    self.batteryCalendarSync.resyncInsulin()
                }
                .store(in: &lifetime)
        }

        /// Move the insulin event to a different calendar.
        func setInsulinCalendarID(_ id: String) {
            insulinCalendarID = id
            batteryCalendarSync.setInsulinEnabled(insulinCalendarEnabled, calendarIdentifier: id.isEmpty ? nil : id)
            batteryCalendarSync.resyncInsulin()
        }

        override func subscribe() {
            currentCalendarID = storedCalendarID ?? ""
            calendarIDs = calendarManager.calendarIDs()
            insulinCalendarEnabled = batteryCalendarSync.isInsulinEnabled()
            insulinCalendarID = batteryCalendarSync.insulinCalendarIdentifier() ?? ""
            insulinCalendars = batteryCalendarSync.availableCalendars()

            subscribeSetting(\.useCalendar, on: $createCalendarEvents) { createCalendarEvents = $0 }
            subscribeSetting(\.displayCalendarIOBandCOB, on: $displayCalendarIOBandCOB) { displayCalendarIOBandCOB = $0 }
            subscribeSetting(\.displayCalendarEmojis, on: $displayCalendarEmojis) { displayCalendarEmojis = $0 }

            $createCalendarEvents
                .removeDuplicates()
                .flatMap { [weak self] ok -> AnyPublisher<Bool, Never> in
                    guard ok, let self = self else { return Just(false).eraseToAnyPublisher() }
                    return self.calendarManager.requestAccessIfNeeded()
                }
                .map { [weak self] ok -> [String] in
                    guard ok, let self = self else { return [] }
                    return self.calendarManager.calendarIDs()
                }
                .receive(on: DispatchQueue.main)
                .weakAssign(to: \.calendarIDs, on: self)
                .store(in: &lifetime)

            $currentCalendarID
                .removeDuplicates()
                .sink { [weak self] id in
                    guard id.isNotEmpty else {
                        self?.calendarManager.currentCalendarID = nil
                        return
                    }
                    self?.calendarManager.currentCalendarID = id
                }
                .store(in: &lifetime)
        }
    }
}
