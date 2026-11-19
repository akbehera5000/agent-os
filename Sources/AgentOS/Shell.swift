import AgentOSKit
import SwiftUI

/// The main window: top bar, left rail, page, bottom dock, plus the Jarvis panel and ⌘K palette.
struct Shell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Namespace private var rail

    var body: some View {
        ZStack {
            Backdrop()
            VStack(spacing: 0) {
                TopBar()
                HStack(spacing: 0) {
                    Rail(ns: rail)
                    page
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                Dock()
            }
            if model.jarvisOpen {
                HStack {
                    Spacer()
                    JarvisPanel()
                        .overlayZone("jarvis")
                        .frame(width: 420)
                        .padding(.top, 64).padding(.bottom, 52).padding(.trailing, Space.md)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(2)
            }
            if let target = model.inspector, !model.jarvisOpen {
                HStack {
                    Spacer()
                    InspectorPanel(target: target)
                        .overlayZone("inspector")
                        .frame(width: 460)
                        .padding(.top, 64).padding(.bottom, 52).padding(.trailing, Space.md)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(2)
            }
            if model.paletteOpen {
                CommandPalette()
                    .overlayZone("palette")
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(3)
            }
            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast).font(HUD.mono(11, .medium)).foregroundStyle(HUD.text)
                        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm + 2)
                        .background(Capsule().fill(HUD.panelHi))
                        .overlay(Capsule().strokeBorder(HUD.lineHi))
                        .shadow(color: .black.opacity(0.5), radius: 16)
                        .padding(.bottom, 64)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(4)
            }
        }
        .preferredColorScheme(.dark)
        .task {
            model.start()
            SelfTest.runIfRequested(model: model)
            Screenshots.runIfRequested(model: model, openSettings: openSettings)
        }
    }

    @ViewBuilder private var page: some View {
        Group {
            switch model.page {
            case .home: HomePage()
            case .brain: SecondBrainPage()
            case .projects: ProjectsPage()
            case .timeline: TimelinePage()
            case .skills: SkillsPage()
            case .connectors: ConnectorsPage()
            case .usage: UsagePage()
            case .memory: MemoryPage()
            case .janitor: JanitorPage()
            case .shelf: ShelfPage()
            case .system: SystemPage()
            }
        }
        .id(model.page)
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)).combined(with: .scale(scale: 0.985)),
                                removal: .opacity))
    }
}

/// Deep black with a faint grid and two soft nebula glows. Drawn once, not animated.
struct Backdrop: View {
    var body: some View {
        ZStack {
            HUD.bg
            Canvas { ctx, size in
                let step: CGFloat = 32
                var path = Path()
                stride(from: 0, through: size.width, by: step).forEach { x in path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)) }
                stride(from: 0, through: size.height, by: step).forEach { y in path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)) }
                ctx.stroke(path, with: .color(Color.white.opacity(0.022)), lineWidth: 0.5)
            }
            RadialGradient(colors: [HUD.apps.opacity(0.10), .clear], center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0, endRadius: 520)
            RadialGradient(colors: [HUD.high.opacity(0.06), .clear], center: UnitPoint(x: 0.85, y: 0.1), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
        .drawingGroup()
    }
}

