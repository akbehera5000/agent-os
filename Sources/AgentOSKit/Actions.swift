import Foundation

/// The only code that changes files outside the app. Every call is user-initiated from a confirm sheet.
public enum Actions {
    public enum Failure: LocalizedError {
        case exists(String), missing(String)
        public var errorDescription: String? {
            switch self {
            case .exists(let p): "Already exists: \(p)"
            case .missing(let p): "Not found: \(p)"
            }
        }
    }

    /// Appends a rule to each instruction file (creates the file if missing). Returns the files written.
    @discardableResult
    public static func addRule(_ rule: String, toTools ids: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [String] {
        var written: [String] = []
        for id in ids {
            guard let rel = ToolCatalog.spec(id)?.instructions else { continue }
            let url = home.appending(path: rel)
            let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TextRules.appendingRule(rule, to: old, date: .now).write(to: url, atomically: true, encoding: .utf8)
            written.append(url.path)
        }
        return written
    }

    /// Copies a skill folder (following a symlink) into another tool's skills folder.
    public static func installSkill(from path: String, name: String, toTool id: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        guard let dir = ToolCatalog.spec(id)?.skillDirs.first else { throw Failure.missing(id) }
        let target = home.appending(path: dir).appending(path: URL(fileURLWithPath: path).lastPathComponent)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw Failure.exists(target.path) }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: path).resolvingSymlinksInPath(), to: target)
        return target.path
    }

    /// Retires a skill: moves its folder to ~/.agentos/retired-skills/<tool>/ so no app loads it. Move it back to restore.
    public static func retireSkill(path: String, tool: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        let src = URL(fileURLWithPath: path)
        let dir = home.appending(path: ".agentos/retired-skills/\(tool)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var dest = dir.appending(path: src.lastPathComponent)
        if FileManager.default.fileExists(atPath: dest.path) { dest = dir.appending(path: src.lastPathComponent + "-\(Int(Date.now.timeIntervalSince1970))") }
        try FileManager.default.moveItem(at: src, to: dest)
        return dest.path
    }

    /// Moves a file or folder to the Trash (recoverable).
    public static func trash(_ path: String) throws {
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
    }

    /// Writes a Basic Memory note: ~/basic-memory/<folder>/<slug>.md
    public static func writeNote(title: String, body: String, folder: String, tags: [String],
                                 home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> String {
        let dir = home.appending(path: "basic-memory").appending(path: folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appending(path: TextRules.slug(title) + ".md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) { url = dir.appending(path: "\(TextRules.slug(title))-\(n).md"); n += 1 }
        let tagLine = tags.map { "\"\($0)\"" }.joined(separator: ", ")
        let doc = """
        ---
        title: \(title)
        type: note
        tags: [\(tagLine)]
        ---

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        try doc.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// A double-clickable script that resumes a session in Terminal, in its own folder.
    public static func resumeScript(for session: Session) throws -> URL {
        let cmd = session.tool == "codex" ? "codex resume \(session.id)" : "claude --resume \(session.id)"
        let dir = session.cwd.replacingOccurrences(of: "'", with: "'\\''")
        let script = "#!/bin/zsh -l\ncd '\(dir)' && \(cmd)\n"
        let url = FileManager.default.temporaryDirectory.appending(path: "agentos-resume-\(session.id.prefix(8)).command")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

/// Numbers derived from a snapshot: rolling windows, daily totals, briefing.
public enum Analytics {
    public static func tokens(in sessions: [Session], since: Date) -> (tokens: Int, cost: Double) {
        var t = 0, c = 0.0
        for s in sessions where s.end >= since {
            for p in s.points where p.date >= since { t += p.tokens; c += p.cost }
        }
        return (t, c)
    }

    /// Cost per day for the last `days` days, oldest first.
    public static func daily(_ sessions: [Session], days: Int, now: Date = .now) -> [(day: Date, cost: Double, tokens: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var map: [Date: (Double, Int)] = [:]
        let since = cal.date(byAdding: .day, value: -(days - 1), to: today)!
        for s in sessions where s.end >= since {
            for p in s.points where p.date >= since {
                let d = cal.startOfDay(for: p.date)
                map[d, default: (0, 0)].0 += p.cost
                map[d, default: (0, 0)].1 += p.tokens
            }
        }
        return (0..<days).map { i in
            let d = cal.date(byAdding: .day, value: i, to: since)!
            return (d, map[d]?.0 ?? 0, map[d]?.1 ?? 0)
        }
    }

    /// Time the 1-hour prompt cache stays warm after the last Claude activity.
    public static func cacheRemaining(_ sessions: [Session], now: Date = .now, ttl: TimeInterval = 3600) -> TimeInterval {
        guard let last = sessions.first(where: { $0.tool == "claude-code" })?.end else { return 0 }
        return max(0, ttl - now.timeIntervalSince(last))
    }

    public static func greeting(_ now: Date = .now) -> String {
        switch Calendar.current.component(.hour, from: now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Working late"
        }
    }

    /// A spoken / written daily briefing built from local data. Costs no tokens.
    public static func briefing(_ s: Snapshot, name: String, now: Date = .now) -> String {
        let today = Calendar.current.startOfDay(for: now)
        let todays = tokens(in: s.sessions, since: today)
        let week = tokens(in: s.sessions, since: now.addingTimeInterval(-7 * 86_400))
        let active = s.projects.filter { $0.lastActive > now.addingTimeInterval(-3 * 86_400) }.prefix(3).map(\.name)
        let missing = s.connectors.filter { $0.health == .missing }.count
        let clutter = s.clutter.reduce(Int64(0)) { $0 + $1.bytes }
        var parts = ["\(greeting(now)), \(name)."]
        parts.append("Today you've used \(Format.tokens(todays.tokens)) tokens, about \(Format.money(todays.cost)) at API rates; \(Format.money(week.cost)) this week.")
        if !active.isEmpty { parts.append("Active projects: \(active.joined(separator: ", ")).") }
        if !s.corrections.isEmpty { parts.append("\(s.corrections.count) corrections are waiting to become rules.") }
        if missing > 0 { parts.append("\(missing) connector\(missing == 1 ? " is" : "s are") broken.") }
        if clutter > 500_000_000 { parts.append("You can free \(Format.bytes(clutter)) of clutter.") }
        return parts.joined(separator: " ")
    }
}
