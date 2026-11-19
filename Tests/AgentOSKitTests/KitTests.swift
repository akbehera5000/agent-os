import Foundation
import Testing
import simd
@testable import AgentOSKit

@Test func correctionsAreDetected() {
    #expect(TextRules.isCorrection("no, I said use SwiftUI not Electron"))
    #expect(TextRules.isCorrection("Don't add a summary at the end of every reply"))
    #expect(!TextRules.isCorrection("build me a mac app please"))
    #expect(!TextRules.isCorrection("<command-name>/clear</command-name>"))
}

@Test func projectCopiesMerge() {
    #expect(TextRules.projectKey("EarHop-Windows") == TextRules.projectKey("earhop"))
    #expect(TextRules.projectKey("Haptic Bridge") == TextRules.projectKey("HapticBridge"))
    #expect(TextRules.projectRoot("/a/EarHop/.claude/worktrees/x-1") == "/a/EarHop")
}

@Test func pricingMatchesPublishedRates() {
    // 1M output tokens on Opus 5.5 = $20; 1M 1h cache writes on Sonnet 5.5 = 2 x $2.
    #expect(Pricing.cost(model: "claude-opus-5-5", input: 0, output: 1_000_000, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0) == 20)
    #expect(Pricing.cost(model: "claude-sonnet-5-5", input: 0, output: 0, cacheWrite5m: 0, cacheWrite1h: 1_000_000, cacheRead: 0) == 4)
    #expect(Pricing.shortName("claude-opus-5-5") == "Opus 5.5")
}

@Test func rulesAppendUnderSection() {
    let doc = "# Me\n\n## Rules from corrections\n\n- old rule\n\n## Preferences\n\n- x\n"
    let out = TextRules.appendingRule("new rule", to: doc, date: Date(timeIntervalSince1970: 0))
    let lines = out.components(separatedBy: "\n")
    let i = lines.firstIndex { $0.hasPrefix("- new rule") }!
    #expect(lines[i - 1] == "- old rule")
    #expect(out.contains("(added 1970-01-01)"))
    #expect(TextRules.appendingRule("r", to: "", date: .now).hasPrefix("## Rules from corrections"))
}

@Test func codexTomlServers() {
    let toml = "[mcp_servers.rea]\ncommand = \"rea\"\n[mcp_servers.rea.env]\nX = \"1\"\n[mcp_servers.web]\nurl = \"https://x\"\n[other]\n"
    let s = Scanner.codexServers(toml)
    #expect(s.map(\.0) == ["rea", "web"])
    #expect(s[0].1["command"] as? String == "rea")
}

@Test func claudeSessionParsesAndDedupes() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "aos-test-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let usage = #"{"input_tokens":10,"output_tokens":1000000,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}"#
    let lines = [
        #"{"type":"user","cwd":"/tmp/Proj","timestamp":"2026-11-19T10:00:00.000Z","message":{"role":"user","content":"no, I said keep it short"}}"#,
        #"{"type":"assistant","cwd":"/tmp/Proj","timestamp":"2026-11-19T10:00:05.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":\#(usage)}}"#,
        #"{"type":"assistant","cwd":"/tmp/Proj","timestamp":"2026-11-19T10:00:06.000Z","message":{"id":"m1","model":"claude-opus-5-5","usage":\#(usage)}}"#,
    ]
    let f = dir.appending(path: "s1.jsonl")
    try lines.joined(separator: "\n").write(to: f, atomically: true, encoding: .utf8)
    let s = try #require(Scanner.parseClaude(f))
    #expect(s.usage.output == 1_000_000)          // duplicate line counted once
    #expect(abs(s.usage.cost - 20.00004) < 0.0001)
    #expect(s.corrections.count == 1)
    #expect(s.cwd == "/tmp/Proj")
}

@Test func routineNextRunHonorsWeekdays() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    // Thursday 19 Nov 2026, 23:00 IST
    let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 23))!
    let daily = Routine(name: "d", kind: .briefing, hour: 9)
    #expect(cal.component(.day, from: daily.nextRun(after: now, calendar: cal)) == 20)
    let sunday = Routine(name: "s", kind: .costDigest, hour: 10, weekdays: [1])
    let next = sunday.nextRun(after: now, calendar: cal)
    #expect(cal.component(.weekday, from: next) == 1 && cal.component(.day, from: next) == 22)
}

@Test func rupeesUseIndianGrouping() {
    Format.inrPerUSD = 88
    #expect(Format.inr(123456) == "₹1,23,456")
    #expect(Format.money(1) == "₹88.00")
}

@Test func brainGraphLinksSkillsToTools() {
    var s = Snapshot()
    s.tools = [AITool(id: "claude-code", name: "Claude Code", kind: "CLI", installed: true, symbol: "x", hue: 0)]
    s.skills = [Skill(name: "demo", description: "", tool: "claude-code", path: "/tmp/demo", source: "user")]
    let g = Brain.build(s)
    #expect(g.nodes.count == 3)
    let skill = g.nodes.firstIndex { $0.kind == .skill }!
    #expect(g.nodes[g.nodes[skill].parent!].kind == .tool)
    let (xy, _) = Brain.project(.zero, yaw: 1, pitch: 0.3, zoom: 1, aspect: 1)
    #expect(xy == .zero)
}

@Test func orbitsMatchLayoutAtTimeZeroAndMove() {
    var s = Snapshot()
    s.tools = [AITool(id: "claude-code", name: "Claude Code", kind: "CLI", installed: true, symbol: "x", hue: 0)]
    s.skills = [Skill(name: "demo", description: "", tool: "claude-code", path: "/tmp/demo", source: "user")]
    let g = Brain.build(s)
    for i in g.nodes.indices { #expect(simd_distance(g.position(i, at: 0), g.nodes[i].pos) < 1e-4) }
    let moon = g.nodes.firstIndex { $0.kind == .skill }!
    #expect(simd_distance(g.position(moon, at: 30), g.nodes[moon].pos) > 0.01)
    // A moon stays the same distance from its planet while it orbits.
    let planet = g.nodes[moon].parent!
    let r0 = simd_distance(g.position(moon, at: 0), g.position(planet, at: 0))
    let r1 = simd_distance(g.position(moon, at: 47), g.position(planet, at: 47))
    #expect(abs(r0 - r1) < 1e-4)
}

@Test func everyStyleLaysOutEveryNode() {
    var s = Snapshot()
    s.tools = [AITool(id: "claude-code", name: "Claude Code", kind: "CLI", installed: true, symbol: "x", hue: 0)]
    s.skills = (0..<20).map { Skill(name: "s\($0)", description: "", tool: "claude-code", path: "/tmp/s\($0)", source: "user") }
    for style in BrainStyle.allCases {
        let g = Brain.build(s, style: style)
        #expect(g.nodes.count == 22)
        for i in g.nodes.indices { #expect(simd_distance(g.position(i, at: 0), g.nodes[i].pos) < 1e-4, "\(style)") }
        #expect(g.nodes.allSatisfy { $0.pos.x.isFinite && $0.pos.y.isFinite && $0.pos.z.isFinite })
    }
}
