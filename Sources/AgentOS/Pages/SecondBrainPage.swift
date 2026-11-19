import AgentOSKit
import SwiftUI

/// Second Brain: workspace topology and cost telemetry in five views.
struct SecondBrainPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("brain.tab") private var tab = "orb"
    @State private var query = ""

    var body: some View {
        VStack(spacing: Space.lg) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("SECOND BRAIN").font(.system(size: 15, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(HUD.text)
                    Text("Workspace topology & cost telemetry").font(HUD.mono(10.5)).foregroundStyle(HUD.text3)
                }
                Spacer()
                PillTabs(items: [("orb", "3D Orb"), ("chrono", "Chronosphere"), ("rings", "2D Rings"), ("skills", "Skills"), ("routines", "Routines")],
                         selection: $tab)
                Spacer()
                SearchField(text: $query, prompt: "Search the brain…").frame(width: 240)
            }
            Group {
                switch tab {
                case "chrono": ChronosphereView()
                case "rings": RingsView()
                case "skills": SkillTelemetryView()
                case "routines": RoutinesView()
                default: OrbTab(query: query)
                }
            }
            .id(tab)
            .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
        .padding(Space.xl)
    }
}

// MARK: - 3D orb

private struct OrbTab: View {
    @Environment(AppModel.self) private var model
    let query: String
    @State private var kindFilter: BrainNode.Kind?
    @State private var control = BrainControl()

    var body: some View {
        let g = model.graph
        let matches = highlight(g)
        ZStack(alignment: .topLeading) {
            BrainView(graph: g, selected: model.selectedNode, highlight: matches,
                      energy: model.jarvis.busy || model.jarvis.listening ? 1 : 0, control: control, style: model.brainStyle) { model.select(node: $0) }
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    VStack(alignment: .trailing, spacing: Space.sm) {
                        StylePicker()
                        CameraControls(control: control, hasSelection: model.selectedNode != nil)
                    }
                        .padding(.trailing, Space.lg).padding(.bottom, 70)
                }
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("DRAG TO ORBIT · SCROLL OR PINCH TO ZOOM · CLICK TO INSPECT · DOUBLE-CLICK TO FLY TO A PLANET").font(HUD.label(10)).tracking(1.2).foregroundStyle(HUD.text)
                    .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                    .background(RoundedRectangle(cornerRadius: 8).fill(HUD.bg.opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.line))
                HStack(spacing: Space.xs) {
                    ForEach(BrainNode.Kind.allCases.filter { $0 != .core }, id: \.self) { k in
                        let c = Color(nsColor: BrainRenderer.nsColor(k))
                        Button { withAnimation(HUD.quick) { kindFilter = kindFilter == k ? nil : k } } label: {
                            Text("\(k.rawValue.uppercased())S (\(g.count(k)))").font(HUD.label(9.5)).foregroundStyle(c)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(RoundedRectangle(cornerRadius: 6).fill(c.opacity(kindFilter == k ? 0.28 : 0.1)))
                                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(c.opacity(kindFilter == k ? 0.9 : 0.35)))
                        }
                        .buttonStyle(.plain)
                        .help("Highlight only \(k.rawValue)s")
                    }
                }
            }
            .padding(Space.lg)
            VStack {
                Spacer()
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        ForEach(model.snapshot.docs.prefix(14)) { d in
                            Button { model.inspect(path: d.path, title: d.title, kind: .doc, detail: d.kind) } label: {
                                HStack(spacing: 6) {
                                    Circle().fill(HUD.memory).frame(width: 6, height: 6)
                                    Text(d.title).font(HUD.mono(10.5)).foregroundStyle(HUD.text)
                                }
                                .padding(.horizontal, Space.md).padding(.vertical, 7)
                                .background(RoundedRectangle(cornerRadius: 8).fill(HUD.panel.opacity(0.9)))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.line))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(Space.lg)
                }
                .scrollIndicators(.never)
            }
        }
        .background(RoundedRectangle(cornerRadius: HUD.radius).fill(HUD.bgRaised.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: HUD.radius).strokeBorder(HUD.line))
        .overlay(HUDCorners(color: HUD.skills).padding(4).allowsHitTesting(false))
        .clipShape(RoundedRectangle(cornerRadius: HUD.radius))
    }

    private func highlight(_ g: BrainGraph) -> Set<Int>? {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty || kindFilter != nil else { return nil }
        return Set(g.nodes.indices.filter { i in
            let n = g.nodes[i]
            return (kindFilter == nil || n.kind == kindFilter) && (q.isEmpty || n.label.lowercased().contains(q) || n.detail.lowercased().contains(q))
        })
    }
}

