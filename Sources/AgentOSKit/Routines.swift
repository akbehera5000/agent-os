import Foundation

/// A job Agent OS runs on a schedule while it is open (it stays in the menu bar when the window is closed).
public struct Routine: Codable, Sendable, Identifiable, Hashable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case briefing        // speaks the daily briefing (local, free)
        case costDigest      // writes a weekly spend note to Basic Memory (local, free)
        case clutterWatch    // rescans and warns when clutter grows (local, free)
        case memoryCapture   // turns the latest finished session into a note (Claude Haiku)
        case prompt          // runs your own prompt with claude -p

        public var usesClaude: Bool { self == .memoryCapture || self == .prompt }
        public var label: String {
            switch self {
            case .briefing: "Spoken briefing"
            case .costDigest: "Cost digest note"
            case .clutterWatch: "Clutter watch"
            case .memoryCapture: "Memory capture"
            case .prompt: "Claude prompt"
            }
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var hour: Int
    public var minute: Int
    /// 1 = Sunday … 7 = Saturday (Calendar weekday). Empty means every day.
    public var weekdays: [Int]
    public var model: String
    public var prompt: String
    public var weeklyCapINR: Double
    public var enabled: Bool

    public init(id: String = UUID().uuidString, name: String, kind: Kind, hour: Int, minute: Int = 0, weekdays: [Int] = [],
                model: String = "haiku", prompt: String = "", weeklyCapINR: Double = 0, enabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.hour = hour; self.minute = minute; self.weekdays = weekdays
        self.model = model; self.prompt = prompt; self.weeklyCapINR = weeklyCapINR; self.enabled = enabled
    }

    public var cadence: String {
        let time = String(format: "%02d:%02d", hour, minute)
        if weekdays.isEmpty { return "Daily · \(time)" }
        if weekdays == [2, 3, 4, 5, 6] { return "Mon–Fri · \(time)" }
        let names = Calendar(identifier: .gregorian).shortWeekdaySymbols
        return weekdays.map { names[$0 - 1] }.joined(separator: ", ") + " · \(time)"
    }

    public func runs(on weekday: Int) -> Bool { weekdays.isEmpty || weekdays.contains(weekday) }

    /// The next time this routine fires strictly after `date`.
    public func nextRun(after date: Date, calendar: Calendar = .current) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if fire > date, runs(on: calendar.component(.weekday, from: fire)) { return fire }
        }
        return date.addingTimeInterval(86_400)
    }

    public static let templates: [Routine] = [
        Routine(id: "morning-briefing", name: "Morning Briefing", kind: .briefing, hour: 9),
        Routine(id: "memory-capture", name: "Daily Memory Capture", kind: .memoryCapture, hour: 18, model: "haiku", weeklyCapINR: 100, enabled: false),
        Routine(id: "cost-digest", name: "Weekly Cost Digest", kind: .costDigest, hour: 10, weekdays: [1]),
        Routine(id: "clutter-watch", name: "Clutter Watch", kind: .clutterWatch, hour: 11, weekdays: [7]),
    ]
}

/// One finished run, appended to runs.jsonl.
public struct RoutineRun: Codable, Sendable, Identifiable, Hashable {
    public var id: String { "\(routineID)-\(date.timeIntervalSince1970)" }
    public var routineID: String
    public var date: Date
    public var status: String          // "ok", "capped", "failed", "skipped"
    public var costUSD: Double
    public var summary: String

    public init(routineID: String, date: Date, status: String, costUSD: Double, summary: String) {
        self.routineID = routineID; self.date = date; self.status = status; self.costUSD = costUSD; self.summary = summary
    }
}

/// Routines and their run log, stored as JSON in Application Support.
public struct RoutineStore: Sendable {
    public let dir: URL
    public init(dir: URL) { self.dir = dir }

    var routinesURL: URL { dir.appending(path: "routines.json") }
    var runsURL: URL { dir.appending(path: "runs.jsonl") }

    public func load() -> [Routine] {
        guard let data = try? Data(contentsOf: routinesURL), let r = try? JSONDecoder().decode([Routine].self, from: data) else {
            return Routine.templates
        }
        return r
    }

    public func save(_ routines: [Routine]) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(routines).write(to: routinesURL, options: .atomic)
    }

    public func runs() -> [RoutineRun] {
        guard let data = try? Data(contentsOf: runsURL) else { return [] }
        let dec = JSONDecoder()
        return data.split(separator: 0x0A).compactMap { try? dec.decode(RoutineRun.self, from: Data($0)) }
    }

    public func append(_ run: RoutineRun) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var line = try JSONEncoder().encode(run)
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: runsURL) {
            try h.seekToEnd()
            try h.write(contentsOf: line)
            try h.close()
        } else {
            try line.write(to: runsURL)
        }
    }

    /// Rupees spent by a routine in the last 7 days.
    public static func weeklySpendINR(_ runs: [RoutineRun], routine: String, now: Date = .now) -> Double {
        runs.filter { $0.routineID == routine && $0.date > now.addingTimeInterval(-7 * 86_400) }.reduce(0) { $0 + $1.costUSD } * Format.inrPerUSD
    }
}
