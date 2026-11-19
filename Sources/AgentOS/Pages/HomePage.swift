import AgentOSKit
import SwiftUI

/// Command center: AI stack on the left, the living orb in the middle, today and what needs you on the right.
struct HomePage: View {
    var body: some View {
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(spacing: Space.lg) {
                StackPanel().appear(0)
                ClockPanel().appear(1)
            }
            .frame(width: 270)

            VStack(spacing: Space.lg) {
                OrbStage()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                TelemetryDeck().appear(5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView {
                VStack(spacing: Space.lg) {
                    TodayPanel().appear(2)
                    RecentPanel().appear(3)
                    NeedsYouPanel().appear(4)
                }
            }
            .scrollIndicators(.never)
            .frame(width: 320)
        }
        .padding(Space.lg)
    }
}

// MARK: Left

private struct StackPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel(title: "AI Stack", dot: HUD.apps, trailing: "\(model.snapshot.tools.count) installed") {
            ScrollView {
                VStack(spacing: Space.sm) {
                    ForEach(Array(model.snapshot.tools.enumerated()), id: \.element.id) { i, t in
                        HoverRow {
                            HStack(spacing: Space.md) {
                                IconTile(symbol: t.symbol, tint: HUD.hue(t.hue), size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(HUD.text)
                                    Text(detail(t)).font(HUD.mono(9.5)).foregroundStyle(HUD.text3).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Circle().strokeBorder(recent(t) ? HUD.on : HUD.off, lineWidth: 1.5).frame(width: 9, height: 9)
                                    .help(recent(t) ? "Used in the last 3 days" : "Idle")
                            }
                        }
                        .onTapGesture { if let p = t.appPath { model.open(p) } else if let c = t.configDir { model.reveal(c) } }
                        .help(t.appPath != nil ? "Open \(t.name)" : "Show its folder in Finder")
                        .appear(i)
                    }
                    if !model.firstScanDone { ProgressView().controlSize(.small).padding() }
                }
            }
            .scrollIndicators(.never)
        }
    }

    private func recent(_ t: AITool) -> Bool { (t.lastUsed ?? .distantPast) > Date.now.addingTimeInterval(-3 * 86_400) }

    private func detail(_ t: AITool) -> String {
        var bits: [String] = []
        if t.sessionCount > 0 { bits.append("\(t.sessionCount) sess") }
        if t.skillCount > 0 { bits.append("\(t.skillCount) skills") }
        if t.connectorCount > 0 { bits.append("\(t.connectorCount) mcp") }
        if bits.isEmpty { bits.append(t.kind) }
        return bits.joined(separator: " · ")
    }
}

private struct ClockPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let days = Analytics.daily(model.snapshot.sessions, days: 14, now: model.now)
        let peak = max(0.01, days.map(\.cost).max() ?? 0)
        Panel(title: "Time", dot: HUD.text2, trailing: "IST · UTC+5:30") {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(model.now.formatted(.dateTime.hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits).second(.twoDigits)))
                    .font(.system(size: 32, weight: .thin, design: .monospaced)).foregroundStyle(HUD.text)
                    .contentTransition(.numericText()).monospacedDigit()
                Text(model.now.formatted(.dateTime.weekday(.wide).month(.wide).day().year())).font(HUD.mono(11)).foregroundStyle(HUD.text2)
            }
            VStack(alignment: .leading, spacing: Space.sm) {
                Text("14-DAY SPEND").font(HUD.label(9)).tracking(1.2).foregroundStyle(HUD.text3)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(LinearGradient(colors: [HUD.skills, HUD.routines], startPoint: .bottom, endPoint: .top).opacity(i == days.count - 1 ? 1 : 0.55))
                            .frame(height: max(2, 46 * d.cost / peak))
                            .help("\(d.day.formatted(.dateTime.month().day())): \(Format.money(d.cost)) · \(Format.tokens(d.tokens)) tokens")
                    }
                }
                .frame(height: 46, alignment: .bottom)
            }
            Button { model.jarvis.briefing() } label: { Label("Brief me", systemImage: "waveform") }
                .buttonStyle(.hud(HUD.cyan, prominent: true))
        }
    }
}

// MARK: Center

