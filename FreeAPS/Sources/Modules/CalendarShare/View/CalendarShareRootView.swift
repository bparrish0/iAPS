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

                    Section(
                        header: Text("Insulin remaining"),
                        footer: Text(
                            "Puts the estimated reservoir-empty time in a calendar, with an alert, and moves it as the estimate changes. Pump and OrangeLink battery events are set up on their battery screens."
                        )
                    ) {
                        Toggle(
                            "Add estimate to Calendar",
                            isOn: Binding(
                                get: { state.insulinCalendarEnabled },
                                set: { state.setInsulinCalendarEnabled($0) }
                            )
                        )
                        if state.insulinCalendarEnabled {
                            if state.insulinCalendars.isNotEmpty {
                                Picker(
                                    "Calendar",
                                    selection: Binding(
                                        get: { state.insulinCalendarID },
                                        set: { state.setInsulinCalendarID($0) }
                                    )
                                ) {
                                    ForEach(state.insulinCalendars) { choice in
                                        Text(choice.title).tag(choice.id)
                                    }
                                }
                            } else {
                                Text(
                                    "If you are not seeing calendars to choose here, please go to Settings -> iAPS -> Calendars and change permissions to \"Full Access\""
                                ).font(.footnote)
                            }
                        }
                    }
                }
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .navigationTitle("Calendar")
                .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}
