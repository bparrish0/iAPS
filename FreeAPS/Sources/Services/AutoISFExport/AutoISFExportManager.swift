import Combine
import Foundation
import Swinject
import UIKit

/// One loop cycle's complete reason text. Core Data `Reasons` keeps only the parsed Auto ISF
/// components, so the full oref reason (predictions, SMB logic, the "Auto ISF { … }" notes) is
/// kept in a rolling file for the daily export.
struct LoopReasonRecord: JSON, Equatable {
    let date: Date
    let reason: String
}

enum LoopReasonHistory {
    static let retention: TimeInterval = 8 * 86400

    static func append(_ reason: String, at date: Date, storage: FileStorage) {
        let cutoff = date.addingTimeInterval(-retention)
        var records = (storage.retrieve(OpenAPS.Monitor.loopReasonHistory, as: [LoopReasonRecord].self) ?? [])
            .filter { $0.date > cutoff }
        records.append(LoopReasonRecord(date: date, reason: reason))
        storage.save(records, as: OpenAPS.Monitor.loopReasonHistory)
    }
}

/// Posts the Auto ISF history (every loop cycle's Auto ISF ratio, components, insulin decisions
/// and full reason text) plus a settings snapshot to a Relayboard workspace, one post per local
/// calendar day, so the tuning can be analysed off-device.
protocol AutoISFExportManager {
    var lastExportStatus: String? { get }
    /// Post the last `days` completed local calendar days, plus today so far when `includeToday`.
    /// Returns a short human-readable status.
    func export(days: Int, includeToday: Bool) async -> String
}

/// One loop cycle in the export: the `Reasons` row joined with its full reason text.
struct AutoISFExportCycle: JSON {
    let date: Date
    let glucose: Decimal?
    let ratio: Decimal?
    let autoISF: String?
    let isf: Decimal?
    let cr: Decimal?
    let iob: Decimal?
    let cob: Decimal?
    let target: Decimal?
    let eventualBG: Decimal?
    let minPredBG: Decimal?
    let insulinReq: Decimal?
    let rate: Decimal?
    let smb: Decimal?
    let tdd: Decimal?
    let override: Bool
    let mmol: Bool
    let reason: String?
}

struct AutoISFExportHeader: JSON {
    let format: String
    let app: String
    let device: String
    let generated: Date
    let timeZone: String
    let day: String
    let from: Date
    let to: Date
    let part: Int
    let parts: Int
    let cycleCount: Int
    /// Settings ride along in part 1 only.
    let settings: FreeAPSSettings?
    let preferences: Preferences?
    let basalProfile: RawJSON?
    let insulinSensitivities: RawJSON?
    let carbRatios: RawJSON?
    let bgTargets: RawJSON?
}

struct AutoISFExportPart: JSON {
    let header: AutoISFExportHeader
    let cycles: [AutoISFExportCycle]
}

enum AutoISFExportError: LocalizedError {
    case invalidURL
    case badResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Relayboard URL is not valid"
        case let .badResponse(detail): return detail
        }
    }
}