/// The live brain inside a ring of your newest artifacts, with a filter that lights up matches.
private struct OrbStage: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var hoverArtifact: String?
    @State private var control = BrainControl()

    var body: some View {
        let artifacts = Array(model.snapshot.assets.prefix(24))
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let matchesArtifact: (DesignAsset) -> Bool = { a in q.isEmpty || a.name.lowercased().contains(q) || a.kind.lowercased().contains(q) }
        let highlight: Set<Int>? = q.isEmpty ? nil : Set(model.graph.nodes.indices.filter { model.graph.nodes[$0].label.lowercased().contains(q) })
        VStack(spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(HUD.text3)
                TextField("Filter \(artifacts.count) artifacts and \(model.graph.nodes.count) brain nodes (decks, pdf, scripts, skills)…", text: $filter)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(HUD.text)
                if !q.isEmpty {
                    Text("\(artifacts.filter(matchesArtifact).count + (highlight?.count ?? 0)) MATCHES").font(HUD.label(9)).foregroundStyle(HUD.cyan)
                }
            }
            .padding(.horizontal, Space.lg).padding(.vertical, Space.sm + 2)
            .frame(maxWidth: 560)
            .background(RoundedRectangle(cornerRadius: 12).fill(HUD.panel.opacity(0.9)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(q.isEmpty ? HUD.line : HUD.cyan.opacity(0.6)))
            GeometryReader { g in
                let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                ZStack {
                    // The brain fills the whole stage; the artifact ring floats over its rim.
                    BrainView(graph: model.graph, selected: model.selectedNode, highlight: highlight,
                              energy: model.jarvis.busy || model.jarvis.listening ? 1 : 0, compact: true, control: control,
                              style: model.brainStyle) { model.select(node: $0) }
                        .frame(width: g.size.width, height: g.size.height)
                        .position(c)
                    StylePicker().position(x: g.size.width / 2, y: 18)
                    // Artifacts line up in two columns at the sides, next to the panels.
                    let half = (artifacts.count + 1) / 2
                    let rowH = (g.size.height - 40) / CGFloat(max(1, half))
                    ForEach(Array(artifacts.enumerated()), id: \.element.id) { i, a in
                        let leftSide = i < half
                        let row = CGFloat(leftSide ? i : i - half)
                        let px = leftSide ? 26.0 : g.size.width - 26
                        let py = 20 + rowH * (row + 0.5)
                        let match = matchesArtifact(a)
                        ArtifactChip(asset: a, hot: hoverArtifact == a.id || (!q.isEmpty && match), dim: !match)
                            .onHover { h in withAnimation(HUD.quick) { hoverArtifact = h ? a.id : nil } }
                            .onTapGesture { model.inspect(path: a.path, title: a.name, kind: .artifact, detail: "\(a.kind) · \(Format.bytes(a.bytes))") }
                            .position(x: px, y: py)
                    }
                    if let id = hoverArtifact, let a = artifacts.first(where: { $0.id == id }) {
                        VStack(spacing: 2) {
                            Text(a.name).font(HUD.mono(11, .semibold)).foregroundStyle(HUD.text).lineLimit(1)
                            Text("\(a.kind) · \(Format.bytes(a.bytes)) · \(a.modified.relative)").font(HUD.mono(9.5)).foregroundStyle(HUD.text2)
                        }
                        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                        .background(RoundedRectangle(cornerRadius: 8).fill(HUD.bg.opacity(0.92)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.lineHi))
                        .position(x: c.x, y: g.size.height - 24)
                        .allowsHitTesting(false)
                    }
                }
            }
            AskBar()
        }
    }
}

/// One artifact on the ring: icon by type, glows when it matches the filter.
private struct ArtifactChip: View {
    let asset: DesignAsset
    let hot: Bool
    let dim: Bool

    static func style(_ kind: String) -> (String, Color) {
        switch kind {
        case "Deck": ("chart.bar.doc.horizontal", HUD.skills)
        case "PDF": ("doc.richtext", HUD.pink)
        case "Doc": ("doc.text", HUD.routines)
        case "Script": ("chevron.left.forwardslash.chevron.right", HUD.memory)
        case "Image": ("photo", HUD.apps)
        case "Video": ("film", HUD.high)
        case "Design": ("paintpalette", HUD.cyan)
        case "Sheet": ("tablecells", HUD.memory)
        case "Build", "Archive": ("shippingbox", HUD.text2)
        default: ("doc", HUD.text2)
        }
    }

    var body: some View {
        let (symbol, tint) = Self.style(asset.kind)
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .background(Circle().fill(hot ? tint.opacity(0.22) : HUD.panel))
            .overlay(Circle().strokeBorder(hot ? tint : HUD.lineHi, lineWidth: hot ? 1.5 : 1))
            .shadow(color: tint.opacity(hot ? 0.6 : 0), radius: 12)
            .scaleEffect(hot ? 1.12 : 1)
            .opacity(dim ? 0.25 : 1)
            .contentShape(Circle())
            .help(asset.name)
    }
}

