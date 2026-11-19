import Foundation

/// A fictional developer's AI setup, for public screenshots and trying the app without real data.
/// Turn it on with `APP_DEMO=1`. Nothing here comes from this Mac.
public enum Demo {
    public static var enabled: Bool { ProcessInfo.processInfo.environment["APP_DEMO"] == "1" }
    public static let userName = "Alex"

    public static func snapshot(now: Date = .now) -> Snapshot {
        var rng = SplitMix64(seed: 42)
        let home = "/Users/alex"
        let toolIDs = ["claude-code", "claude-desktop", "codex", "chatgpt", "gemini", "antigravity", "copilot", "opencode", "qwen", "shared"]
        let projectNames = ["Nebula Notes", "Orbit CRM", "PixelForge", "Atlas API", "Lumen Docs", "Vega Mobile", "Quasar Analytics", "Echo Voice", "Helix Infra", "Aurora Site"]
        let titles = ["Add offline sync to the notes editor", "Refactor auth middleware", "Design the onboarding flow", "Fix flaky checkout test",
                      "Write release notes for v2.4", "Migrate charts to Swift Charts", "Speed up cold start", "Add dark mode tokens",
                      "Build the pricing page", "Profile memory leak in the importer", "Draft the investor update", "Set up CI caching",
                      "Wire Stripe webhooks", "Generate API docs", "Clean up feature flags", "Prototype voice commands"]
        let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"]

        var sessions: [Session] = []
        for i in 0..<64 {
            let tool = i % 5 == 0 ? "codex" : "claude-code"
            let project = projectNames[Int(rng.float() * Float(projectNames.count)) % projectNames.count]
            let ago = Double(pow(rng.float(), 1.6)) * 29 * 86_400 + Double(rng.float()) * 3600
            let end = now.addingTimeInterval(-ago)
            let start = end.addingTimeInterval(-Double(600 + rng.float() * 7200))
            let model = models[Int(rng.float() * Float(models.count)) % models.count]
            var usage = Usage()
            usage.input = Int(5_000 + rng.float() * 40_000)
            usage.output = Int(20_000 + rng.float() * 180_000)
            usage.cacheRead = Int(400_000 + rng.float() * 9_000_000)
            usage.cacheWrite = Int(50_000 + rng.float() * 600_000)
            usage.cost = tool == "codex" ? 0 : Pricing.cost(model: model, input: usage.input, output: usage.output, cacheWrite5m: 0,
                                                             cacheWrite1h: usage.cacheWrite, cacheRead: usage.cacheRead)
            let steps = 6
            let points = (0..<steps).map { k in
                UsagePoint(date: start.addingTimeInterval(Double(k) / Double(steps) * end.timeIntervalSince(start)),
                           tokens: usage.total / steps, cost: usage.cost / Double(steps))
            }
            var skillUse: [String: Usage] = [:]
            if rng.float() > 0.55 {
                let skill = ["code-review", "release-notes", "ui-polish", "test-writer", "api-docs"][Int(rng.float() * 5) % 5]
                var u = Usage()
                u.runs = 1; u.output = usage.output / 3; u.cacheRead = usage.cacheRead / 3; u.cost = usage.cost / 3
                skillUse[skill] = u
            }
            sessions.append(Session(id: "demo-\(i)", tool: tool, cwd: "\(home)/Developer/\(project)", title: titles[i % titles.count],
                                    start: start, end: end, model: tool == "codex" ? "gpt-6" : model, usage: usage, points: points,
                                    messages: Int(3 + rng.float() * 40), branch: ["main", "feature/sync", "fix/checkout", "design/onboarding"][i % 4],
                                    file: "\(home)/.claude/projects/demo/demo-\(i).jsonl", corrections: [], skillUse: skillUse))
        }
        sessions.sort { $0.end > $1.end }

        let projects: [Project] = projectNames.map { name in
            let mine = sessions.filter { $0.cwd.hasSuffix("/" + name) }
            return Project(id: TextRules.projectKey(name), name: name, locations: ["\(home)/Developer/\(name)"],
                           tools: Array(Set(mine.map(\.tool))).sorted(), sessions: mine.count, usage: mine.reduce(Usage()) { $0 + $1.usage },
                           lastActive: mine.map(\.end).max() ?? now.addingTimeInterval(-20 * 86_400), existing: 1)
        }.sorted { $0.lastActive > $1.lastActive }

        let skillNames = ["code-review", "release-notes", "ui-polish", "test-writer", "api-docs", "refactor-guide", "commit-message", "security-scan",
                          "perf-profiler", "design-tokens", "sql-helper", "changelog", "onboarding-writer", "a11y-check", "i18n-sync", "deploy-check",
                          "bug-triage", "spec-writer", "data-viz", "prompt-tuner", "seo-audit", "copy-editor", "pitch-deck", "meeting-notes"]
        var skills: [Skill] = []
        for (t, tool) in ["claude-code", "codex", "opencode", "qwen", "shared"].enumerated() {
            for (k, s) in skillNames.enumerated() where (k + t) % (t == 0 ? 1 : 2) == 0 {
                skills.append(Skill(name: s, description: "Demo skill: \(s.replacingOccurrences(of: "-", with: " "))", tool: tool,
                                    path: "\(home)/.\(tool)/skills/\(s)", source: "user"))
            }
        }
        for k in 0..<160 {
            skills.append(Skill(name: "\(skillNames[k % skillNames.count])-\(k / skillNames.count + 2)", description: "Plugin skill", tool: "claude-code",
                                path: "\(home)/.claude/plugins/demo/skill-\(k)", source: ["toolkit", "design-pack", "devops-pack"][k % 3]))
        }

        let tools: [AITool] = toolIDs.compactMap { id in
            guard let spec = ToolCatalog.spec(id) else { return nil }
            let mine = sessions.filter { $0.tool == id }
            var t = AITool(id: id, name: spec.name, kind: spec.kind, appPath: nil, configDir: "\(home)/\(spec.configDir ?? "")", installed: true,
                           symbol: spec.symbol, hue: spec.hue)
            t.sessionCount = mine.count
            t.skillCount = skills.filter { $0.tool == id }.count
            t.connectorCount = id == "claude-code" ? 4 : 2
            t.lastUsed = mine.map(\.end).max() ?? now.addingTimeInterval(-Double(5 + id.count) * 86_400)
            t.tokens = mine.reduce(0) { $0 + $1.usage.total }
            t.costUSD = mine.reduce(0) { $0 + $1.usage.cost }
            return t
        }

        let connectorRows: [(String, String, Connector.Health)] = [("github", "claude-code", .ok), ("filesystem", "claude-code", .ok), ("figma", "claude-code", .remote),
                                                                     ("postgres", "claude-code", .ok), ("github", "codex", .ok), ("browser", "codex", .missing),
                                                                     ("filesystem", "gemini", .ok), ("memory", "opencode", .ok)]
        let connectors = connectorRows.map {
            Connector(name: $0.0, tool: $0.1, transport: $0.2 == .remote ? "http" : "stdio",
                      command: $0.2 == .remote ? "https://mcp.example.com" : "npx \($0.0)-mcp", health: $0.2, configFile: "\(home)/.claude.json")
        }
        let corrections = ["no, keep the existing API shape and add a new endpoint instead",
                           "don't add comments that restate the code",
                           "I said use Swift Charts, not a custom drawing",
                           "stop creating new files for small helpers"].enumerated().map {
            Correction(id: "demo-c\($0.offset)", text: $0.element, project: projectNames[$0.offset],
                       date: now.addingTimeInterval(-Double($0.offset + 1) * 40_000), sessionID: "demo-\($0.offset)")
        }
        let noteTitles = ["Orbit CRM — auth decisions", "Nebula Notes — sync design", "Release checklist", "Design system rules", "Weekly cost digest"]
        let notes = noteTitles.enumerated().map {
            MemoryNote(title: $0.element, folder: ["sessions", "sessions", "process", "design", "digests"][$0.offset],
                       path: "\(home)/basic-memory/demo-\($0.offset).md", modified: now.addingTimeInterval(-Double($0.offset) * 50_000), words: 180 + $0.offset * 40)
        }
        let docTitles = ["~/.claude/CLAUDE.md", "~/.codex/AGENTS.md", "~/.gemini/GEMINI.md", "Orbit CRM/CLAUDE.md", "Nebula Notes/AGENTS.md"]
        let docs = docTitles.enumerated().map {
            Doc(path: "\(home)/demo-doc-\($0.offset).md", title: $0.element, kind: $0.offset < 3 ? "Rules" : "Project rules",
                tool: ["claude-code", "codex", "gemini", "claude-code", "codex"][$0.offset], bytes: 2_000 + $0.offset * 900,
                modified: now.addingTimeInterval(-Double($0.offset) * 30_000))
        }
        let kinds = ["Deck", "PDF", "Doc", "Script", "Image", "Video", "Design", "Sheet"]
        let exts = ["key", "pdf", "md", "sh", "png", "mov", "fig", "csv"]
        let assets: [DesignAsset] = (0..<30).map { k in
            let project = projectNames[k % projectNames.count]
            let slug = project.lowercased().replacingOccurrences(of: " ", with: "-")
            return DesignAsset(path: "\(home)/Developer/\(project)/asset-\(k).\(exts[k % 8])", name: "\(slug)-\(kinds[k % 8].lowercased())-\(k).\(exts[k % 8])",
                               kind: kinds[k % 8], modified: now.addingTimeInterval(-Double(k) * 20_000), bytes: Int64(80_000 + k * 120_000))
        }
        let clutter = [
            ClutterItem(path: "\(home)/.claude/spares/spare-a1", reason: "Spare Claude workspace", bytes: 180_000_000, modified: now.addingTimeInterval(-9 * 86_400)),
            ClutterItem(path: "\(home)/Developer/Orbit CRM.zip", reason: "Zip copy of a project you still have", bytes: 420_000_000, modified: now.addingTimeInterval(-20 * 86_400)),
            ClutterItem(path: "\(home)/Developer/PixelForge/.claude/worktrees/old-ui", reason: "Worktree untouched for 14+ days", bytes: 96_000_000, modified: now.addingTimeInterval(-30 * 86_400)),
        ]

        var s = Snapshot(scannedAt: now, tools: tools, sessions: sessions, projects: projects, skills: skills, connectors: connectors,
                         corrections: corrections, notes: notes, clutter: clutter, assets: assets, localModels: [], ollamaRunning: false)
        s.docs = docs
        return s
    }

    public static func activity(now: Date = .now) -> [Activity] {
        let rows: [(String, String, String)] = [
            ("ASK", "Make the sync conflict banner dismissible", "Nebula Notes"), ("READ", "SyncEngine.swift", "Nebula Notes"),
            ("EDIT", "ConflictBanner.swift", "Nebula Notes"), ("BASH", "swift test --filter Sync", "Nebula Notes"),
            ("SKILL", "code-review", "Nebula Notes"), ("GREP", "TODO(sync)", "Orbit CRM"), ("EDIT", "AuthMiddleware.ts", "Orbit CRM"),
            ("BASH", "npm run lint", "Orbit CRM"), ("ASK", "Write release notes for 2.4", "Lumen Docs"), ("WRITE", "CHANGELOG.md", "Lumen Docs"),
        ]
        return rows.enumerated().map {
            Activity(id: "demo-a\($0.offset)", date: now.addingTimeInterval(-Double($0.offset) * 95), verb: $0.element.0, target: $0.element.1, project: $0.element.2)
        }
    }
}
