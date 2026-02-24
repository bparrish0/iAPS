import RileyLinkKit
import SwiftUI
import Swinject

extension RileyLinkLog {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state: StateModel
        @State private var showShareSheet = false

        init(resolver: Resolver) {
            self.resolver = resolver
            _state = StateObject(wrappedValue: StateModel(resolver: resolver))
        }

        var body: some View {
            VStack(spacing: 0) {
                filterBar
                logList
            }
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Button {
                        state.clearLogs()
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(activityItems: [state.formattedLogText()])
            }
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
            .navigationTitle("RileyLink Logs")
            .navigationBarTitleDisplayMode(.inline)
        }

        private var filterBar: some View {
            HStack {
                Menu {
                    Button("All Categories") {
                        state.selectedCategory = nil
                    }
                    ForEach(state.categories, id: \.self) { category in
                        Button(category) {
                            state.selectedCategory = category
                        }
                    }
                } label: {
                    HStack {
                        Text(state.selectedCategory ?? "Category")
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemFill))
                    .cornerRadius(8)
                }

                Menu {
                    Button("All Levels") {
                        state.selectedLevel = nil
                    }
                    ForEach(RileyLinkLogLevel.allCases, id: \.self) { level in
                        Button(level.rawValue.capitalized) {
                            state.selectedLevel = level
                        }
                    }
                } label: {
                    HStack {
                        Text(state.selectedLevel?.rawValue.capitalized ?? "Level")
                            .font(.subheadline)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color(.secondarySystemFill))
                    .cornerRadius(8)
                }

                Spacer()

                Text("\(state.filteredEntries.count) entries")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }

        private var logList: some View {
            ScrollViewReader { proxy in
                List(state.filteredEntries) { entry in
                    logRow(entry)
                        .id(entry.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                }
                .listStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .onChange(of: state.filteredEntries.last?.id) { _, newID in
                    if let id = newID {
                        withAnimation {
                            proxy.scrollTo(id, anchor: .bottom)
                        }
                    }
                }
            }
        }

        private func logRow(_ entry: RileyLinkLogEntry) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(entry.timestamp, format: .dateTime.hour().minute().second().secondFraction(.fractional(3)))
                        .foregroundColor(.secondary)
                    levelBadge(entry.level)
                    Text(entry.category)
                        .foregroundColor(.secondary)
                        .bold()
                }
                .font(.system(.caption2, design: .monospaced))

                Text(entry.message)
                    .foregroundColor(colorForLevel(entry.level))
            }
        }

        private func levelBadge(_ level: RileyLinkLogLevel) -> some View {
            Text(level.rawValue.prefix(3).uppercased())
                .font(.system(.caption2, design: .monospaced))
                .bold()
                .foregroundColor(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(colorForLevel(level))
                .cornerRadius(3)
        }

        private func colorForLevel(_ level: RileyLinkLogLevel) -> Color {
            switch level {
            case .debug: return .gray
            case .info: return .primary
            case .default: return .primary
            case .error: return .red
            }
        }
    }
}