final class BaseAutoISFExportManager: AutoISFExportManager, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var broadcaster: Broadcaster!

    /// Day key ("yyyy-MM-dd", local) of the most recent *completed* day that has been posted.
    @Persisted(key: "AutoISFExport.lastExportDay") private var lastExportDay: String? = nil
    @Persisted(key: "AutoISFExport.lastExportStatus") private(set) var lastExportStatus: String? = nil

    private let coreDataStorage = CoreDataStorage()
    private var exporting = false
    private var lastAutoAttempt: Date = .distantPast

    static let workspaceTitle = "iAPS / Auto ISF History"
    static let format = "iaps-autoisf-history/1"
    /// Relayboard caps a post body at 200,000 characters; leave room for the settings header.
    static let maxPostBody = 150_000
    static let maxCatchUpDays = 7
    /// Don't hammer an unreachable board: retry a failed automatic export no sooner than this.
    static let retryInterval: TimeInterval = 30 * 60
    /// Full reason texts are matched to `Reasons` rows by nearest timestamp within this window.
    static let reasonMatchTolerance: TimeInterval = 90

    init(resolver: Resolver) {
        injectServices(resolver)
        broadcaster.register(SuggestionObserver.self, observer: self)
    }

    // MARK: - Public

    func export(days: Int, includeToday: Bool) async -> String {
        guard !exporting else { return "Export already running" }
        exporting = true
        defer { exporting = false }

        guard let base = Self.baseURL(settingsManager.settings.relayboardURL) else {
            return finish("Failed: " + (AutoISFExportError.invalidURL.errorDescription ?? ""))
        }
        let calendar = Calendar.current
        let now = Date()
        let todayStart = calendar.startOfDay(for: now)
        var dayStarts: [Date] = (1 ... max(1, days)).reversed()
            .compactMap { calendar.date(byAdding: .day, value: -$0, to: todayStart) }
        if includeToday { dayStarts.append(todayStart) }

        do {
            let workspace = try await ensureWorkspace(base: base)
            var posted = 0
            for start in dayStarts {
                let end = min(calendar.date(byAdding: .day, value: 1, to: start) ?? now, now)
                posted += try await exportDay(start: start, end: end, base: base, parentID: workspace)
                if start < todayStart {
                    lastExportDay = Self.dayKey(start)
                }
            }
            return finish("Posted \(posted) post(s) for \(dayStarts.count) day(s), \(Self.timeString(now))")
        } catch {
            return finish("Failed: \(error.localizedDescription), \(Self.timeString(now))")
        }
    }

    // MARK: - Automatic daily export

    /// Runs on every loop cycle; posts each completed day once, the first cycle after local
    /// midnight, catching up any days missed while the board was unreachable.
    private func autoExportIfDue() async {
        guard settingsManager.settings.autoISFDailyExport else { return }
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) else { return }
        guard lastExportDay != Self.dayKey(yesterday) else { return }
        guard Date().timeIntervalSince(lastAutoAttempt) > Self.retryInterval else { return }
        lastAutoAttempt = Date()

        var days = 1
        if let last = lastExportDay, let lastDate = Self.date(fromDayKey: last) {
            let elapsed = calendar.dateComponents([.day], from: lastDate, to: todayStart).day ?? 2
            days = max(1, min(Self.maxCatchUpDays, elapsed - 1))
        }
        _ = await export(days: days, includeToday: false)
    }

    // MARK: - Building the document

    private func exportDay(start: Date, end: Date, base: URL, parentID: Int) async throws -> Int {
        let cycles = cycles(from: start, to: end)
        guard !cycles.isEmpty else { return 0 }

        // Chunk so no post exceeds the board's body limit, however often the loop ran.
        let encoder = Self.compactEncoder
        var chunks: [[AutoISFExportCycle]] = [[]]
        var size = 0
        for cycle in cycles {
            let length = (try? encoder.encode(cycle).count) ?? 0
            if size + length > Self.maxPostBody, !chunks[chunks.count - 1].isEmpty {
                chunks.append([])
                size = 0
            }
            chunks[chunks.count - 1].append(cycle)
            size += length + 1
        }

        let day = Self.dayKey(start)
        for (index, chunk) in chunks.enumerated() {
            let header = makeHeader(
                day: day, from: start, to: end,
                part: index + 1, parts: chunks.count,
                cycleCount: cycles.count, includeSettings: index == 0
            )
            let data = try encoder.encode(AutoISFExportPart(header: header, cycles: chunk))
            let body = String(decoding: data, as: UTF8.self)
            let title = chunks.count == 1
                ? "Auto ISF history \(day)"
                : "Auto ISF history \(day) (part \(index + 1) of \(chunks.count))"
            _ = try await createPost(base: base, parentID: parentID, title: title, body: body)
        }
        return chunks.count
    }

    private func makeHeader(
        day: String, from: Date, to: Date,
        part: Int, parts: Int, cycleCount: Int, includeSettings: Bool
    ) -> AutoISFExportHeader {
        AutoISFExportHeader(
            format: Self.format,
            app: Self.appVersion,
            device: UIDevice.current.getDeviceId,
            generated: Date(),
            timeZone: TimeZone.current.identifier,
            day: day,
            from: from,
            to: to,
            part: part,
            parts: parts,
            cycleCount: cycleCount,
            settings: includeSettings ? settingsManager.settings : nil,
            preferences: includeSettings ? settingsManager.preferences : nil,
            basalProfile: includeSettings ? storage.retrieveRaw(OpenAPS.Settings.basalProfile) : nil,
            insulinSensitivities: includeSettings ? storage.retrieveRaw(OpenAPS.Settings.insulinSensitivities) : nil,
            carbRatios: includeSettings ? storage.retrieveRaw(OpenAPS.Settings.carbRatios) : nil,
            bgTargets: includeSettings ? storage.retrieveRaw(OpenAPS.Settings.bgTargets) : nil
        )
    }

    private func cycles(from start: Date, to end: Date) -> [AutoISFExportCycle] {
        let rows = coreDataStorage.fetchReasons(interval: start as NSDate)
            .filter { ($0.date ?? .distantPast) < end }
            .sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        let fullReasons = (storage.retrieve(OpenAPS.Monitor.loopReasonHistory, as: [LoopReasonRecord].self) ?? [])
            .filter { $0.date >= start.addingTimeInterval(-Self.reasonMatchTolerance) && $0.date <= end }
            .sorted { $0.date < $1.date }

        var cursor = 0
        return rows.map { row in
            let date = row.date ?? .distantPast
            // Both lists are time-ordered; advance a cursor to the nearest full reason.
            while cursor + 1 < fullReasons.count,
                  abs(fullReasons[cursor + 1].date.timeIntervalSince(date)) <= abs(fullReasons[cursor].date.timeIntervalSince(date))
            {
                cursor += 1
            }
            let matched = fullReasons.indices.contains(cursor)
                && abs(fullReasons[cursor].date.timeIntervalSince(date)) <= Self.reasonMatchTolerance
                ? fullReasons[cursor].reason : nil
            return AutoISFExportCycle(
                date: date,
                glucose: Self.decimal(row.glucose),
                ratio: Self.decimal(row.ratio),
                autoISF: row.reasons,
                isf: Self.decimal(row.isf),
                cr: Self.decimal(row.cr),
                iob: Self.decimal(row.iob),
                cob: Self.decimal(row.cob),
                target: Self.decimal(row.target),
                eventualBG: Self.decimal(row.eventualBG),
                minPredBG: Self.decimal(row.minPredBG),
                insulinReq: Self.decimal(row.insulinReq),
                rate: Self.decimal(row.rate),
                smb: Self.decimal(row.smb),
                tdd: Self.decimal(row.tdd),
                override: row.override,
                mmol: row.mmol,
                reason: matched
            )
        }
    }

    // MARK: - Relayboard client

    private struct RBPost: Decodable {
        let id: Int
        let title: String
    }

    private struct RBList: Decodable { let posts: [RBPost] }
    private struct RBSingle: Decodable { let post: RBPost }

    private func ensureWorkspace(base: URL) async throws -> Int {
        let list: RBList = try await request(base.appendingPathComponent("api/posts"), method: "GET", body: nil)
        if let existing = list.posts.first(where: { $0.title == Self.workspaceTitle }) {
            return existing.id
        }
        return try await createPost(
            base: base,
            parentID: nil,
            title: Self.workspaceTitle,
            body: "Daily Auto ISF loop-cycle history posted automatically by iAPS (format \(Self.format)). " +
                "Each child note is one local calendar day: a header with the app's settings snapshot, " +
                "then every loop cycle's Auto ISF ratio and components, insulin decisions, and full reason text."
        )
    }

    private func createPost(base: URL, parentID: Int?, title: String, body: String) async throws -> Int {
        var payload: [String: Any] = [
            "title": title,
            "body": body,
            "author": "iAPS",
            "model": "iAPS \(Self.appVersion)"
        ]
        if let parentID = parentID {
            payload["parent_id"] = parentID
            payload["kind"] = "note"
        }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let single: RBSingle = try await request(base.appendingPathComponent("api/posts"), method: "POST", body: data)
        return single.post.id
    }

    private func request<T: Decodable>(_ url: URL, method: String, body: Data?) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("iAPS", forHTTPHeaderField: "X-LLM-Name")
        request.setValue("iAPS \(Self.appVersion)", forHTTPHeaderField: "X-LLM-Model")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AutoISFExportError.badResponse("no HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let detail = String(decoding: data.prefix(200), as: UTF8.self)
            throw AutoISFExportError.badResponse("HTTP \(http.statusCode) \(detail)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Helpers

    private func finish(_ status: String) -> String {
        lastExportStatus = status
        debug(.service, "Auto ISF export: \(status)")
        return status
    }

    private static func baseURL(_ string: String) -> URL? {
        var trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil
        else { return nil }
        return url
    }

    private static var compactEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        encoder.dateEncodingStrategy = .customISO8601
        return encoder
    }

    private static func decimal(_ number: NSDecimalNumber?) -> Decimal? {
        number.map { $0 as Decimal }
    }

    private static var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    static func dayKey(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func date(fromDayKey key: String) -> Date? {
        dayFormatter.date(from: key)
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

extension BaseAutoISFExportManager: SuggestionObserver {
    func suggestionDidUpdate(_: Suggestion) {
        Task { await self.autoExportIfDue() }
    }
}
