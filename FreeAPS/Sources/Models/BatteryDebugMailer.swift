import Foundation
import Network
import UIKit

/// Sends battery-tracking debug reports by email so discharge-curve learning problems can be
/// diagnosed off-device. Uses a minimal SMTP-over-TLS client (smtp2go) — no Mail.app needed.
/// Credentials are injected at build time from CI secrets (Info.plist keys backed by the
/// SMTP_USERNAME/SMTP_PASSWORD build settings) and are blank in local builds.
enum BatteryDebugMailer {
    static let host = "mail.smtp2go.com"
    static let port: UInt16 = 465 // implicit SSL/TLS
    static let to = "brandon@parrishtech.net"

    private static var username: String {
        Bundle.main.object(forInfoDictionaryKey: "SMTPUsername") as? String ?? ""
    }

    private static var password: String {
        Bundle.main.object(forInfoDictionaryKey: "SMTPPassword") as? String ?? ""
    }

    static func send(subject: String, body: String) async throws {
        let username = username
        let password = password
        guard !username.isEmpty, !password.isEmpty else {
            throw SMTPError.notConfigured
        }
        let from = username
        try await withTimeout(seconds: 45) {
            let client = SMTPClient(host: host, port: port)
            defer { client.close() }
            try await client.connect()
            try await client.expectReply(220)
            try await client.command("EHLO iaps.debug", expect: 250)
            try await client.command("AUTH LOGIN", expect: 334)
            try await client.command(Data(username.utf8).base64EncodedString(), expect: 334)
            try await client.command(Data(password.utf8).base64EncodedString(), expect: 235)
            try await client.command("MAIL FROM:<\(from)>", expect: 250)
            try await client.command("RCPT TO:<\(to)>", expect: 250)
            try await client.command("DATA", expect: 354)
            try await client.command(message(from: from, subject: subject, body: body) + "\r\n.", expect: 250)
            try? await client.command("QUIT", expect: 221)
        }
    }

    private static func message(from: String, subject: String, body: String) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let headers = [
            "From: iAPS Debug <\(from)>",
            "To: \(to)",
            "Subject: \(subject)",
            "Date: \(dateFormatter.string(from: Date()))",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=utf-8",
            "Content-Transfer-Encoding: 8bit"
        ].joined(separator: "\r\n")
        // Normalize newlines and dot-stuff so a body line starting with "." can't end DATA.
        let normalizedBody = body
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix(".") ? ".\($0)" : String($0) }
            .joined(separator: "\r\n")
        return headers + "\r\n\r\n" + normalizedBody
    }

    private static func withTimeout(seconds: Double, _ operation: @escaping () async throws -> Void) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SMTPError.timeout
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

enum SMTPError: LocalizedError {
    case notConfigured
    case connectionFailed(String)
    case unexpectedReply(expected: Int, got: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "SMTP credentials not configured in this build"
        case let .connectionFailed(reason): return "SMTP connection failed: \(reason)"
        case let .unexpectedReply(expected, got): return "SMTP expected \(expected), got: \(got)"
        case .timeout: return "SMTP timed out"
        }
    }
}

/// Just enough SMTP to authenticate and hand over one plain-text message. Implicit TLS only.
final class SMTPClient {
    private let connection: NWConnection
    private var buffer = ""

    init(host: String, port: UInt16) {
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: NWParameters(tls: NWProtocolTLS.Options())
        )
    }

    func connect() async throws {
        final class Once { var done = false }
        let once = Once()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    once.done = true
                    continuation.resume()
                case let .failed(error):
                    once.done = true
                    continuation.resume(throwing: SMTPError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    once.done = true
                    continuation.resume(throwing: SMTPError.connectionFailed("cancelled"))
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "iAPS.smtp"))
        }
    }

    func close() {
        connection.cancel()
    }

    func command(_ line: String, expect: Int) async throws {
        try await send(line + "\r\n")
        try await expectReply(expect)
    }

    func expectReply(_ expected: Int) async throws {
        let reply = try await readReply()
        guard reply.code == expected else {
            throw SMTPError.unexpectedReply(expected: expected, got: reply.text)
        }
    }

    private func send(_ string: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(string.utf8), completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    /// Read one (possibly multi-line) SMTP reply. Complete when a line "NNN ..." (or bare
    /// "NNN") arrives — "NNN-..." lines are continuations.
    private func readReply() async throws -> (code: Int, text: String) {
        while true {
            if let reply = extractReply() { return reply }
            let chunk: Data = try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if isComplete {
                        continuation.resume(throwing: SMTPError.connectionFailed("connection closed"))
                    } else {
                        continuation.resume(returning: Data())
                    }
                }
            }
            buffer += String(decoding: chunk, as: UTF8.self)
        }
    }

    private func extractReply() -> (code: Int, text: String)? {
        let lines = buffer.components(separatedBy: "\r\n")
        var consumed = 0
        for line in lines.dropLast() { // last element is a trailing partial line (or "")
            consumed += 1
            guard let code = Int(line.prefix(3)), line.count >= 3 else { continue }
            let isFinal = line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " "
            if isFinal {
                let text = lines.prefix(consumed).joined(separator: "\n")
                buffer = lines.dropFirst(consumed).joined(separator: "\r\n")
                return (code, text)
            }
        }
        return nil
    }
}