private struct AskBar: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "waveform.circle.fill").foregroundStyle(HUD.cyan).font(.system(size: 16))
            TextField("Ask Jarvis — “how much did I spend this week?”", text: $text)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(HUD.text)
                .onSubmit {
                    guard !text.isEmpty else { return }
                    withAnimation(HUD.spring) { model.jarvisOpen = true }
                    model.jarvis.send(text)
                    text = ""
                }
            Button {
                withAnimation(HUD.spring) { model.jarvisOpen = true }
                model.jarvis.toggleListening()
            } label: { Image(systemName: "mic.fill") }
                .buttonStyle(.hud(HUD.cyan))
                .help("Talk to Jarvis")
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm + 2)
        .frame(maxWidth: 520)
        .background(Capsule().fill(HUD.panel.opacity(0.9)))
        .overlay(Capsule().strokeBorder(LinearGradient(colors: [HUD.cyan.opacity(0.55), HUD.high.opacity(0.35)], startPoint: .leading, endPoint: .trailing)))
        .shadow(color: HUD.cyan.opacity(0.15), radius: 18)
    }
}

// MARK: Right

private struct TodayPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let t = model.today
        let sessionsToday = model.snapshot.sessions.filter { Calendar.current.isDateInToday($0.end) }.count
        Panel(title: "Today", dot: HUD.routines, trailing: "API-equivalent") {
            Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: Space.md) {
                GridRow {
                    Metric(label: "Spend", value: Format.money(t.cost), tint: HUD.routines)
                    Metric(label: "Tokens", value: Format.tokens(t.tokens))
                }
                GridRow {
                    Metric(label: "Sessions", value: "\(sessionsToday)")
                    Metric(label: "Week", value: Format.money(model.week.cost), tint: HUD.skills)
                }
            }
        }
    }
}

private struct RecentPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel(title: "Recent sessions", dot: HUD.routines, trailing: "click to resume") {
            VStack(spacing: Space.sm) {
                ForEach(model.snapshot.sessions.prefix(5)) { s in
                    HoverRow {
                        HStack(spacing: Space.sm) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(.system(size: 12, weight: .medium)).foregroundStyle(HUD.text).lineLimit(1)
                                Text("\(TextRules.projectName(s.cwd)) · \(ToolCatalog.name(s.tool)) · \(s.end.relative)")
                                    .font(HUD.mono(9.5)).foregroundStyle(HUD.text3).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(Format.money(s.usage.cost)).font(HUD.mono(10)).foregroundStyle(HUD.text2)
                        }
                    }
                    .onTapGesture { model.resume(s) }
                    .help("Resume in Terminal")
                }
                if model.snapshot.sessions.isEmpty && model.firstScanDone {
                    Text("No sessions found yet.").font(HUD.mono(11)).foregroundStyle(HUD.text3)
                }
            }
        }
    }
}

private struct NeedsYouPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.snapshot
        let broken = s.connectors.filter { $0.health == .missing }.count
        let clutter = s.clutter.reduce(Int64(0)) { $0 + $1.bytes }
        let dupes = s.projects.filter { $0.locations.count > 1 }.count
        Panel(title: "Needs you", dot: HUD.pink) {
            VStack(spacing: Space.sm) {
                card("text.badge.checkmark", HUD.memory, "\(model.pendingCorrections.count) corrections → rules", "Teach every AI app at once", .memory)
                card("exclamationmark.triangle", HUD.high, "\(broken) broken connector\(broken == 1 ? "" : "s")", "\(s.connectors.count) configured in total", .connectors)
                card("sparkles", HUD.pink, "\(Format.bytes(clutter)) of clutter", "\(s.clutter.count) items, moved to Trash on confirm", .janitor)
                card("square.on.square", HUD.apps, "\(dupes) projects in several places", "See every copy in one passport", .projects)
            }
        }
    }

    private func card(_ symbol: String, _ tint: Color, _ title: String, _ sub: String, _ page: Page) -> some View {
        HoverRow {
            HStack(spacing: Space.md) {
                IconTile(symbol: symbol, tint: tint, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(HUD.text).contentTransition(.numericText())
                    Text(sub).font(HUD.mono(9.5)).foregroundStyle(HUD.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(HUD.text3)
            }
        }
        .onTapGesture { model.go(page) }
    }
}