// MARK: - Top bar

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The title is centered on the window itself, so status text changing width never moves it.
        ZStack {
            HStack(spacing: Space.lg) {
                HStack(spacing: Space.sm) {
                    Circle().fill(model.online ? HUD.on : HUD.off).frame(width: 7, height: 7)
                        .shadow(color: model.online ? HUD.on : HUD.off, radius: 5)
                    Text(model.online ? "ONLINE" : "OFFLINE").font(HUD.label(10.5)).tracking(1.4).foregroundStyle(HUD.text)
                        .frame(width: 66, alignment: .leading)
                    Text("· \(model.snapshot.tools.count) AI TOOLS").font(HUD.label(10)).tracking(1).foregroundStyle(HUD.text3)
                    if model.scanning {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("SCANNING").font(HUD.label(9)).tracking(1).foregroundStyle(HUD.warn)
                        }
                        .transition(.opacity)
                    }
                }
                .padding(.leading, 80)
                .help(model.online ? "Connected to the internet. Offline AI keeps working without it." : "No internet. Jarvis answers with the offline model.")
                Spacer()
                HStack(spacing: Space.sm) {
                    Button { withAnimation(HUD.spring) { model.paletteOpen = true } } label: {
                        Label("Search", systemImage: "magnifyingglass")
                        Text("⌘K").foregroundStyle(HUD.text3)
                    }
                    .buttonStyle(.hud(HUD.text3))
                    Button { Task { await model.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").rotationEffect(.degrees(model.scanning ? 360 : 0))
                            .animation(model.scanning ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: model.scanning)
                    }
                    .buttonStyle(.hud(HUD.text3))
                    .help("Rescan (⌘R)")
                    Button { withAnimation(HUD.spring) { model.jarvisOpen.toggle() } } label: {
                        Label("Jarvis", systemImage: "waveform.circle")
                    }
                    .buttonStyle(.hud(HUD.cyan, prominent: model.jarvisOpen))
                    .help("Ask Jarvis (⌥⌘J from anywhere)")
                }
            }
            HStack(spacing: Space.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9).fill(HUD.skills.opacity(0.15))
                    RoundedRectangle(cornerRadius: 9).strokeBorder(HUD.skills.opacity(0.6))
                    Image(systemName: "circle.hexagongrid.fill").foregroundStyle(HUD.skills).font(.system(size: 15))
                }
                .frame(width: 30, height: 30)
                .shadow(color: HUD.skills.opacity(0.5), radius: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text("AGENT OS").font(.system(size: 15, weight: .bold, design: .monospaced)).tracking(4).foregroundStyle(HUD.text)
                    Text("Apps · Routines · Memory · Skills").font(HUD.mono(9.5)).tracking(1).foregroundStyle(HUD.text3)
                }
            }
            .fixedSize()
            .allowsHitTesting(false)
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 56)
        .background(HUD.bg.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(HUD.line).frame(height: 1) }
        .animation(HUD.quick, value: model.scanning)
    }
}

// MARK: - Rail

struct Rail: View {
    @Environment(AppModel.self) private var model
    var ns: Namespace.ID

    var body: some View {
        VStack(spacing: Space.xs) {
            ForEach(Page.allCases) { page in
                RailButton(page: page, selected: model.page == page, ns: ns, badge: badge(page)) { model.go(page) }
            }
            Spacer()
        }
        .padding(.vertical, Space.md)
        .frame(width: 68)
        .overlay(alignment: .trailing) { Rectangle().fill(HUD.line).frame(width: 1) }
    }

    private func badge(_ page: Page) -> Int {
        switch page {
        case .memory: model.pendingCorrections.count
        case .connectors: model.snapshot.connectors.filter { $0.health == .missing }.count
        default: 0
        }
    }
}

private struct RailButton: View {
    let page: Page
    let selected: Bool
    let ns: Namespace.ID
    let badge: Int
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(page.tint.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(page.tint.opacity(0.55)))
                        .shadow(color: page.tint.opacity(0.45), radius: 10)
                        .matchedGeometryEffect(id: "rail", in: ns)
                } else if hover {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HUD.panelHi)
                }
                Image(systemName: page.symbol)
                    .font(.system(size: 16, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? page.tint : (hover ? HUD.text : HUD.text2))
            }
            .frame(width: 44, height: 44)
            .overlay(alignment: .topTrailing) {
                if badge > 0 {
                    Text("\(min(badge, 99))").font(.system(size: 8.5, weight: .bold, design: .monospaced)).foregroundStyle(HUD.text)
                        .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                        .background(Capsule().fill(HUD.pink.opacity(0.85)))
                        .offset(x: 3, y: -3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(HUD.quick) { hover = h } }
        .help("\(page.title) (⌘\(String(page.key.character)))")
        .accessibilityLabel(page.title)
    }
}

// MARK: - Dock