// MARK: - Chronosphere: every session of the last 30 days on a radial clock

private struct ChronosphereView: View {
    @Environment(AppModel.self) private var model
    @State private var hover: Session?
    private let days = 30

    var body: some View {
        let now = model.now
        let start = Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: now))!
        let sessions = model.snapshot.sessions.filter { $0.end >= start }
        let maxCost = max(0.01, sessions.map(\.usage.cost).max() ?? 0)
        GeometryReader { g in
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let r0 = min(g.size.width, g.size.height) * 0.17
            let r1 = min(g.size.width, g.size.height) * 0.4
            let angle: (Date) -> Double = { d in d.timeIntervalSince(start) / (Double(days) * 86_400) * 2 * .pi - .pi / 2 }
            let spike: (Session) -> (CGPoint, CGPoint) = { s in
                let a = angle(s.end)
                let mag = s.usage.cost > 0 ? log10(1 + s.usage.cost) / log10(1 + maxCost) : log10(Double(max(10, s.usage.total))) / 9
                let len = (r1 - r0) * CGFloat(0.12 + 0.88 * mag)
                return (CGPoint(x: c.x + cos(a) * r0, y: c.y + sin(a) * r0), CGPoint(x: c.x + cos(a) * (r0 + len), y: c.y + sin(a) * (r0 + len)))
            }
            ZStack {
                Canvas { ctx, _ in
                    for k in 1...4 {
                        let r = r0 + (r1 - r0) * CGFloat(k) / 4
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(HUD.line), style: StrokeStyle(lineWidth: 0.6, dash: [2, 4]))
                    }
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r0, y: c.y - r0, width: r0 * 2, height: r0 * 2)), with: .color(HUD.lineHi), lineWidth: 1)
                    for d in 0..<days {
                        let day = Calendar.current.date(byAdding: .day, value: d, to: start)!
                        let a = angle(day)
                        let isToday = Calendar.current.isDateInToday(day)
                        let len: CGFloat = d % 5 == 0 ? 18 : 11
                        var tick = Path()
                        tick.move(to: CGPoint(x: c.x + cos(a) * (r1 + 6), y: c.y + sin(a) * (r1 + 6)))
                        tick.addLine(to: CGPoint(x: c.x + cos(a) * (r1 + len), y: c.y + sin(a) * (r1 + len)))
                        ctx.stroke(tick, with: .color(isToday ? HUD.skills : HUD.text3), lineWidth: isToday ? 2 : 1)
                        if d % 5 == 0 || isToday {
                            let lp = CGPoint(x: c.x + cos(a) * (r1 + 36), y: c.y + sin(a) * (r1 + 36))
                            ctx.draw(Text(isToday ? "TODAY" : day.formatted(.dateTime.day().month(.abbreviated)).uppercased())
                                .font(HUD.label(9)).foregroundStyle(isToday ? HUD.skills : HUD.text2), at: lp)
                        }
                    }
                    for s in sessions {
                        let (a, b) = spike(s)
                        let col = HUD.hue(ToolCatalog.spec(s.tool)?.hue ?? 0.1)
                        var p = Path(); p.move(to: a); p.addLine(to: b)
                        let hot = hover?.id == s.id
                        ctx.stroke(p, with: .linearGradient(Gradient(colors: [col.opacity(0.15), col]), startPoint: a, endPoint: b), lineWidth: hot ? 3 : 1.6)
                        let r: CGFloat = hot ? 5 : 3
                        ctx.fill(Path(ellipseIn: CGRect(x: b.x - r, y: b.y - r, width: r * 2, height: r * 2)), with: .color(col))
                    }
                }
                VStack(spacing: 4) {
                    Text("30 DAYS").font(HUD.label(10)).tracking(2).foregroundStyle(HUD.text3)
                    Text(Format.money(sessions.reduce(0) { $0 + $1.usage.cost })).font(HUD.display(30)).foregroundStyle(HUD.routines)
                    Text("\(sessions.count) sessions").font(HUD.mono(10.5)).foregroundStyle(HUD.text2)
                }
                .position(c)
                if let h = hover {
                    let tip = spike(h).1
                    VStack(alignment: .leading, spacing: 3) {
                        Text(h.title).font(HUD.mono(11, .semibold)).foregroundStyle(HUD.text).lineLimit(1)
                        Text("\(TextRules.projectName(h.cwd)) · \(ToolCatalog.name(h.tool)) · \(h.end.formatted(date: .abbreviated, time: .shortened))")
                            .font(HUD.mono(9.5)).foregroundStyle(HUD.text2)
                        Text("\(h.usage.cost > 0 ? Format.money(h.usage.cost) : "plan") · \(Format.tokens(h.usage.total)) tokens · click to inspect")
                            .font(HUD.mono(9.5)).foregroundStyle(HUD.routines)
                    }
                    .padding(Space.md).frame(width: 300, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(HUD.bg.opacity(0.95)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(HUD.routines.opacity(0.6)))
                    .position(x: min(g.size.width - 160, max(160, tip.x)), y: max(50, tip.y - 50))
                    .allowsHitTesting(false)
                }
                Text("HOVER A SPIKE · CLICK TO INSPECT · LENGTH = SPEND").font(HUD.label(10)).tracking(1.2).foregroundStyle(HUD.text)
                    .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                    .background(RoundedRectangle(cornerRadius: 8).fill(HUD.bg.opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.line))
                    .position(x: 210, y: 30)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                guard case .active(let p) = phase else { hover = nil; return }
                let near = sessions.map { ($0, hypot(spike($0).1.x - p.x, spike($0).1.y - p.y)) }.min { $0.1 < $1.1 }
                hover = near.flatMap { $0.1 < 22 ? $0.0 : nil }
            }
            .onTapGesture { if let h = hover { model.inspect(path: h.file, title: h.title, kind: .session) } }
        }
        .background(RoundedRectangle(cornerRadius: HUD.radius).fill(HUD.bgRaised.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: HUD.radius).strokeBorder(HUD.line))
        .overlay(HUDCorners(color: HUD.routines).padding(4).allowsHitTesting(false))
    }
}

