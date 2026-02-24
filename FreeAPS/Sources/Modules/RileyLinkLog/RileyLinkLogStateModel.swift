import Combine
import RileyLinkKit
import SwiftUI
import Swinject

extension RileyLinkLog {
    final class StateModel: BaseStateModel<Provider> {
        @Published var entries: [RileyLinkLogEntry] = []
        @Published var filteredEntries: [RileyLinkLogEntry] = []
        @Published var selectedCategory: String? = nil
        @Published var selectedLevel: RileyLinkLogLevel? = nil

        override func subscribe() {
            RileyLinkLogBuffer.shared.entriesDidChange
                .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
                .sink { [weak self] in
                    self?.refreshEntries()
                }
                .store(in: &lifetime)

            $selectedCategory
                .combineLatest($selectedLevel)
                .sink { [weak self] _, _ in
                    self?.applyFilters()
                }
                .store(in: &lifetime)

            refreshEntries()
        }

        private func refreshEntries() {
            entries = RileyLinkLogBuffer.shared.allEntries()
            applyFilters()
        }

        private func applyFilters() {
            var result = entries
            if let category = selectedCategory {
                result = result.filter { $0.category == category }
            }
            if let level = selectedLevel {
                result = result.filter { $0.level == level }
            }
            filteredEntries = result
        }

        var categories: [String] {
            Array(Set(entries.map(\.category))).sorted()
        }

        func clearLogs() {
            RileyLinkLogBuffer.shared.clear()
        }

        func formattedLogText() -> String {
            RileyLinkLogBuffer.shared.formattedLog()
        }
    }
}
