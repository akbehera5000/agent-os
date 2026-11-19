import Foundation

/// Small text rules with no I/O, so they are unit-tested.
public enum TextRules {
    /// True when a user message reads like a correction of the AI ("no, I said…", "don't…").
    public static func isCorrection(_ raw: String) -> Bool {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count >= 12, t.count <= 500, !t.hasPrefix("<"), !t.hasPrefix("/"), !t.hasPrefix("[") else { return false }
        let starts = ["no,", "no.", "no ", "nope", "wrong", "stop ", "don't ", "dont ", "do not ", "never ", "not like that", "that's not", "thats not"]
        if starts.contains(where: t.hasPrefix) { return true }
        let anywhere = ["i said ", "i told you", "not what i", "why did you", "you should have", "you forgot", "instead of", "i asked for", "that is wrong", "you missed"]
        return anywhere.contains(where: t.contains)
    }

    /// Normalizes a folder name so copies of one project match: "EarHop-Windows" and "earhop" -> "earhop".
    public static func projectKey(_ name: String) -> String {
        var k = name.lowercased().filter { $0.isLetter || $0.isNumber }
        for suffix in ["windows", "win", "mac", "macos", "copy", "backup", "old", "main"] where k.hasSuffix(suffix) && k.count > suffix.count + 2 {
            k.removeLast(suffix.count)
        }
        return k
    }

    /// The project folder a working directory belongs to (worktrees fold into their repo).
    public static func projectRoot(_ cwd: String) -> String {
        if let r = cwd.range(of: "/.claude/worktrees/") { return String(cwd[..<r.lowerBound]) }
        if let r = cwd.range(of: "/.worktrees/") { return String(cwd[..<r.lowerBound]) }
        return cwd
    }

    /// A readable project name for a working folder: scratch areas get a label, generic folders keep their parent.
    public static func projectName(_ cwd: String) -> String {
        if cwd.contains("/scratch-workspaces/") { return "Claude scratch" }
        if cwd.contains("/.claude/spares/") { return "Spare workspace" }
        let url = URL(fileURLWithPath: projectRoot(cwd))
        let generic: Set<String> = ["plugins", "src", "app", "web", "server", "code", "client", "frontend", "backend"]
        return generic.contains(url.lastPathComponent.lowercased())
            ? "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)" : url.lastPathComponent
    }

    /// Reads `name:` / `description:` / `title:` from YAML front matter.
    public static func frontMatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            if line.hasPrefix("---") { break }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == "\"" || f == "'", value.last == f { value = String(value.dropFirst().dropLast()) }
            out[key] = value
        }
        return out
    }

    /// First line of a prompt, cleaned for display as a session title.
    public static func title(_ text: String, limit: Int = 90) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("@\"") } ?? text
        let clean = line.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return clean.count > limit ? String(clean.prefix(limit - 1)) + "…" : clean
    }

    public static func slug(_ s: String) -> String {
        let parts = s.lowercased().split { !($0.isLetter || $0.isNumber) }
        return parts.prefix(8).joined(separator: "-")
    }

    /// Adds a dated rule under "## Rules from corrections", creating the section if needed.
    public static func appendingRule(_ rule: String, to document: String, date: Date) -> String {
        let day = date.formatted(.iso8601.year().month().day())
        let line = "- \(rule.trimmingCharacters(in: .whitespacesAndNewlines)) (added \(day))"
        let header = "## Rules from corrections"
        var lines = document.components(separatedBy: "\n")
        guard let h = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
            let base = document.trimmingCharacters(in: .newlines)
            return (base.isEmpty ? "" : base + "\n\n") + header + "\n\n" + line + "\n"
        }
        // Insert after the last bullet of the section (before the next heading).
        var end = h + 1
        while end < lines.count, !lines[end].hasPrefix("#") { end += 1 }
        var insert = end
        while insert > h + 1, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
        lines.insert(line, at: insert)
        return lines.joined(separator: "\n")
    }
}