/// Builds the plain-text battery debug report: config, summary, per-level first-seen times,
/// completed sessions, raw reading history, and the raw persisted JSON for both batteries.
enum BatteryDebugReport {
    static func compose(
        focus: BatteryDeviceKind,
        logs: [(kind: BatteryDeviceKind, log: BatteryDischargeLog?)],
        battery: Battery?,
        reservoir: Decimal?
    ) -> (subject: String, body: String) {
        let stamp = dateFormatter.string(from: Date())
        let subject = "iAPS Battery Debug — \(focus.title) — \(stamp)"

        var body = """
        iAPS battery debug report
        Opened from: \(focus.title)
        Generated: \(stamp) (\(TimeZone.current.identifier))
        App: \(appVersion())
        Device: \(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)
        Pump battery snapshot: percent=\(battery?.percent.map { "\($0)" } ?? "nil"), \
        voltage=\(battery?.voltage.map { "\($0)" } ?? "nil"), \
        expiration=\(battery?.batteryExpirationDate.map { dateFormatter.string(from: $0) } ?? "nil")
        Reservoir (raw pump units): \(reservoir.map { "\($0)" } ?? "nil")
        """

        for entry in logs {
            body += "\n\n" + section(kind: entry.kind, log: entry.log)
        }
        return (subject, body)
    }

    private static func section(kind: BatteryDeviceKind, log: BatteryDischargeLog?) -> String {
        let config = kind.config
        var out = """
        ================================================================
        == \(kind.title)
        ================================================================
        Config: replacementLow=\(config.replacementLowThreshold) replacementHigh=\(config.replacementHighThreshold) \
        granularity=\(config.levelGranularity) defaultLifetime=\(duration(config.defaultLifetime)) \
        defaultRange=\(config.defaultDepletedValue)–\(config.defaultFreshValue) maxCycles=\(config.maxStoredCycles)
        """

        guard let log = log else {
            return out + "\nNo log recorded yet (no readings ever received for this battery)."
        }

        let learned = BatteryDischargeTracker.averagedProfile(log.completedCycles)
        out += """

        Summary:
          replacementDate:      \(log.replacementDate.map { dateFormatter.string(from: $0) } ?? "nil")
          cycleIsLearnable:     \(log.cycleIsLearnable) \(log.cycleIsLearnable ? "(current session started at a detected replacement; will become a learned cycle at the NEXT replacement)" : "(synthetic first session — no replacement jump has been detected yet)")
          lastValue:            \(log.lastValue.map { voltage($0, kind) } ?? "nil") at \(log.lastValueDate.map { dateFormatter.string(from: $0) } ?? "nil")
          currentValueSince:    \(log.currentValueSince.map { dateFormatter.string(from: $0) } ?? "nil (no voltage change seen since this field was added)")
          estimateAnchor:       \(log.currentLevelTimes.min(by: { $0.level < $1.level }).map { "\(voltage(Double($0.level) * config.levelGranularity, kind)) band, first seen \(dateFormatter.string(from: $0.date))" } ?? "none (no levels recorded this cycle)")
          currentExpiration:    \(log.currentExpirationDate.map { dateFormatter.string(from: $0) } ?? "nil")
          completedCycles:      \(log.completedCycles.count)
          levelOverrides:       \(log.levelOverrides?.count ?? 0)
          learnedProfile:       \(learned.map { "lifetime=\(duration($0.lifetime)), \($0.offsets.count) levels" } ?? "none — estimate uses \(log.levelOverrides?.isEmpty == false ? "default curve + user edits" : "plain default-lifetime countdown")")
        """

        out += "\n\nCurrent session — first time seen at each level:"
        if log.currentLevelTimes.isEmpty {
            out += "\n  (none)"
        }
        for levelTime in log.currentLevelTimes {
            out += "\n  \(voltage(Double(levelTime.level) * config.levelGranularity, kind)) first seen \(dateFormatter.string(from: levelTime.date))"
        }

        out += "\n\nCompleted sessions:"
        if log.completedCycles.isEmpty {
            out += "\n  (none)"
        }
        for (index, cycle) in log.completedCycles.enumerated() {
            out += "\n  #\(index + 1): started \(cycle.startDate.map { dateFormatter.string(from: $0) } ?? "unknown"), lifetime \(duration(cycle.totalLifetime))"
            for offset in cycle.levelOffsets {
                out += "\n      \(voltage(Double(offset.level) * config.levelGranularity, kind)) at +\(duration(offset.secondsFromReplacement))"
            }
        }

        let history = log.readingHistory ?? []
        out += "\n\nRaw reading history (voltage changes only; last \(min(history.count, 300)) of \(history.count)):"
        if history.isEmpty {
            out += "\n  (empty — history recording was added recently; it fills as new readings arrive)"
        }
        for event in history.suffix(300) {
            out += "\n  \(dateFormatter.string(from: event.date))  \(voltage(event.value, kind))\(event.kind.map { "  <-- \($0.uppercased())" } ?? "")"
        }

        out += "\n\nRaw persisted JSON:\n" + rawJSON(log)
        return out
    }

    private static func rawJSON(_ log: BatteryDischargeLog) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(log) else { return "(encoding failed)" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static func voltage(_ value: Double, _ kind: BatteryDeviceKind) -> String {
        String(format: "%.\(max(kind.voltageFractionDigits, 2))f V", value)
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let absInterval = abs(interval)
        let days = Int(absInterval / 86400)
        let hours = Int(absInterval.truncatingRemainder(dividingBy: 86400) / 3600)
        let minutes = Int(absInterval.truncatingRemainder(dividingBy: 3600) / 60)
        let sign = interval < 0 ? "-" : ""
        return days >= 1 ? "\(sign)\(days)d\(hours)h" : "\(sign)\(hours)h\(minutes)m"
    }

    private static var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }
}