struct Dock: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let week = model.week, five = model.fiveHours
        let cache = model.cacheLeft
        HStack(spacing: Space.xl) {
            meter("7D", week.cost * Format.inrPerUSD / model.weeklyBudgetINR, Format.money(week.cost), [HUD.skills, HUD.routines])
            meter("5H", five.cost * Format.inrPerUSD / model.fiveHourBudgetINR, Format.money(five.cost), [HUD.high, HUD.apps])
            Spacer()
            Text("TODAY \(Format.tokens(model.today.tokens)) TOK · \(Format.money(model.today.cost))")
                .font(HUD.label(10)).tracking(1).foregroundStyle(HUD.text2).contentTransition(.numericText())
            HStack(spacing: Space.sm) {
                Circle().fill(cache > 0 ? HUD.on : HUD.off).frame(width: 6, height: 6)
                Text(cache > 0 ? "CACHE WARM · \(Int(cache / 60))M LEFT" : "CACHE COLD")
                    .font(HUD.label(10)).tracking(1).foregroundStyle(HUD.text)
                    .contentTransition(.numericText())
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill((cache > 0 ? HUD.memory : HUD.text3).opacity(0.1)))
            .overlay(Capsule().strokeBorder(cache > 0 ? HUD.on.opacity(0.7) : HUD.off.opacity(0.7)))
            Text("₹\(String(format: "%.2f", Format.inrPerUSD))/$ · SCANNED \(model.snapshot.scannedAt.formatted(date: .omitted, time: .shortened)) IST")
                .font(HUD.label(9.5)).tracking(1).foregroundStyle(HUD.text3)
        }
        .padding(.horizontal, Space.lg)
        .frame(height: 40)
        .background(HUD.bg.opacity(0.75))
        .overlay(alignment: .top) { Rectangle().fill(HUD.line).frame(height: 1) }
    }

    private func meter(_ label: String, _ value: Double, _ text: String, _ colors: [Color]) -> some View {
        HStack(spacing: Space.sm) {
            Text("\(label) USAGE").font(HUD.label(9.5)).tracking(1).foregroundStyle(HUD.text3)
            Meter(value: value, colors: colors, height: 5).frame(width: 130)
            Text("\(Int(min(999, value * 100)))% · \(text)").font(HUD.label(10)).foregroundStyle(HUD.text).monospacedDigit()
        }
        .help("Share of your \(label == "7D" ? "weekly" : "5-hour") budget, at API rates. Change budgets in Settings.")
    }
}

// MARK: - Jarvis panel

struct JarvisPanel: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var jarvis = model.jarvis
        VStack(spacing: 0) {
            HStack(spacing: Space.md) {
                ZStack {
                    OrbView(weights: [3, 2, 2, 2, 1], energy: jarvis.busy || jarvis.listening ? 1 : 0.15)
                        .frame(width: 46, height: 46)
                        .clipShape(Circle())
                    Circle().strokeBorder(HUD.cyan.opacity(0.4)).frame(width: 46, height: 46)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("JARVIS").font(HUD.label(12)).tracking(3).foregroundStyle(HUD.text)
                    Text(jarvis.busy ? "Thinking…" : jarvis.listening ? "Listening…" : "Answers with \(model.ai.resolved.1) · \(model.ai.resolved.0 == .claude ? "cloud" : "offline, free")")
                        .font(HUD.mono(10)).foregroundStyle(HUD.text2)
                }
                Spacer()
                Button { jarvis.speaks.toggle() } label: { Image(systemName: jarvis.speaks ? "speaker.wave.2.fill" : "speaker.slash") }
                    .buttonStyle(.hud(HUD.text3)).help(jarvis.speaks ? "Mute voice" : "Speak replies")
                Button { withAnimation(HUD.spring) { model.jarvisOpen = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.hud(HUD.text3)).keyboardShortcut(.cancelAction)
            }
            .padding(Space.lg)
            Rectangle().fill(HUD.line).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.md) {
                        if jarvis.messages.isEmpty { suggestions }
                        ForEach(jarvis.messages) { m in bubble(m).id(m.id) }
                    }
                    .padding(Space.lg)
                }
                .onChange(of: jarvis.messages.last?.text) { _, _ in
                    if let id = jarvis.messages.last?.id { withAnimation(HUD.quick) { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }

            Rectangle().fill(HUD.line).frame(height: 1)
            HStack(spacing: Space.sm) {
                Button { jarvis.toggleListening() } label: {
                    Image(systemName: jarvis.listening ? "waveform" : "mic")
                        .symbolEffect(.variableColor.iterative, isActive: jarvis.listening)
                        .frame(width: 16)
                }
                .buttonStyle(.hud(jarvis.listening ? HUD.pink : HUD.text3, prominent: jarvis.listening))
                .help("Talk to Jarvis")
                TextField("Ask Jarvis anything…", text: $jarvis.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(HUD.text)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit { jarvis.send() }
                if jarvis.busy {
                    Button { jarvis.stop() } label: { Image(systemName: "stop.fill") }.buttonStyle(.hud(HUD.pink))
                } else {
                    Button { jarvis.send() } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.hud(HUD.cyan, prominent: true))
                        .disabled(jarvis.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(Space.md)
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.ultraThinMaterial))
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(HUD.bgRaised.opacity(0.88)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(LinearGradient(colors: [HUD.cyan.opacity(0.5), HUD.line], startPoint: .top, endPoint: .bottom)))
        .shadow(color: HUD.cyan.opacity(0.12), radius: 30)
        .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
        .onAppear { focused = true }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("TRY").font(HUD.label(9.5)).tracking(1.2).foregroundStyle(HUD.text3)
            ForEach(["Give me my briefing", "How much did I spend this week?", "Open EarHop", "Any broken connectors?",
                     "What did I decide about the Agent OS design?", "Which project should I clean up?"], id: \.self) { s in
                Button { model.jarvis.send(s) } label: {
                    HStack { Text(s).font(.system(size: 12)).foregroundStyle(HUD.text2); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 9)).foregroundStyle(HUD.text3) }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                .background(RoundedRectangle(cornerRadius: 8).fill(HUD.panel))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUD.line))
            }
        }
    }

    private func bubble(_ m: Jarvis.Message) -> some View {
        HStack(alignment: .top) {
            if m.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: Space.xs) {
                if m.text.isEmpty {
                    ThinkingDots()
                } else {
                    Text(LocalizedStringKey(m.text)).font(.system(size: 12.5)).foregroundStyle(HUD.text).textSelection(.enabled)
                }
                if m.role == .jarvis, !m.text.isEmpty {
                    Text(m.engine.map { e in m.cost.map { "\(e) · \(Format.money($0))" } ?? e } ?? (m.local ? "INSTANT · ON THIS MAC · ₹0" : "CLAUDE"))
                        .font(HUD.label(8.5)).tracking(1).foregroundStyle(HUD.text3)
                }
            }
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm + 2)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(m.role == .user ? HUD.apps.opacity(0.18) : HUD.panel))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(m.role == .user ? HUD.apps.opacity(0.35) : HUD.line))
            if m.role == .jarvis { Spacer(minLength: 24) }
        }
        .transition(.opacity.combined(with: .offset(y: 8)))
    }
}

struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation) { t in
            let phase = t.date.timeIntervalSinceReferenceDate * 3
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(HUD.cyan).frame(width: 6, height: 6)
                        .opacity(0.3 + 0.7 * max(0, sin(phase - Double(i) * 0.7)))
                }
            }
        }
        .frame(height: 16)
    }
}

// MARK: - Command palette (⌘K): zero-token search across everything

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    struct Hit: Identifiable {
        let id: String
        let kind: String
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        let run: () -> Void
    }

    private var hits: [Hit] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let s = model.snapshot
        var out: [Hit] = Page.allCases.map { p in
            Hit(id: "page-\(p.id)", kind: "Page", symbol: p.symbol, tint: p.tint, title: p.title, detail: "⌘\(String(p.key.character))") { model.go(p) }
        }
        out.append(Hit(id: "brief", kind: "Jarvis", symbol: "waveform.circle", tint: HUD.cyan, title: "Briefing", detail: "Spoken summary of today") {
            model.jarvis.briefing()
        })
        out += s.projects.map { p in
            Hit(id: "proj-\(p.id)", kind: "Project", symbol: "folder", tint: HUD.apps, title: p.name, detail: p.locations.first ?? "") {
                model.focusedProject = p.id; model.go(.projects)
            }
        }
        out += s.sessions.prefix(400).map { x in
            Hit(id: "ses-\(x.id)", kind: "Session", symbol: "text.bubble", tint: HUD.routines, title: x.title, detail: "\(ToolCatalog.name(x.tool)) · \(x.end.relative)") {
                model.resume(x)
            }
        }
        out += s.skills.map { k in
            Hit(id: "skill-\(k.id)", kind: "Skill", symbol: "bolt", tint: HUD.skills, title: k.name, detail: "\(ToolCatalog.name(k.tool)) · \(k.description)") {
                model.open(k.path + "/SKILL.md")
            }
        }
        out += s.notes.map { n in
            Hit(id: "note-\(n.id)", kind: "Note", symbol: "brain", tint: HUD.memory, title: n.title, detail: n.folder) { model.open(n.path) }
        }
        out += s.connectors.map { c in
            Hit(id: "mcp-\(c.id)", kind: "Connector", symbol: "point.3.connected.trianglepath.dotted", tint: HUD.high, title: c.name, detail: ToolCatalog.name(c.tool)) {
                model.go(.connectors)
            }
        }
        out += s.assets.map { a in
            Hit(id: "asset-\(a.id)", kind: a.kind, symbol: "photo", tint: HUD.pink, title: a.name, detail: a.path) { model.open(a.path) }
        }
        guard !q.isEmpty else { return Array(out.prefix(11)) }
        let words = q.split(separator: " ")
        let scored = out.compactMap { h -> (Hit, Int)? in
            let hay = "\(h.title) \(h.detail) \(h.kind)".lowercased()
            guard words.allSatisfy({ hay.contains($0) }) else { return nil }
            let title = h.title.lowercased()
            let score = (title.hasPrefix(q) ? 0 : title.contains(q) ? 1 : 2) * 10 + (h.kind == "Page" ? 0 : h.kind == "Project" ? 1 : 3)
            return (h, score)
        }
        return scored.sorted { $0.1 < $1.1 }.prefix(40).map(\.0)
    }

    var body: some View {
        let results = hits
        ZStack(alignment: .top) {
            Color.black.opacity(0.45).ignoresSafeArea()
                .onTapGesture { close() }
            VStack(spacing: 0) {
                HStack(spacing: Space.md) {
                    Image(systemName: "magnifyingglass").foregroundStyle(HUD.cyan)
                    TextField("Search projects, sessions, skills, notes, files…", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 17)).foregroundStyle(HUD.text)
                        .focused($focused)
                        .onSubmit { run(results) }
                        .onExitCommand { close() }
                        .onChange(of: query) { selected = 0 }
                    Text("0 TOKENS").font(HUD.label(9)).tracking(1).foregroundStyle(HUD.memory)
                }
                .padding(Space.lg)
                Rectangle().fill(HUD.line).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { i, h in
                                HStack(spacing: Space.md) {
                                    IconTile(symbol: h.symbol, tint: h.tint, size: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(h.title).font(.system(size: 13, weight: .medium)).foregroundStyle(HUD.text).lineLimit(1)
                                        Text(h.detail).font(HUD.mono(10)).foregroundStyle(HUD.text3).lineLimit(1)
                                    }
                                    Spacer()
                                    Text(h.kind.uppercased()).font(HUD.label(8.5)).tracking(1).foregroundStyle(HUD.text3)
                                }
                                .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
                                .background(RoundedRectangle(cornerRadius: 9).fill(i == selected ? h.tint.opacity(0.16) : .clear))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(i == selected ? h.tint.opacity(0.4) : .clear))
                                .contentShape(Rectangle())
                                .onTapGesture { selected = i; run(results) }
                                .id(i)
                            }
                            if results.isEmpty { EmptyHUD(symbol: "magnifyingglass", title: "Nothing found", message: "Try a project, skill, note or file name.") }
                        }
                        .padding(Space.sm)
                    }
                    .frame(maxHeight: 420)
                    .onChange(of: selected) { _, i in proxy.scrollTo(i) }
                }
            }
            .frame(width: 640)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(HUD.bgRaised.opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(HUD.lineHi))
            .shadow(color: .black.opacity(0.7), radius: 40, y: 20)
            .padding(.top, 110)
        }
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { selected = min(selected + 1, max(0, results.count - 1)); return .handled }
        .onKeyPress(.upArrow) { selected = max(selected - 1, 0); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onExitCommand { close() }
    }

    private func run(_ results: [Hit]) {
        guard results.indices.contains(selected) else { return }
        let hit = results[selected]
        close()
        hit.run()
    }

    private func close() { withAnimation(HUD.spring) { model.paletteOpen = false } }
}

/// Areas covered by floating panels (inspector, Jarvis, search), in window coordinates.
/// The Metal brain view sits underneath as an AppKit view, which would otherwise take clicks meant for these panels.
@MainActor
enum OverlayZones {
    static var rects: [String: CGRect] = [:]

    /// True when a point (window coordinates, origin top-left) falls inside a panel.
    static func covers(_ p: CGPoint) -> Bool { rects.values.contains { $0.contains(p) } }
}

extension View {
    /// Marks this view as a floating panel so the brain view underneath lets its clicks through.
    func overlayZone(_ id: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { OverlayZones.rects[id] = $0 }
            .onDisappear { OverlayZones.rects[id] = nil }
    }
}