// MARK: - 2D rings: your rules file at the center, departments around it

private struct RingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("brain.tab") private var tab = "rings"
    @State private var hover: String?

    struct Spot: Identifiable { let id: String; let label: String; let path: String?; let dept: Int }

    var body: some View {
        let s = model.snapshot
        let depts: [(String, Color)] = [("SKILLS", HUD.skills), ("MEMORY", HUD.memory), ("ROUTINES", HUD.routines), ("APPS", HUD.apps)]
        let used = Set(s.sessions.flatMap { $0.skillUse.keys })
        let skillPool = s.skills.filter { used.contains($0.name) || used.contains("\($0.source):\($0.name)") } + s.skills.filter { $0.source == "user" && $0.tool == "claude-code" }
        let skillSpots = skillPool.prefix(5).map { Spot(id: "s-\($0.id)", label: "\($0.name)/SKILL.md", path: $0.path + "/SKILL.md", dept: 0) }
        let memSpots = Array(s.docs.prefix(3).map { Spot(id: "d-\($0.path)", label: $0.title, path: $0.path, dept: 1) }
                             + s.notes.prefix(2).map { Spot(id: "n-\($0.path)", label: $0.title, path: $0.path, dept: 1) })
        let routineSpots = model.routines.prefix(5).map { Spot(id: "r-\($0.id)", label: $0.name, path: nil, dept: 2) }
        let appSpots = s.tools.prefix(5).map { t in Spot(id: "a-\(t.id)", label: t.name, path: ToolCatalog.spec(t.id)?.mcp.first.map { NSHomeDirectory() + "/" + $0.path }, dept: 3) }
        let groups: [[Spot]] = [Array(skillSpots), memSpots, Array(routineSpots), Array(appSpots)]
        let center = NSHomeDirectory() + "/.claude/CLAUDE.md"

        GeometryReader { g in
            let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
            let R = min(g.size.width, g.size.height) * 0.4
            let arcR = R * 0.62
            let positions: [(Spot, CGPoint)] = groups.enumerated().flatMap { d, spots in
                spots.enumerated().map { i, spot in
                    let deg = Double(d) * 90 - 135 - 40 + (Double(i) + 0.5) / Double(max(1, spots.count)) * 80
                    let a = deg * .pi / 180
                    return (spot, CGPoint(x: c.x + cos(a) * R, y: c.y + sin(a) * R))
                }
            }
            ZStack {
                Canvas { ctx, _ in
                    for k in [0.3, 0.62, 1.0] {
                        let r = R * k
                        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(HUD.line), lineWidth: 0.7)
                    }
                    for (d, dept) in depts.enumerated() {
                        var arc = Path()
                        arc.addArc(center: c, radius: arcR, startAngle: .degrees(Double(d) * 90 - 135 - 38), endAngle: .degrees(Double(d) * 90 - 135 + 38), clockwise: false)
                        ctx.stroke(arc, with: .color(dept.1.opacity(0.85)), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        let mid = (Double(d) * 90 - 135) * .pi / 180
                        ctx.draw(Text(dept.0).font(HUD.label(10)).foregroundStyle(dept.1), at: CGPoint(x: c.x + cos(mid) * (arcR - 22), y: c.y + sin(mid) * (arcR - 22)))
                    }
                    for (spot, p) in positions {
                        var line = Path(); line.move(to: c); line.addLine(to: p)
                        let hot = hover == spot.id
                        ctx.stroke(line, with: .color(depts[spot.dept].1.opacity(hot ? 0.95 : 0.25)), lineWidth: hot ? 1.6 : 0.8)
                    }
                }
                Button { model.inspect(path: center, title: "~/.claude/CLAUDE.md", kind: .doc, detail: "Your rules for every Claude session") } label: {
                    Text("CLAUDE.md").font(HUD.mono(11, .bold)).foregroundStyle(HUD.text)
                        .frame(width: 92, height: 92)
                        .background(Circle().fill(HUD.panel))
                        .overlay(Circle().strokeBorder(HUD.skills, lineWidth: 2))
                        .shadow(color: HUD.skills.opacity(0.5), radius: 16)
                }
                .buttonStyle(.plain)
                .position(c)
                ForEach(positions, id: \.0.id) { spot, p in
                    let col = depts[spot.dept].1
                    let hot = hover == spot.id
                    Button {
                        if let path = spot.path {
                            model.inspect(path: path, title: spot.label, kind: spot.dept == 0 ? .skill : spot.dept == 3 ? .connector : .doc)
                        } else {
                            withAnimation(HUD.spring) { tab = "routines" }
                        }
                    } label: {
                        VStack(spacing: 4) {
                            Circle().fill(col).frame(width: hot ? 16 : 12, height: hot ? 16 : 12).shadow(color: col, radius: hot ? 10 : 4)
                            Text(spot.label).font(HUD.mono(10)).foregroundStyle(hot ? HUD.text : HUD.text2).lineLimit(1).fixedSize()
                        }
                    }
                    .buttonStyle(.plain)
                    .onHover { h in withAnimation(HUD.quick) { hover = h ? spot.id : (hover == spot.id ? nil : hover) } }
                    .position(p)
                }
                Text("HOVER TO TRACE CONTEXT PATHWAYS · CLICK TO INSPECT").font(HUD.label(10)).tracking(1.2).foregroundStyle(HUD.text)
                    .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                    .background(RoundedRectangle(cornerRadius: 8).fill(HUD.bg.opacity(0.8)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.line))
                    .position(x: 220, y: 30)
            }
        }
        .background(RoundedRectangle(cornerRadius: HUD.radius).fill(HUD.bgRaised.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: HUD.radius).strokeBorder(HUD.line))
        .overlay(HUDCorners(color: HUD.apps).padding(4).allowsHitTesting(false))
    }
}

