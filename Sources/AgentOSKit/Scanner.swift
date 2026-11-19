import Foundation

/// Reads every AI tool's files under `home` and builds a `Snapshot`. Read-only.
/// Session logs are parsed in parallel across all performance cores and cached by
/// file size + modification date, so a rescan only parses files that changed.
public struct Scanner: Sendable {
    public let home: URL
    public let cacheURL: URL?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, cacheURL: URL? = nil) {
        self.home = home
        self.cacheURL = cacheURL
    }

    private func path(_ rel: String) -> String { home.appending(path: rel).path }

    public func scan() async -> Snapshot {
        async let sessionsTask = scanSessions()
        async let skillsTask = Task.detached(priority: .userInitiated) { scanSkills() }.value
        async let connectorsTask = Task.detached(priority: .userInitiated) { scanConnectors() }.value
        async let notesTask = Task.detached(priority: .utility) { scanNotes() }.value
        async let assetsTask = Task.detached(priority: .utility) { scanAssets() }.value
        async let ollamaTask = ollamaStatus()

        let sessions = await sessionsTask
        let skills = await skillsTask
        let connectors = await connectorsTask
        let projects = buildProjects(sessions)
        let corrections = sessions.flatMap { s in
            s.corrections.enumerated().map { i, text in
                Correction(id: "\(s.id)-\(i)", text: text, project: TextRules.projectName(s.cwd),
                           date: s.end, sessionID: s.id)
            }
        }.sorted { $0.date > $1.date }
        let clutter = await Task.detached(priority: .utility) { scanClutter(sessions: sessions, projects: projects) }.value
        let (models, running) = await ollamaTask
        let tools = buildTools(sessions: sessions, skills: skills, connectors: connectors)
        let docs = await Task.detached(priority: .utility) { scanDocs(projects: projects) }.value

        var snap = Snapshot(scannedAt: .now, tools: tools, sessions: sessions, projects: projects, skills: skills,
                        connectors: connectors, corrections: corrections, notes: await notesTask, clutter: clutter,
                        assets: await assetsTask, localModels: models, ollamaRunning: running)
        snap.docs = docs
        return snap
    }

    // MARK: Docs (instructions + memory)

    func scanDocs(projects: [Project]) -> [Doc] {
        let fm = FileManager.default
        var out: [Doc] = []
        var seen = Set<String>()
        func add(_ path: String, _ kind: String, _ tool: String, title: String? = nil) {
            guard seen.insert(path).inserted, let a = try? fm.attributesOfItem(atPath: path) else { return }
            let name = URL(fileURLWithPath: path).lastPathComponent
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent
            out.append(Doc(path: path, title: title ?? "\(parent)/\(name)", kind: kind, tool: tool,
                           bytes: (a[.size] as? Int) ?? 0, modified: (a[.modificationDate] as? Date) ?? .distantPast))
        }
        for spec in ToolCatalog.ruleTargets { if let rel = spec.instructions { add(path(rel), "Rules", spec.id, title: "~/" + rel) } }
        for p in projects {
            for loc in p.locations {
                for f in ["CLAUDE.md", "AGENTS.md", "GEMINI.md", ".claude/CLAUDE.md"] {
                    add("\(loc)/\(f)", "Project rules", f.contains("GEMINI") ? "gemini" : f.contains("AGENTS") ? "codex" : "claude-code", title: "\(p.name)/\(f)")
                }
            }
        }
        // Claude Code auto-memory: ~/.claude/projects/<project>/memory/*.md
        for dir in (try? fm.contentsOfDirectory(at: home.appending(path: ".claude/projects"), includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir.appending(path: "memory"), includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "md" {
                add(f.path, "Auto memory", "claude-code")
            }
        }
        return out.sorted { $0.modified > $1.modified }
    }

    // MARK: Live activity

    /// The latest actions from the most recent Claude Code sessions, newest first. Reads only file tails.
    public func activity(limit: Int = 40) -> [Activity] {
        let fm = FileManager.default
        let root = home.appending(path: ".claude/projects")
        var files: [(URL, Date)] = []
        for dir in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where f.pathExtension == "jsonl" {
                if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate { files.append((f, d)) }
            }
        }
        var out: [Activity] = []
        for (f, _) in files.sorted(by: { $0.1 > $1.1 }).prefix(3) {
            guard let h = try? FileHandle(forReadingFrom: f) else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 120_000 ? size - 120_000 : 0)
            let data = (try? h.readToEnd()) ?? Data()
            try? h.close()
            var n = 0
            Self.lines(data) { line in
                guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let ts = Self.date(o["timestamp"]) else { return }
                let project = TextRules.projectName(o["cwd"] as? String ?? "")
                let msg = o["message"] as? [String: Any]
                if (o["type"] as? String) == "user", let t = Self.text(of: msg?["content"]), !t.hasPrefix("<"), !t.hasPrefix("Base directory for this skill") {
                    n += 1
                    out.append(Activity(id: "\(f.lastPathComponent)-\(n)", date: ts, verb: "ASK", target: TextRules.title(t, limit: 70), project: project))
                }
                for b in (msg?["content"] as? [[String: Any]]) ?? [] where (b["type"] as? String) == "tool_use" {
                    let input = b["input"] as? [String: Any] ?? [:]
                    let target = (input["file_path"] ?? input["command"] ?? input["pattern"] ?? input["skill"] ?? input["url"] ?? input["description"] ?? input["query"]) as? String ?? ""
                    let short = target.hasPrefix("/") ? URL(fileURLWithPath: target).lastPathComponent : TextRules.title(target, limit: 60)
                    n += 1
                    out.append(Activity(id: "\(f.lastPathComponent)-\(n)", date: ts, verb: String(((b["name"] as? String) ?? "TOOL").split(separator: "_").last ?? "TOOL").uppercased(), target: short, project: project))
                }
            }
        }
        return Array(out.sorted { $0.date > $1.date }.prefix(limit))
    }

    // MARK: Sessions

    private struct CacheEntry: Codable { var size: Int; var mtime: Double; var sessions: [Session] }

    func scanSessions() async -> [Session] {
        let fm = FileManager.default
        var files: [(url: URL, tool: String)] = []
        let claudeRoot = home.appending(path: ".claude/projects")
        for dir in (try? fm.contentsOfDirectory(at: claudeRoot, includingPropertiesForKeys: nil)) ?? [] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "jsonl" {
                files.append((f, "claude-code"))
            }
        }
        if let e = fm.enumerator(at: home.appending(path: ".codex/sessions"), includingPropertiesForKeys: nil) {
            for case let f as URL in e.allObjects where f.lastPathComponent.hasPrefix("rollout-") { files.append((f, "codex")) }
        }

        var cache: [String: CacheEntry] = [:]
        if let cacheURL, let data = try? Data(contentsOf: cacheURL) {
            cache = (try? JSONDecoder().decode([String: CacheEntry].self, from: data)) ?? [:]
        }
        let codexTitles = codexThreadNames()
        let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first { fm.isExecutableFile(atPath: $0) }

        let results = await withTaskGroup(of: (String, CacheEntry?).self) { group in
            for (url, tool) in files {
                let attrs = try? fm.attributesOfItem(atPath: url.path)
                let size = (attrs?[.size] as? Int) ?? 0
                let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                if let hit = cache[url.path], hit.size == size, hit.mtime == mtime {
                    group.addTask { (url.path, hit) }
                    continue
                }
                group.addTask(priority: .userInitiated) {
                    let parsed: [Session]
                    if tool == "codex" {
                        parsed = Self.parseCodex(url, zstd: zstd, titles: codexTitles).map { [$0] } ?? []
                    } else {
                        parsed = Self.parseClaude(url).map { [$0] } ?? []
                    }
                    return (url.path, CacheEntry(size: size, mtime: mtime, sessions: parsed))
                }
            }
            var out: [String: CacheEntry] = [:]
            for await (k, v) in group { if let v { out[k] = v } }
            return out
        }
        if let cacheURL, let data = try? JSONEncoder().encode(results) {
            try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
        }
        return results.values.flatMap(\.sessions).sorted { $0.end > $1.end }
    }

    // ISO8601DateFormatter is documented thread-safe; parse() runs on many threads at once.
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let isoPlain = ISO8601DateFormatter()

    private static func date(_ any: Any?) -> Date? {
        guard let s = any as? String else { return nil }
        return iso.date(from: s) ?? isoPlain.date(from: s)
    }

    /// Splits a file into lines without copying it into a String first.
    private static func lines(_ data: Data, _ body: (Data) -> Void) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var start = 0
            let count = raw.count
            while start < count {
                let rest = UnsafeRawBufferPointer(start: base + start, count: count - start)
                let nl = rest.firstIndex(of: 0x0A) ?? rest.count
                if nl > 0 { body(Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: base + start), count: nl, deallocator: .none)) }
                start += nl + 1
            }
        }
    }

    private static func text(of content: Any?) -> String? {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            if arr.contains(where: { ($0["type"] as? String) == "tool_result" }) { return nil }
            return arr.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first
        }
        return nil
    }

    /// One Claude Code session: tokens, API-equivalent cost, title, corrections.
    static func parseClaude(_ url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return nil }
        var usage = Usage()
        var seen = Set<String>()
        var buckets: [Date: UsagePoint] = [:]
        var start: Date?, end: Date?
        var cwd = "", model = "", title = "", summary = "", branch: String?
        var messages = 0
        var corrections: [String] = []
        var skillUse: [String: Usage] = [:]
        var activeSkill: String?
        let sessionID = url.deletingPathExtension().lastPathComponent

        lines(data) { line in
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            let type = obj["type"] as? String
            if type == "summary", let s = obj["summary"] as? String { summary = s; return }
            if cwd.isEmpty, let c = obj["cwd"] as? String { cwd = c }
            if branch == nil, let b = obj["gitBranch"] as? String, !b.isEmpty { branch = b }
            guard let ts = date(obj["timestamp"]) else { return }
            start = min(start ?? ts, ts); end = max(end ?? ts, ts)
            let msg = obj["message"] as? [String: Any]
            if type == "user", (obj["isMeta"] as? Bool) != true, let t = text(of: msg?["content"]) {
                // A typed /skill command starts a skill turn; any other prompt ends it.
                if let r = t.range(of: "<command-name>/"), let e = t.range(of: "</command-name>", range: r.upperBound..<t.endIndex) {
                    activeSkill = String(t[r.upperBound..<e.lowerBound])
                } else if !t.hasPrefix("<") {
                    activeSkill = nil
                }
                messages += 1
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if title.isEmpty, !trimmed.hasPrefix("<"), !trimmed.hasPrefix("Base directory for this skill"), !trimmed.isEmpty { title = TextRules.title(trimmed) }
                if corrections.count < 6, TextRules.isCorrection(trimmed) { corrections.append(TextRules.title(trimmed, limit: 240)) }
            }
            guard type == "assistant", let msg, let u = msg["usage"] as? [String: Any] else { return }
            // Claude Code writes one line per content block with the same usage: count each message once.
            let mid = (msg["id"] as? String) ?? (obj["requestId"] as? String) ?? UUID().uuidString
            guard seen.insert(mid).inserted else { return }
            if let m = msg["model"] as? String, !m.hasPrefix("<") { model = m }
            let input = u["input_tokens"] as? Int ?? 0
            let output = u["output_tokens"] as? Int ?? 0
            let read = u["cache_read_input_tokens"] as? Int ?? 0
            let creation = u["cache_creation"] as? [String: Any]
            let w1h = creation?["ephemeral_1h_input_tokens"] as? Int ?? 0
            let w5m = creation?["ephemeral_5m_input_tokens"] as? Int ?? max(0, (u["cache_creation_input_tokens"] as? Int ?? 0) - w1h)
            let cost = Pricing.cost(model: model, input: input, output: output, cacheWrite5m: w5m, cacheWrite1h: w1h, cacheRead: read)
            usage.input += input; usage.output += output; usage.cacheWrite += w5m + w1h; usage.cacheRead += read; usage.cost += cost
            // 10-minute buckets keep the rolling windows accurate without storing every message.
            let bucket = Date(timeIntervalSince1970: (ts.timeIntervalSince1970 / 600).rounded(.down) * 600)
            var p = buckets[bucket] ?? UsagePoint(date: bucket, tokens: 0, cost: 0)
            p.tokens += input + output + w5m + w1h + read; p.cost += cost
            buckets[bucket] = p
            // Tokens spent after a skill is invoked (until the next prompt) belong to that skill.
            if let skill = activeSkill {
                var su = skillUse[skill] ?? Usage()
                su.input += input; su.output += output; su.cacheWrite += w5m + w1h; su.cacheRead += read; su.cost += cost
                skillUse[skill] = su
            }
            if let content = msg["content"] as? [[String: Any]] {
                for block in content where (block["type"] as? String) == "tool_use" && (block["name"] as? String) == "Skill" {
                    if let s = (block["input"] as? [String: Any])?["skill"] as? String {
                        activeSkill = s
                        var su = skillUse[s] ?? Usage()
                        su.runs += 1
                        skillUse[s] = su
                    }
                }
            }
        }
        guard let start, let end, !cwd.isEmpty else { return nil }
        let name = summary.isEmpty ? (title.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : title) : summary
        return Session(id: sessionID, tool: "claude-code", cwd: cwd, title: name, start: start, end: end, model: model,
                       usage: usage, points: buckets.values.sorted { $0.date < $1.date }, messages: messages,
                       branch: branch, file: url.path, corrections: corrections, skillUse: skillUse)
    }

    func codexThreadNames() -> [String: String] {
        guard let data = try? Data(contentsOf: home.appending(path: ".codex/session_index.jsonl")) else { return [:] }
        var out: [String: String] = [:]
        Self.lines(data) { line in
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = o["id"] as? String, let n = o["thread_name"] as? String else { return }
            out[id] = n
        }
        return out
    }

    /// One Codex session. Codex runs on a ChatGPT plan, so tokens are counted but cost stays 0.
    static func parseCodex(_ url: URL, zstd: String?, titles: [String: String]) -> Session? {
        var data: Data?
        if url.pathExtension == "zst" {
            guard let zstd else { return nil }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: zstd)
            p.arguments = ["-dcq", url.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
        } else {
            data = try? Data(contentsOf: url, options: .mappedIfSafe)
        }
        guard let data, !data.isEmpty else { return nil }
        var id = "", cwd = "", model = "", firstPrompt = ""
        var start: Date?, end: Date?
        var usage = Usage()
        var points: [UsagePoint] = []
        var messages = 0
        var corrections: [String] = []
        lines(data) { line in
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return }
            let ts = date(o["timestamp"])
            if let ts { start = min(start ?? ts, ts); end = max(end ?? ts, ts) }
            let payload = o["payload"] as? [String: Any] ?? [:]
            switch (o["type"] as? String, payload["type"] as? String) {
            case ("session_meta", _):
                id = payload["id"] as? String ?? id
                cwd = payload["cwd"] as? String ?? cwd
            case ("turn_context", _):
                if cwd.isEmpty { cwd = payload["cwd"] as? String ?? "" }
            case ("event_msg", "thread_settings_applied"):
                model = (payload["thread_settings"] as? [String: Any])?["model"] as? String ?? model
            case ("event_msg", "user_message"):
                if let t = payload["message"] as? String {
                    messages += 1
                    if firstPrompt.isEmpty { firstPrompt = TextRules.title(t) }
                    if corrections.count < 6, TextRules.isCorrection(t) { corrections.append(TextRules.title(t, limit: 240)) }
                }
            case ("event_msg", "token_count"):
                let info = payload["info"] as? [String: Any]
                if let total = info?["total_token_usage"] as? [String: Any] {
                    let cached = total["cached_input_tokens"] as? Int ?? 0
                    usage.input = (total["input_tokens"] as? Int ?? 0) - cached
                    usage.cacheRead = cached
                    usage.output = total["output_tokens"] as? Int ?? 0
                }
                if let last = info?["last_token_usage"] as? [String: Any], let ts {
                    points.append(UsagePoint(date: ts, tokens: last["total_tokens"] as? Int ?? 0, cost: 0))
                }
            default: break
            }
        }
        guard let start, let end, !id.isEmpty else { return nil }
        let title = titles[id] ?? (firstPrompt.isEmpty ? URL(fileURLWithPath: cwd).lastPathComponent : firstPrompt)
        return Session(id: id, tool: "codex", cwd: cwd, title: title, start: start, end: end, model: model, usage: usage,
                       points: points, messages: messages, branch: nil, file: url.path, corrections: corrections, skillUse: [:])
    }

    // MARK: Projects

    /// Groups sessions and dev folders into projects; copies of one project ("EarHop", "EarHop-Windows") merge.
    func buildProjects(_ sessions: [Session]) -> [Project] {
        let fm = FileManager.default
        var byKey: [String: (names: [String: Int], locs: Set<String>, tools: Set<String>, sessions: Int, usage: Usage, last: Date)] = [:]
        func add(root: String, tool: String?, session: Session?) {
            let name = TextRules.projectName(root)
            let key = TextRules.projectKey(name)
            guard !key.isEmpty, !isNoise(root) else { return }
            var e = byKey[key] ?? ([:], [], [], 0, Usage(), .distantPast)
            e.names[name, default: 0] += 1
            e.locs.insert(root)
            if let tool { e.tools.insert(tool) }
            if let session { e.sessions += 1; e.usage = e.usage + session.usage; e.last = max(e.last, session.end) }
            byKey[key] = e
        }
        for s in sessions { add(root: TextRules.projectRoot(s.cwd), tool: s.tool, session: s) }
        // Dev folders: ~/Documents/Development/<Tool folder>/<Project>
        let dev = home.appending(path: "Documents/Development")
        let toolFolders = ["claude code": "claude-code", "codex": "codex", "copilot": "copilot", "gemini": "gemini", "antigravity": "antigravity"]
        for group in (try? fm.contentsOfDirectory(at: dev, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            guard let tool = toolFolders[group.lastPathComponent.lowercased()] else { continue }
            for p in (try? fm.contentsOfDirectory(at: group, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: p.path, isDirectory: &isDir), isDir.boolValue, !p.lastPathComponent.hasPrefix(".") {
                    add(root: p.path, tool: tool, session: nil)
                }
            }
        }
        return byKey.map { key, e in
            let name = e.names.max { ($0.key.contains { $0.isUppercase } ? 1 : 0, $0.value) < ($1.key.contains { $0.isUppercase } ? 1 : 0, $1.value) }?.key ?? key
            let locs = e.locs.sorted()
            return Project(id: key, name: name, locations: locs, tools: e.tools.sorted(), sessions: e.sessions, usage: e.usage,
                           lastActive: e.last == .distantPast ? latestModified(locs) : e.last,
                           existing: locs.filter { fm.fileExists(atPath: $0) }.count)
        }.sorted { $0.lastActive > $1.lastActive }
    }

    private func isNoise(_ root: String) -> Bool {
        root == home.path || root.contains("/.claude/") || root.contains("/.codex/") || root.contains("/Documents/Codex/2") || root.contains("/scratch-workspaces/") || root.contains("/.claude/spares/") || root.hasPrefix("/private/tmp") || root.hasPrefix("/tmp")
    }

    private func latestModified(_ paths: [String]) -> Date {
        paths.compactMap { (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max() ?? .distantPast
    }

    // MARK: Skills

    func scanSkills() -> [Skill] {
        var out: [Skill] = []
        let fm = FileManager.default
        for spec in ToolCatalog.all {
            for dir in spec.skillDirs {
                let root = home.appending(path: dir)
                for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] where !entry.lastPathComponent.hasPrefix(".") {
                    let resolved = entry.resolvingSymlinksInPath()
                    let md = resolved.appending(path: "SKILL.md")
                    guard fm.fileExists(atPath: md.path) else { continue }
                    out.append(skill(md: md, tool: spec.id, source: "user", fallback: entry.lastPathComponent))
                }
            }
        }
        // Claude Code plugin skills: ~/.claude/plugins/cache/<market>/<plugin>/<version>/skills/**/SKILL.md
        let cache = home.appending(path: ".claude/plugins/cache")
        var seen = Set<String>()
        if let e = fm.enumerator(at: cache, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let f as URL in e where f.lastPathComponent == "SKILL.md" {
                let comps = f.path.replacingOccurrences(of: cache.path + "/", with: "").split(separator: "/")
                guard comps.count > 3 else { continue }
                let plugin = String(comps[1])
                let s = skill(md: f, tool: "claude-code", source: plugin, fallback: f.deletingLastPathComponent().lastPathComponent)
                if seen.insert("\(plugin)/\(s.name)").inserted { out.append(s) }
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func skill(md: URL, tool: String, source: String, fallback: String) -> Skill {
        let head = (try? String(contentsOf: md, encoding: .utf8)).map { String($0.prefix(2000)) } ?? ""
        let fm = TextRules.frontMatter(head)
        return Skill(name: fm["name"] ?? fallback, description: fm["description"] ?? "", tool: tool,
                     path: md.deletingLastPathComponent().path, source: source)
    }

    // MARK: Connectors

    func scanConnectors() -> [Connector] {
        var out: [Connector] = []
        for spec in ToolCatalog.all {
            for (rel, format) in spec.mcp {
                let file = path(rel)
                guard let data = FileManager.default.contents(atPath: file) else { continue }
                var servers: [(String, [String: Any])] = []
                switch format {
                case .jsonKey(let key):
                    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    servers = ((obj?[key] as? [String: Any]) ?? [:]).compactMap { k, v in (v as? [String: Any]).map { (k, $0) } }
                case .claudeJSON:
                    let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                    servers = ((obj?["mcpServers"] as? [String: Any]) ?? [:]).compactMap { k, v in (v as? [String: Any]).map { (k, $0) } }
                case .codexTOML:
                    servers = Self.codexServers(String(decoding: data, as: UTF8.self))
                }
                for (name, cfg) in servers {
                    let url = cfg["url"] as? String ?? cfg["serverUrl"] as? String ?? cfg["httpUrl"] as? String
                    var command = cfg["command"] as? String ?? ""
                    if let arr = cfg["command"] as? [String] { command = arr.first ?? "" }
                    let health: Connector.Health = url != nil ? .remote : (resolves(command) ? .ok : .missing)
                    out.append(Connector(name: name, tool: spec.id, transport: url != nil ? "http" : "stdio",
                                         command: url ?? command, health: health, configFile: file))
                }
            }
        }
        return out.sorted { ($0.name, $0.tool) < ($1.name, $1.tool) }
    }

    static func codexServers(_ toml: String) -> [(String, [String: Any])] {
        var out: [(String, [String: Any])] = []
        var current: String?
        var cfg: [String: Any] = [:]
        func flush() { if let c = current { out.append((c, cfg)) }; current = nil; cfg = [:] }
        for raw in toml.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                let name = line.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                if name.hasPrefix("mcp_servers."), !name.dropFirst(12).contains(".") {
                    flush(); current = String(name.dropFirst(12)).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                } else if !name.hasPrefix("mcp_servers.\(current ?? "\u{0}").") { flush() }
                continue
            }
            guard current != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if key == "command" || key == "url" { cfg[key] = value }
        }
        flush()
        return out
    }

    private func resolves(_ command: String) -> Bool {
        guard !command.isEmpty else { return false }
        let expanded = command.hasPrefix("~") ? home.path + command.dropFirst() : command
        if expanded.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: expanded) }
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", path(".local/bin"), path(".bun/bin"), path(".cargo/bin")]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return dirs.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(expanded)") }
    }

    // MARK: Memory notes

    func scanNotes() -> [MemoryNote] {
        let root = home.appending(path: "basic-memory")
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [MemoryNote] = []
        for case let f as URL in e where f.pathExtension == "md" {
            let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            let title = TextRules.frontMatter(text)["title"] ?? f.deletingPathExtension().lastPathComponent
            let folder = f.deletingLastPathComponent().path.replacingOccurrences(of: root.path, with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let mod = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            out.append(MemoryNote(title: title, folder: folder.isEmpty ? "/" : folder, path: f.path, modified: mod,
                                  words: text.split { $0.isWhitespace }.count))
        }
        return out.sorted { $0.modified > $1.modified }
    }

    // MARK: Clutter

    func scanClutter(sessions: [Session], projects: [Project]) -> [ClutterItem] {
        let fm = FileManager.default
        var out: [ClutterItem] = []
        func add(_ url: URL, _ reason: String) {
            guard fm.fileExists(atPath: url.path) else { return }
            let mod = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            out.append(ClutterItem(path: url.path, reason: reason, bytes: Self.size(of: url), modified: mod))
        }
        let weekAgo = Date.now.addingTimeInterval(-7 * 86_400)
        for dir in (try? fm.contentsOfDirectory(at: home.appending(path: ".claude/spares"), includingPropertiesForKeys: nil)) ?? [] {
            add(dir, "Spare Claude workspace")
        }
        let scratch = home.appending(path: "Library/Application Support/Claude/scratch-workspaces")
        if let e = fm.enumerator(at: scratch, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) {
            for case let f as URL in e where f.lastPathComponent.hasPrefix("scratch-") {
                e.skipDescendants()
                if let m = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date, m < weekAgo { add(f, "Old scratch workspace (7+ days)") }
            }
        }
        // Session logs whose project folder no longer exists.
        var logDirs: [String: String] = [:]
        for s in sessions where s.tool == "claude-code" { logDirs[URL(fileURLWithPath: s.file).deletingLastPathComponent().path] = s.cwd }
        for (dir, cwd) in logDirs where !fm.fileExists(atPath: cwd) && !cwd.contains("/scratch-workspaces/") && !cwd.contains("/.claude/spares/") {
            add(URL(fileURLWithPath: dir), "Logs for a folder that no longer exists")
        }
        // Zip copies of a project that also exists unzipped, and stale worktrees.
        let keys = Set(projects.filter { $0.existing > 0 }.map(\.id))
        for root in ["Documents/Development", "Desktop", "Downloads"] {
            guard let e = fm.enumerator(at: home.appending(path: root), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let f as URL in e {
                if e.level > 3 { e.skipDescendants(); continue }
                if ["node_modules", "build", ".build", "DerivedData"].contains(f.lastPathComponent) { e.skipDescendants(); continue }
                if f.pathExtension == "zip", keys.contains(TextRules.projectKey(f.deletingPathExtension().lastPathComponent)) {
                    add(f, "Zip copy of a project you still have")
                }
            }
        }
        for p in projects {
            for loc in p.locations {
                let wt = URL(fileURLWithPath: loc).appending(path: ".claude/worktrees")
                for w in (try? fm.contentsOfDirectory(at: wt, includingPropertiesForKeys: nil)) ?? [] {
                    if let m = (try? fm.attributesOfItem(atPath: w.path))?[.modificationDate] as? Date, m < Date.now.addingTimeInterval(-14 * 86_400) {
                        add(w, "Worktree untouched for 14+ days")
                    }
                }
            }
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    static func size(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isRegularFileKey]) else {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Design assets

    static let assetKinds: [String: String] = [
        "fig": "Design", "sketch": "Design", "psd": "Design", "ai": "Design", "indd": "Design", "idml": "Design", "svg": "Design",
        "png": "Image", "jpg": "Image", "jpeg": "Image", "webp": "Image", "heic": "Image", "gif": "Image",
        "mp4": "Video", "mov": "Video", "pdf": "PDF", "key": "Deck", "pptx": "Deck",
        "md": "Doc", "html": "Doc", "docx": "Doc", "pages": "Doc", "xlsx": "Sheet", "csv": "Sheet",
        "sh": "Script", "py": "Script", "command": "Script", "zip": "Archive", "apk": "Build", "dmg": "Build",
    ]

    func scanAssets() -> [DesignAsset] {
        let fm = FileManager.default
        let since = Date.now.addingTimeInterval(-45 * 86_400)
        var out: [DesignAsset] = []
        for root in ["Desktop", "Downloads", "Documents", "Claude"] {
            guard let e = fm.enumerator(at: home.appending(path: root), includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let f as URL in e {
                if e.level > 4 || ["node_modules", "build", ".build", "DerivedData", "Library", "mac-optimize-backup", "Sources", "src", "Tests",
                                   "vendor", "dist", "Pods", "tools", "scripts", "docs", "lib"].contains(f.lastPathComponent) {
                    e.skipDescendants(); continue
                }
                guard let kind = Self.assetKinds[f.pathExtension.lowercased()],
                      let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                      let mod = v.contentModificationDate, mod > since, (v.fileSize ?? 0) > 2_000 else { continue }
                out.append(DesignAsset(path: f.path, name: f.lastPathComponent, kind: kind, modified: mod, bytes: Int64(v.fileSize ?? 0)))
            }
        }
        return Array(out.sorted { $0.modified > $1.modified }.prefix(120))
    }

    // MARK: Ollama

    func ollamaStatus() async -> ([String], Bool) {
        var models: [String] = []
        let manifests = home.appending(path: ".ollama/models/manifests")
        if let e = FileManager.default.enumerator(at: manifests, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let f as URL in e.allObjects where (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                models.append("\(f.deletingLastPathComponent().lastPathComponent):\(f.lastPathComponent)")
            }
        }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        req.timeoutInterval = 1
        let running = ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
        return (models.sorted(), running)
    }

    // MARK: Tools

    func buildTools(sessions: [Session], skills: [Skill], connectors: [Connector]) -> [AITool] {
        let fm = FileManager.default
        return ToolCatalog.all.compactMap { spec in
            let app = spec.apps.first { fm.fileExists(atPath: $0) }
            let config = spec.configDir.map(path)
            let hasConfig = config.map { fm.fileExists(atPath: $0) } ?? false
            guard app != nil || hasConfig else { return nil }
            let mine = sessions.filter { $0.tool == spec.id }
            var t = AITool(id: spec.id, name: spec.name, kind: spec.kind, appPath: app, configDir: hasConfig ? config : nil,
                           installed: true, symbol: spec.symbol, hue: spec.hue)
            t.skillCount = skills.filter { $0.tool == spec.id }.count
            t.connectorCount = connectors.filter { $0.tool == spec.id }.count
            t.sessionCount = mine.count
            t.lastUsed = mine.map(\.end).max() ?? config.flatMap { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }
            t.tokens = mine.reduce(0) { $0 + $1.usage.total }
            t.costUSD = mine.reduce(0) { $0 + $1.usage.cost }
            return t
        }
    }
}
