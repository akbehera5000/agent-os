import AgentOSKit
import SwiftUI

/// The live strip under the brain: what your AIs are doing right now, how your brain is balanced,
/// when you burn tokens, and an overall health score. Every cell is clickable.
struct TelemetryDeck: View {
    var body: some View {
        HStack(spacing: Space.md) {
            ActivityLog().frame(minWidth: 230, maxWidth: .infinity).layoutPriority(1)
            PillarRadar().frame(width: 150)
            TokenHeat().frame(width: 220)
            HealthGauge().frame(width: 132)
        }
        .frame(height: 178)
    }
}

private struct Cell<Content: View>: View {
    let title: String
    let trailing: String
    var tint: Color = HUD.cyan
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(title).font(HUD.label(10)).tracking(1.4).foregroundStyle(HUD.text)
                Spacer()
                Text(trailing).font(HUD.label(9)).foregroundStyle(tint)
            }
            content
        }
        .padding(Space.md)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 10).fill(HUD.bgRaised.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HUD.line))
        .overlay(HUDCorners(color: tint.opacity(0.6), length: 7).padding(2).allowsHitTesting(false))
    }
}

/// Live tail of your latest Claude Code sessions: every prompt and tool call as it happens.
private struct ActivityLog: View {
    @Environment(AppModel.self) private var model

    static func color(_ verb: String) -> Color {
        switch verb {
        case "ASK": HUD.cyan
        case "READ", "GREP", "GLOB": HUD.apps
        case "EDIT", "WRITE": HUD.routines
        case "BASH": HUD.memory
        case "SKILL": HUD.skills
        default: HUD.high
        }
    }

    var body: some View {
        let perMin = model.activity.filter { model.now.timeIntervalSince($0.date) < 600 }.count
        Cell(title: "ACTIVITY LOG", trailing: perMin > 0 ? "● LIVE · \(perMin)/10M" : "IDLE", tint: perMin > 0 ? HUD.memory : HUD.text3) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.activity) { a in
                        HStack(spacing: Space.sm) {
                            Text(a.date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))).font(HUD.mono(9.5)).foregroundStyle(HUD.text3)
                            Text(a.verb.prefix(6)).font(HUD.mono(9.5, .bold)).foregroundStyle(Self.color(a.verb)).frame(width: 44, alignment: .leading).lineLimit(1)
                            Text(a.target).font(HUD.mono(9.5)).foregroundStyle(HUD.text2).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(a.project).font(HUD.mono(8.5)).foregroundStyle(HUD.text3).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { model.go(.timeline) }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if model.activity.isEmpty { Text("Waiting for activity…").font(HUD.mono(10)).foregroundStyle(HUD.text3) }
                }
            }
            .scrollIndicators(.never)
        }
    }
}

/// How your brain is balanced across the pillars (log scale). Click to open the Second Brain.
private struct PillarRadar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        let axes: [(String, Double, Color)] = [
            ("SKL", Double(s.skills.count), HUD.skills), ("MEM", Double(s.notes.count + s.docs.count), HUD.memory),
            ("SES", Double(s.sessions.count), HUD.routines), ("APP", Double(s.tools.count), HUD.apps),
            ("MCP", Double(s.connectors.count), HUD.high), ("ART", Double(s.assets.count), HUD.pink),
        ]
        let maxLog = max(1, axes.map { log10(1 + $0.1) }.max() ?? 1)
        Cell(title: "PILLAR RADAR", trailing: "LIVE", tint: HUD.skills) {
            Canvas { ctx, size in
                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r = min(size.width, size.height) / 2 - 14
                func pt(_ i: Int, _ f: Double) -> CGPoint {
                    let a = Double(i) / Double(axes.count) * 2 * .pi - .pi / 2
                    return CGPoint(x: c.x + cos(a) * r * f, y: c.y + sin(a) * r * f)
                }
                for k in [0.33, 0.66, 1.0] {
                    var ring = Path()
                    for i in 0...axes.count { i == 0 ? ring.move(to: pt(0, k)) : ring.addLine(to: pt(i % axes.count, k)) }
                    ctx.stroke(ring, with: .color(HUD.line), lineWidth: 0.7)
                }
                var shape = Path()
                for (i, ax) in axes.enumerated() {
                    let p = pt(i, max(0.08, log10(1 + ax.1) / maxLog))
                    i == 0 ? shape.move(to: p) : shape.addLine(to: p)
                    ctx.draw(Text(ax.0).font(HUD.label(8)).foregroundStyle(ax.2), at: pt(i, 1.18))
                }
                shape.closeSubpath()
                ctx.fill(shape, with: .color(HUD.cyan.opacity(0.22)))
                ctx.stroke(shape, with: .color(HUD.cyan), lineWidth: 1.4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.go(.brain) }
        .help("Skills, memory, sessions, apps, connectors, artifacts — open the Second Brain")
    }
}