// MARK: - Skill telemetry: real tokens per skill, from your session logs

struct SkillRow: Identifiable { let id: String; let name: String; let usage: Usage; let model: String; let skill: Skill? }

private struct SkillTelemetryView: View {
    @Environment(AppModel.self) private var model
    @State private var retire: Skill?

    var body: some View {
        let s = model.snapshot
        var agg: [String: (Usage, [String: Int])] = [:]
        for x in s.sessions {
            for (k, u) in x.skillUse {
                var e = agg[k] ?? (Usage(), [:])
                e.0 = e.0 + u
                e.1[Pricing.shortName(x.model), default: 0] += 1
                agg[k] = e
            }
        }
        let find: (String) -> Skill? = { name in
            let parts = name.split(separator: ":").map(String.init)
            return s.skills.first { parts.count == 2 ? ($0.source == parts[0] && $0.name == parts[1]) : $0.name == name }
        }
        let rows = agg.map { k, v in SkillRow(id: k, name: k, usage: v.0, model: v.1.max { $0.value < $1.value }?.key ?? "—", skill: find(k)) }
            .sorted { $0.usage.total > $1.usage.total }
        let top = max(1, rows.first?.usage.total ?? 1)
        let usedNames = Set(agg.keys)
        let unused = s.skills.filter { $0.source == "user" && $0.tool == "claude-code" && !usedNames.contains($0.name) }

        return HStack(alignment: .top, spacing: Space.lg) {
            Panel(title: "Token footprint", dot: HUD.skills, trailing: Format.tokens(rows.reduce(0) { $0 + $1.usage.total }) + " tok") {
                Text("Proportional to tokens spent while each skill ran").font(HUD.mono(10)).foregroundStyle(HUD.text3)
                if rows.isEmpty {
                    EmptyHUD(symbol: "bolt", title: "No skill runs yet", message: "Run a skill in Claude Code and its token footprint appears here.")
                } else {
                    FlowBubbles(rows: rows, top: top) { r in if let k = r.skill { model.inspect(path: k.path + "/SKILL.md", title: r.name, kind: .skill) } }
                        .frame(maxWidth: .infinity, minHeight: 470)
                }
            }
            .frame(width: 440)
            VStack(spacing: Space.lg) {
                Panel(title: "Skill efficiency & routing", dot: HUD.skills, trailing: "ranked by tokens") {
                    VStack(spacing: Space.sm) {
                        ForEach(rows) { r in
                            HoverRow {
                                VStack(spacing: Space.sm) {
                                    HStack(spacing: Space.sm) {
                                        Text("/\(r.name)").font(HUD.mono(12.5, .semibold)).foregroundStyle(HUD.text)
                                        Tag(text: r.model, tint: r.model.hasPrefix("Opus") ? HUD.high : r.model.hasPrefix("Haiku") ? HUD.memory : HUD.skills)
                                        Spacer()
                                        Text("\(r.usage.runs) runs · \(Format.tokens(r.usage.total)) tok · \(Format.money(r.usage.cost))").font(HUD.mono(10.5)).foregroundStyle(HUD.text2)
                                        Button("Optimize") { optimize(r) }.buttonStyle(.hud(HUD.memory)).disabled(r.skill == nil)
                                            .help("Ask Jarvis to tighten this skill and suggest a cheaper model")
                                        Button("Retire") { retire = r.skill }.buttonStyle(.hud(HUD.text3)).disabled(r.skill?.source != "user")
                                            .help(r.skill?.source == "user" ? "Move it out of the skills folder" : "Plugin skills are managed by their plugin")
                                    }
                                    Meter(value: Double(r.usage.total) / Double(top), colors: [HUD.skills, HUD.routines], height: 4)
                                }
                            }
                        }
                    }
                }
                Panel(title: "Never used", dot: HUD.text3, trailing: "\(unused.count) Claude Code skills") {
                    Text("Skills with no recorded runs. Retiring them keeps them out of every session's skill list.")
                        .font(.system(size: 11.5)).foregroundStyle(HUD.text2)
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(unused) { k in
                                HStack {
                                    Text(k.name).font(HUD.mono(11)).foregroundStyle(HUD.text)
                                    Spacer()
                                    Button("Inspect") { model.inspect(path: k.path + "/SKILL.md", title: k.name, kind: .skill) }.buttonStyle(.hud(HUD.text3))
                                    Button("Retire") { retire = k }.buttonStyle(.hud(HUD.text3))
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
        }
        .alert("Retire \(retire?.name ?? "")?", isPresented: Binding(get: { retire != nil }, set: { if !$0 { retire = nil } })) {
            Button("Retire") {
                guard let k = retire else { return }
                do {
                    let dest = try Actions.retireSkill(path: k.path, tool: k.tool)
                    model.flash("Retired to \(dest.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
                    Task { await model.refresh() }
                } catch { model.flash(error.localizedDescription) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its folder moves to ~/.agentos/retired-skills/. Move it back to restore it.")
        }
    }

    private func optimize(_ r: SkillRow) {
        guard let k = r.skill else { return }
        withAnimation(HUD.spring) { model.jarvisOpen = true }
        model.jarvis.send("Read \(k.path)/SKILL.md. It ran \(r.usage.runs) times and used \(Format.tokens(r.usage.total)) tokens on \(r.model). Suggest a tighter version of the instructions and whether a cheaper model would do. Don't edit the file.")
    }
}

/// Bubbles sized by token spend.
private struct FlowBubbles: View {
    let rows: [SkillRow]
    let top: Int
    let tap: (SkillRow) -> Void
    @State private var hover: String?

    var body: some View {
        let items = Array(rows.prefix(9))
        GeometryReader { g in
            ZStack {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, r in
                    let d = 70 + 110 * sqrt(Double(r.usage.total) / Double(top))
                    let col = i % 3 == 1 ? HUD.high : i % 3 == 2 ? HUD.memory : HUD.skills
                    let x = (Double(i % 2) + (i / 2 % 2 == 0 ? 0.5 : 0.75)) / 2.2 * g.size.width
                    let y = 90 + Double(i / 2) * 140
                    Button { tap(r) } label: {
                        VStack(spacing: 3) {
                            Text("/\(r.name)").font(HUD.mono(10.5, .semibold)).foregroundStyle(HUD.text).lineLimit(1).frame(maxWidth: d - 12)
                            Text(Format.tokens(r.usage.total)).font(HUD.mono(10)).foregroundStyle(HUD.text2)
                        }
                        .frame(width: d, height: d)
                        .background(Circle().fill(col.opacity(hover == r.id ? 0.3 : 0.16)))
                        .overlay(Circle().strokeBorder(col.opacity(0.7), lineWidth: 1.2))
                        .shadow(color: col.opacity(hover == r.id ? 0.5 : 0), radius: 14)
                        .scaleEffect(hover == r.id ? 1.05 : 1)
                    }
                    .buttonStyle(.plain)
                    .onHover { h in withAnimation(HUD.quick) { hover = h ? r.id : nil } }
                    .position(x: x, y: y)
                }
            }
        }
    }
}

// MARK: - Routines: jobs Agent OS runs on a schedule

private struct RoutinesView: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Routine?

    var body: some View {
        let runs = model.routineRuns.filter { $0.date > model.now.addingTimeInterval(-7 * 86_400) }
        let weekCost = runs.reduce(0) { $0 + $1.costUSD }
        let active = model.routines.filter(\.enabled)
        let perWeek = active.reduce(0) { $0 + ($1.weekdays.isEmpty ? 7 : $1.weekdays.count) }
        let today = Calendar.current.component(.weekday, from: model.now)
        ScrollView {
            VStack(spacing: Space.lg) {
                HStack(spacing: Space.lg) {
                    Panel { Metric(label: "Runs this week", value: "\(runs.count)", sub: "\(runs.filter { $0.status == "ok" }.count) succeeded").frame(maxWidth: .infinity, alignment: .leading) }
                    Panel { Metric(label: "Cost this week", value: Format.money(weekCost), tint: HUD.routines, sub: "Local routines are free").frame(maxWidth: .infinity, alignment: .leading) }
                    Panel { Metric(label: "Active routines", value: "\(active.count)", tint: HUD.routines, sub: "\(perWeek) scheduled runs / week").frame(maxWidth: .infinity, alignment: .leading) }
                }
                Panel(title: "Weekly execution cadence", dot: HUD.routines) {
                    HStack(spacing: Space.sm) {
                        ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { wd in
                            VStack(spacing: Space.sm) {
                                Text(Calendar.current.shortWeekdaySymbols[wd - 1].uppercased()).font(HUD.label(10)).foregroundStyle(wd == today ? HUD.routines : HUD.text3)
                                HStack(spacing: 4) {
                                    ForEach(active.filter { $0.runs(on: wd) }) { r in Circle().fill(color(r)).frame(width: 7, height: 7).help(r.name) }
                                }
                                .frame(height: 8)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, Space.md)
                            .background(RoundedRectangle(cornerRadius: 9).fill(HUD.bg.opacity(0.6)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(wd == today ? HUD.routines.opacity(0.8) : HUD.line))
                        }
                    }
                }
                Panel(title: "Routines", dot: HUD.routines, trailing: "runs while Agent OS is open (menu bar)") {
                    HStack {
                        Text("ROUTINE").frame(maxWidth: .infinity, alignment: .leading)
                        Text("CADENCE").frame(width: 150, alignment: .leading)
                        Text("TYPE").frame(width: 130, alignment: .leading)
                        Text("WEEK / CAP").frame(width: 130, alignment: .trailing)
                        Text("ACTIONS").frame(width: 250, alignment: .trailing)
                    }
                    .font(HUD.label(9.5)).tracking(1).foregroundStyle(HUD.text3)
                    ForEach(model.routines) { r in row(r) }
                    HStack {
                        Button { editing = Routine(name: "New routine", kind: .prompt, hour: 9, model: "haiku", prompt: "", weeklyCapINR: 200, enabled: false) } label: {
                            Label("Add routine", systemImage: "plus")
                        }
                        .buttonStyle(.hud(HUD.routines, prominent: true))
                        Spacer()
                    }
                }
                Panel(title: "Recent runs", dot: HUD.text2) {
                    ForEach(model.routineRuns.suffix(12).reversed()) { run in
                        HStack(spacing: Space.md) {
                            Circle().strokeBorder(run.status == "ok" ? HUD.on : HUD.off, lineWidth: 1.5).frame(width: 9, height: 9)
                            Text(model.routines.first { $0.id == run.routineID }?.name ?? run.routineID).font(HUD.mono(11, .medium)).foregroundStyle(HUD.text).frame(width: 190, alignment: .leading)
                            Text(run.summary).font(.system(size: 11)).foregroundStyle(HUD.text2).lineLimit(1)
                            Spacer()
                            Text(run.costUSD > 0 ? Format.money(run.costUSD) : "free").font(HUD.mono(10)).foregroundStyle(HUD.text3)
                            Text(run.date.relative).font(HUD.mono(10)).foregroundStyle(HUD.text3).frame(width: 70, alignment: .trailing)
                        }
                    }
                    if model.routineRuns.isEmpty { Text("No runs yet. Press Run now on any routine.").font(HUD.mono(10.5)).foregroundStyle(HUD.text3) }
                }
            }
        }
        .scrollIndicators(.never)
        .sheet(item: $editing) { r in RoutineEditor(routine: r) }
    }

    private func color(_ r: Routine) -> Color {
        switch r.kind {
        case .briefing: HUD.cyan
        case .costDigest: HUD.routines
        case .clutterWatch: HUD.pink
        case .memoryCapture: HUD.memory
        case .prompt: HUD.high
        }
    }

    private func row(_ r: Routine) -> some View {
        HoverRow {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Circle().fill(color(r)).frame(width: 7, height: 7)
                        Text(r.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(HUD.text)
                    }
                    Text(r.enabled ? "NEXT · \(r.nextRun(after: model.now).formatted(.dateTime.weekday(.abbreviated).hour().minute())) IST" : "PAUSED")
                        .font(HUD.label(9)).foregroundStyle(HUD.text3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(r.cadence).font(HUD.mono(11)).foregroundStyle(HUD.text2).frame(width: 150, alignment: .leading)
                Tag(text: r.kind.usesClaude ? "\(r.model) · claude" : "local · free", tint: r.kind.usesClaude ? HUD.high : HUD.memory).frame(width: 130, alignment: .leading)
                Text(r.kind.usesClaude ? "\(Format.inr(model.weeklySpendINR(r))) / \(Format.inr(r.weeklyCapINR))" : "—")
                    .font(HUD.mono(10.5)).foregroundStyle(HUD.text2).frame(width: 130, alignment: .trailing)
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(get: { r.enabled }, set: { on in
                        if let i = model.routines.firstIndex(where: { $0.id == r.id }) { model.routines[i].enabled = on; model.saveRoutines() }
                    }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().tint(HUD.on)
                    if model.runningRoutine == r.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Run now") { Task { await model.run(r) } }.buttonStyle(.hud(HUD.routines)).disabled(model.runningRoutine != nil)
                    }
                    Button("Edit") { editing = r }.buttonStyle(.hud(HUD.text3))
                }
                .frame(width: 250, alignment: .trailing)
            }
        }
    }
}

private struct RoutineEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var routine: Routine

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("ROUTINE").font(HUD.label(10)).tracking(2).foregroundStyle(HUD.routines)
            TextField("Name", text: $routine.name).textFieldStyle(.roundedBorder)
            Picker("Type", selection: $routine.kind) { ForEach(Routine.Kind.allCases, id: \.self) { Text($0.label).tag($0) } }
            HStack {
                Stepper("Hour \(routine.hour)", value: $routine.hour, in: 0...23)
                Stepper("Minute \(String(format: "%02d", routine.minute))", value: $routine.minute, in: 0...55, step: 5)
            }
            HStack(spacing: 4) {
                Text("Days").font(.system(size: 12)).foregroundStyle(HUD.text2)
                ForEach(1...7, id: \.self) { d in
                    let on = routine.weekdays.isEmpty || routine.weekdays.contains(d)
                    Button(Calendar.current.veryShortWeekdaySymbols[d - 1]) {
                        var set = Set(routine.weekdays.isEmpty ? Array(1...7) : routine.weekdays)
                        if on { set.remove(d) } else { set.insert(d) }
                        routine.weekdays = set.count == 7 ? [] : set.sorted()
                    }
                    .buttonStyle(.hud(on ? HUD.routines : HUD.text3, prominent: on))
                }
            }
            if routine.kind.usesClaude {
                Picker("Model", selection: $routine.model) { Text("Haiku").tag("haiku"); Text("Sonnet").tag("sonnet"); Text("Opus").tag("opus") }
                TextField("Weekly cap (₹)", value: $routine.weeklyCapINR, format: .number).textFieldStyle(.roundedBorder)
            }
            if routine.kind == .prompt {
                Text("Prompt").font(.system(size: 12)).foregroundStyle(HUD.text2)
                TextEditor(text: $routine.prompt).font(HUD.mono(11.5)).frame(height: 120)
                    .scrollContentBackground(.hidden).padding(6).background(RoundedRectangle(cornerRadius: 8).fill(HUD.panel))
            }
            Toggle("Enabled", isOn: $routine.enabled)
            HStack {
                if model.routines.contains(where: { $0.id == routine.id }) {
                    Button("Delete", role: .destructive) {
                        model.routines.removeAll { $0.id == routine.id }
                        model.saveRoutines()
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    if let i = model.routines.firstIndex(where: { $0.id == routine.id }) { model.routines[i] = routine } else { model.routines.append(routine) }
                    model.saveRoutines()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(routine.name.isEmpty || (routine.kind == .prompt && routine.prompt.isEmpty))
            }
        }
        .padding(Space.xl)
        .frame(width: 520)
        .background(HUD.bgRaised)
        .preferredColorScheme(.dark)
    }
}

/// Zoom, reset and fly-to buttons for the galaxy camera.
struct CameraControls: View {
    let control: BrainControl
    var hasSelection: Bool

    var body: some View {
        VStack(spacing: 6) {
            Text(control.zoomLabel).font(HUD.label(9.5)).foregroundStyle(HUD.cyan).contentTransition(.numericText())
            Button { control.zoom(1) } label: { Image(systemName: "plus") }.buttonStyle(.hud(HUD.cyan)).help("Zoom in")
            Button { control.zoom(-1) } label: { Image(systemName: "minus") }.buttonStyle(.hud(HUD.cyan)).help("Zoom out")
            Button { control.focusSelected() } label: { Image(systemName: "scope") }.buttonStyle(.hud(HUD.skills)).disabled(!hasSelection)
                .help("Fly to the selected node and follow its orbit")
            Button { control.reset() } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.hud(HUD.text3)).help("Back to the whole galaxy")
        }
        .padding(Space.sm)
        .background(RoundedRectangle(cornerRadius: 12).fill(HUD.bg.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(HUD.line))
    }
}

/// Switches how the brain is drawn: galaxy, neural, wormhole, filament star, holo globe, radial dial, synapse flow, neuron burst.
struct StylePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            ForEach(BrainStyle.allCases) { s in
                Button { withAnimation(HUD.spring) { model.brainStyle = s } } label: {
                    Label(s.title, systemImage: model.brainStyle == s ? "checkmark" : s.symbol)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.brainStyle.symbol)
                Text(model.brainStyle.title.uppercased()).font(HUD.label(9.5)).tracking(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(HUD.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(HUD.bg.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.skills.opacity(0.6)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Change how your brain is drawn")
    }
}
