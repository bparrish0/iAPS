import Combine
import Foundation

public enum RileyLinkLogLevel: String, CaseIterable {
    case debug
    case info
    case `default`
    case error
}

public struct RileyLinkLogEntry: Identifiable {
    public let id = UUID()
    public let timestamp: Date
    public let category: String
    public let level: RileyLinkLogLevel
    public let message: String
}

public final class RileyLinkLogBuffer {
    public static let shared = RileyLinkLogBuffer()

    public let entriesDidChange = PassthroughSubject<Void, Never>()

    private let lock = NSLock()
    private var buffer: [RileyLinkLogEntry] = []
    private let maxEntries = 1000

    private init() {}

    public func append(_ entry: RileyLinkLogEntry) {
        lock.lock()
        buffer.append(entry)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
        lock.unlock()
        entriesDidChange.send()
    }

    public func allEntries() -> [RileyLinkLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    public func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        entriesDidChange.send()
    }

    public func formattedLog() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let entries = allEntries()
        return entries.map { entry in
            "[\(formatter.string(from: entry.timestamp))] [\(entry.level.rawValue.uppercased())] [\(entry.category)] \(entry.message)"
        }.joined(separator: "\n")
    }
}