/// Tokens by hour of day over the last 7 days. Hover a cell for the number.
private struct TokenHeat: View {
    @Environment(AppModel.self) private var model
    @State private var hover: (Int, Int)?

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: model.now)
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        for s in model.snapshot.sessions where s.end > today.addingTimeInterval(-7 * 86_400) {
            for p in s.points {
                let d = cal.dateComponents([.day], from: cal.startOfDay(for: p.date), to: today).day ?? 99
                if d >= 0 && d < 7 { grid[6 - d][cal.component(.hour, from: p.date)] += p.tokens }
            }
        }
        let peak = max(1, grid.flatMap { $0 }.max() ?? 1)
        return Cell(title: "TOKEN HEAT", trailing: hover.map { h in "\(Format.tokens(grid[h.0][h.1])) @ \(h.1):00" } ?? "7D × 24H", tint: HUD.routines) {
            VStack(spacing: 2) {
                ForEach(0..<7, id: \.self) { row in
                    HStack(spacing: 2) {
                        Text(cal.date(byAdding: .day, value: row - 6, to: today)!.formatted(.dateTime.weekday(.narrow)))
                            .font(HUD.mono(8)).foregroundStyle(HUD.text3).frame(width: 10)
                        ForEach(0..<24, id: \.self) { h in
                            let v = Double(grid[row][h]) / Double(peak)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(v == 0 ? HUD.line.opacity(0.6) : HUD.routines.opacity(0.18 + 0.82 * sqrt(v)))
                                .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(hover.map { $0 == (row, h) } == true ? HUD.text : .clear))
                                .onHover { inside in hover = inside ? (row, h) : nil }
                        }
                    }
                }
                HStack {
                    Text("00").font(HUD.mono(8)).foregroundStyle(HUD.text3)
                    Spacer()
                    Text("12").font(HUD.mono(8)).foregroundStyle(HUD.text3)
                    Spacer()
                    Text("23 IST").font(HUD.mono(8)).foregroundStyle(HUD.text3)
                }
                .padding(.leading, 12)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.go(.usage) }
    }
}

/// One number for how healthy your AI setup is; hover for what drags it down.
private struct HealthGauge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        let broken = s.connectors.filter { $0.health == .missing }.count
        let clutterGB = Double(s.clutter.reduce(Int64(0)) { $0 + $1.bytes }) / 1e9
        let all = s.sessions.reduce(Usage()) { $0 + $1.usage }
        let base = Double(all.input + all.cacheRead + all.cacheWrite)
        let hit = base > 0 ? Double(all.cacheRead) / base : 1
        let penalties: [(String, Double)] = [
            ("\(broken) broken connector\(broken == 1 ? "" : "s")", Double(broken) * 8),
            ("\(model.pendingCorrections.count) corrections not yet rules", min(20, Double(model.pendingCorrections.count) * 3)),
            (String(format: "%.1f GB clutter", clutterGB), min(15, clutterGB * 10)),
            ("cache hit \(Int(hit * 100))%", max(0, (0.9 - hit) * 60)),
            (s.notes.count < 5 ? "memory has only \(s.notes.count) notes" : "", s.notes.count < 5 ? 10 : 0),
        ].filter { $0.1 > 0.5 }
        let score = max(0, min(100, 100 - penalties.reduce(0) { $0 + $1.1 }))
        let color = score > 80 ? HUD.memory : score > 60 ? HUD.routines : HUD.pink
        Cell(title: "HEALTH", trailing: "LIVE", tint: color) {
            ZStack {
                Circle().stroke(HUD.line, lineWidth: 8)
                Circle().trim(from: 0, to: score / 100)
                    .stroke(AngularGradient(colors: [color.opacity(0.5), color], center: .center), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: color.opacity(0.6), radius: 6)
                    .animation(HUD.slow, value: score)
                VStack(spacing: 0) {
                    Text("\(Int(score))").font(HUD.display(34)).foregroundStyle(HUD.text).contentTransition(.numericText())
                    Text("SCORE").font(HUD.label(8)).foregroundStyle(HUD.text3)
                }
            }
            .padding(Space.sm)
            .frame(maxWidth: .infinity)
            .help(penalties.isEmpty ? "All clear" : "Pulling it down: " + penalties.map(\.0).joined(separator: ", "))
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if broken > 0 { model.go(.connectors) } else if !model.pendingCorrections.isEmpty { model.go(.memory) } else { model.go(.janitor) }
        }
    }
}
