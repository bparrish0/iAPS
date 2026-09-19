import LoopKitUI
import SwiftUI
import Swinject

extension CalendarShare {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state: StateModel

        init(resolver: Resolver) {
            self.resolver = resolver
            _state = StateObject(wrappedValue: StateModel(resolver: resolver))
        }

        var body: some View {
            NavigationView {
                Form {
                    Section {
                        Toggle("Create Events in Calendar", isOn: $state.createCalendarEvents)
                        if state.calendarIDs.isNotEmpty {
                            Picker("Calendar", selection: $state.currentCalendarID) {
                                ForEach(state.calendarIDs, id: \.self) {
                                    Text($0).tag($0)
                                }
                            }
                            Toggle("Display Emojis as Labels", isOn: $state.displayCalendarEmojis)
                            Toggle("Display IOB and COB", isOn: $state.displayCalendarIOBandCOB)
                        } else if state.createCalendarEvents {
                            Text(
                                "If you are not seeing calendars to choose here, please go to Settings -> iAPS -> Calendars and change permissions to \"Full Access\""
                            ).font(.footnote)

                            Button("Open Settings") {
                                // Get the settings URL and open it
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }
                    }

                    expirationSection(
                        .insulin,
                        header: "Insulin remaining",
                        footer: "Puts the estimated reservoir-empty time in a calendar, with an alert, and moves it as the estimate changes."
                    )
                    expirationSection(
                        .cgmSensor,
                        header: "CGM sensor",
                        footer: "Puts the sensor's expiration time in a calendar, with an alert, from the session start reported by the CGM. Pump and OrangeLink battery events are set up on their battery screens."
                    )
                }
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .navigationTitle("Calendar")
                .navigationBarTitleDisplayMode(.inline)
            }
        }

        private func expirationSection(_ item: CalendarExpirationItem, header: String, footer: String) -> some View {
            Section(header: Text(header), footer: Text(footer)) {
                Toggle(
                    "Add to Calendar",
                    isOn: Binding(
                        get: { state.expirationEnabled[item] ?? false },
                        set: { state.setExpirationEnabled($0, for: item) }
                    )
                )
                if state.expirationEnabled[item] ?? false {
                    if state.expirationCalendars.isNotEmpty {
                        Picker(
                            "Calendar",
                            selection: Binding(
                                get: { state.expirationCalendarID[item] ?? "" },
                                set: { state.setExpirationCalendarID($0, for: item) }
                            )
                        ) {
                            ForEach(state.expirationCalendars) { choice in
                                Text(choice.title).tag(choice.id)
                            }
                        }
                    } else {
                        Text(
                            "If you are not seeing calendars to choose here, please go to Settings -> iAPS -> Calendars and change permissions to \"Full Access\""
                        ).font(.footnote)
                    }
                    if let status = state.expirationStatus[item], !status.isEmpty {
                        HStack {
                            Text("Status")
                            Spacer()
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
    }
}
