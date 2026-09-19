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

        /// Expiration events (insulin reservoir, CGM sensor). Batteries are configured on their
        /// own detail screens but share the same service and calendar list.
        @Published var expirationEnabled: [CalendarExpirationItem: Bool] = [:]
        @Published var expirationCalendarID: [CalendarExpirationItem: String] = [:]
        @Published var expirationCalendars: [BatteryCalendarChoice] = []
        @Published var expirationStatus: [CalendarExpirationItem: String] = [:]

        private func refreshExpirationStatus() {
            for item in CalendarExpirationItem.allCases {
                expirationStatus[item] = batteryCalendarSync.lastStatus(item)
            }
        }

        /// Turn one item's calendar event on or off. Turning it on asks for calendar access
        /// (first time), loads the calendar list, preselects a calendar, and creates the event;
        /// turning it off deletes the event.
        func setExpirationEnabled(_ enabled: Bool, for item: CalendarExpirationItem) {
            expirationEnabled[item] = enabled
            guard enabled else {
                batteryCalendarSync.setEnabled(false, calendarIdentifier: batteryCalendarSync.calendarIdentifier(item), for: item)
                batteryCalendarSync.resync(item)
                return
            }
            batteryCalendarSync.requestAccessIfNeeded()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] granted in
                    guard let self = self else { return }
                    self.expirationCalendars = granted ? self.batteryCalendarSync.availableCalendars() : []
                    let current = self.expirationCalendarID[item] ?? ""
                    if granted, !self.expirationCalendars.contains(where: { $0.id == current }) {
                        self.expirationCalendarID[item] = self.batteryCalendarSync.suggestedCalendarIdentifier()
                            ?? self.expirationCalendars.first?.id ?? ""
                    }
                    let id = self.expirationCalendarID[item] ?? ""
                    self.batteryCalendarSync.setEnabled(true, calendarIdentifier: id.isEmpty ? nil : id, for: item)
                    self.batteryCalendarSync.resync(item)
                }
                .store(in: &lifetime)
        }

        /// Move one item's event to a different calendar.
        func setExpirationCalendarID(_ id: String, for item: CalendarExpirationItem) {
            expirationCalendarID[item] = id
            batteryCalendarSync.setEnabled(expirationEnabled[item] ?? false, calendarIdentifier: id.isEmpty ? nil : id, for: item)
            batteryCalendarSync.resync(item)
        }

        override func subscribe() {
            currentCalendarID = storedCalendarID ?? ""
            calendarIDs = calendarManager.calendarIDs()
            for item in CalendarExpirationItem.allCases {
                expirationEnabled[item] = batteryCalendarSync.isEnabled(item)
                expirationCalendarID[item] = batteryCalendarSync.calendarIdentifier(item) ?? ""
            }
            expirationCalendars = batteryCalendarSync.availableCalendars()
            refreshExpirationStatus()
            Foundation.NotificationCenter.default.publisher(for: .expirationCalendarSynced)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refreshExpirationStatus() }
                .store(in: &lifetime)

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
