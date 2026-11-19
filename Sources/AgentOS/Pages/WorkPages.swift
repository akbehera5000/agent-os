import AgentOSKit
import Charts
import SwiftUI

// MARK: - Projects: one passport per project, every copy and every tool

struct ProjectsPage: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""

    var body: some View {
        let projects = model.snapshot.projects.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        let selected = model.snapshot.projects.first { $0.id == model.focusedProject } ?? projects.first
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.md) {
                PageHeader(title: "Projects", subtitle: "\(model.snapshot.projects.count) passports", tint: HUD.apps)
                SearchField(text: $query, prompt: "Filter projects")
                ScrollView {
                    LazyVStack(spacing: Space.sm) {
                        ForEach(Array(projects.enumerated()), id: \.element.id) { i, p in
                            ProjectRow(project: p, selected: p.id == selected?.id)
                                .onTapGesture { withAnimation(HUD.spring) { model.focusedProject = p.id } }
                                .appear(i)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .frame(width: 330)

            if let selected {
                Passport(project: selected).id(selected.id).transition(.opacity)
            } else {
                EmptyHUD(symbol: "folder", title: "No projects yet", message: "Projects appear when you use an AI tool inside a folder.")
            }
        }
        .padding(Space.xl)
    }
}

private struct ProjectRow: View {
    let project: Project
    let selected: Bool

    var body: some View {
        HStack(spacing: Space.md) {
            IconTile(symbol: project.locations.count > 1 ? "square.on.square" : "folder", tint: selected ? HUD.apps : HUD.text3, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(HUD.text).lineLimit(1)
                Text("\(project.sessions) sess · \(project.tools.count) tools · \(project.lastActive.relative)").font(HUD.mono(9.5)).foregroundStyle(HUD.text3)
            }
            Spacer(minLength: 0)
            Text(Format.money(project.usage.cost)).font(HUD.mono(10.5)).foregroundStyle(HUD.text2)
        }
        .padding(Space.md)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? HUD.apps.opacity(0.12) : HUD.panel.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? HUD.apps.opacity(0.6) : HUD.line))
        .contentShape(Rectangle())
    }
}

private struct Passport: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let sessions = model.sessions(of: project)
        let days = Analytics.daily(sessions, days: 30)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("PROJECT PASSPORT").font(HUD.label(10)).tracking(2).foregroundStyle(HUD.apps)
                        Text(project.name).font(.system(size: 32, weight: .semibold)).foregroundStyle(HUD.text)
                        HStack(spacing: Space.xs) {
                            ForEach(project.tools, id: \.self) { t in Tag(text: ToolCatalog.name(t), tint: HUD.hue(ToolCatalog.spec(t)?.hue ?? 0.5)) }
                        }
                    }
                    Spacer()
                    if let loc = project.locations.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                        Button { model.open(loc) } label: { Label("Open folder", systemImage: "folder") }.buttonStyle(.hud(HUD.apps))
                        Button { model.jarvis.send("Summarize where I left off on \(project.name) and what to do next. Look at its recent files if useful."); withAnimation(HUD.spring) { model.jarvisOpen = true } } label: {
                            Label("Ask Jarvis", systemImage: "waveform")
                        }
                        .buttonStyle(.hud(HUD.cyan, prominent: true))
                    }
                }
                .appear(0)

                Panel {
                    HStack(spacing: Space.section) {
                        Metric(label: "Sessions", value: "\(project.sessions)")
                        Metric(label: "API cost", value: Format.money(project.usage.cost), tint: HUD.routines)
                        Metric(label: "Tokens", value: Format.tokens(project.usage.total))
                        Metric(label: "Copies", value: "\(project.locations.count)", tint: project.locations.count > 1 ? HUD.pink : HUD.text)
                        Metric(label: "Last active", value: project.lastActive.relative)
                    }
                }
                .appear(1)

                Panel(title: "Spend · 30 days", dot: HUD.routines) {
                    Chart(days, id: \.day) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("USD", d.cost))
                            .foregroundStyle(LinearGradient(colors: [HUD.skills, HUD.routines], startPoint: .bottom, endPoint: .top))
                            .cornerRadius(2)
                    }
                    .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(HUD.line); AxisValueLabel { if let d = v.as(Double.self) { Text(Format.money(d)).foregroundStyle(HUD.text3) } } } }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in AxisValueLabel(format: .dateTime.month().day()).foregroundStyle(HUD.text3) } }
                    .frame(height: 140)
                }
                .appear(2)

                Panel(title: "Locations", dot: HUD.apps, trailing: project.locations.count > 1 ? "duplicates found" : nil) {
                    VStack(spacing: Space.sm) {
                        ForEach(project.locations, id: \.self) { loc in
                            let exists = FileManager.default.fileExists(atPath: loc)
                            HoverRow {
                                HStack {
                                    Circle().strokeBorder(exists ? HUD.on : HUD.off, lineWidth: 1.5).frame(width: 9, height: 9)
                                    Text(loc.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(HUD.mono(11)).foregroundStyle(exists ? HUD.text : HUD.text3).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if exists {
                                        Button("Reveal") { model.reveal(loc) }.buttonStyle(.hud(HUD.text3))
                                    } else {
                                        Text("MISSING").font(HUD.label(9)).foregroundStyle(HUD.text3)
                                    }
                                    Button("Copy") { model.copy(loc) }.buttonStyle(.hud(HUD.text3))
                                }
                            }
                        }
                    }
                }
                .appear(3)

                Panel(title: "Sessions", dot: HUD.routines, trailing: "\(sessions.count)") {
                    VStack(spacing: Space.sm) {
                        ForEach(sessions.prefix(30)) { s in SessionRow(session: s) }
                    }
                }
                .appear(4)
            }
            .padding(.bottom, Space.xl)
        }
        .scrollIndicators(.never)
    }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: Session
    var showProject = false

    var body: some View {
        HoverRow {
            HStack(spacing: Space.md) {
                IconTile(symbol: ToolCatalog.spec(session.tool)?.symbol ?? "terminal", tint: HUD.hue(ToolCatalog.spec(session.tool)?.hue ?? 0.1), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(HUD.text).lineLimit(1)
                    Text(([showProject ? TextRules.projectName(session.cwd) : nil,
                           Pricing.shortName(session.model), "\(session.messages) prompts", session.branch.map { "⎇ \($0)" },
                           session.end.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }).joined(separator: " · "))
                        .font(HUD.mono(9.5)).foregroundStyle(HUD.text3).lineLimit(1)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(session.usage.cost > 0 ? Format.money(session.usage.cost) : "plan").font(HUD.mono(11, .medium)).foregroundStyle(HUD.text)
                    Text("\(Format.tokens(session.usage.total)) tok").font(HUD.mono(9)).foregroundStyle(HUD.text3)
                }
                Button { model.resume(session) } label: { Image(systemName: "play.fill") }.buttonStyle(.hud(HUD.memory)).help("Resume in Terminal")
            }
        }
        .contextMenu {
            Button("Resume in Terminal") { model.resume(session) }
            Button("Reveal Log File") { model.reveal(session.file) }
            Button("Copy Session ID") { model.copy(session.id) }
        }
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(HUD.text3)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(HUD.text)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(HUD.text3) }.buttonStyle(.plain) }
        }
        .padding(.horizontal, Space.md).padding(.vertical, Space.sm)
        .background(RoundedRectangle(cornerRadius: 9).fill(HUD.panel))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(HUD.line))
    }
}

// MARK: - Timeline

struct TimelinePage: View {
    @Environment(AppModel.self) private var model
    @State private var tool = "all"
    @State private var query = ""

    var body: some View {
        let sessions = model.snapshot.sessions.filter {
            (tool == "all" || $0.tool == tool) && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.cwd.localizedCaseInsensitiveContains(query))
        }
        let days = Dictionary(grouping: sessions.prefix(500)) { Calendar.current.startOfDay(for: $0.end) }.sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: Space.lg) {
            PageHeader(title: "Timeline", subtitle: "\(sessions.count) sessions across your AI tools", tint: HUD.routines) {
                HStack(spacing: Space.sm) {
                    SearchField(text: $query, prompt: "Filter").frame(width: 220)
                    Picker("Tool", selection: $tool) {
                        Text("All tools").tag("all")
                        ForEach(Array(Set(model.snapshot.sessions.map(\.tool))).sorted(), id: \.self) { Text(ToolCatalog.name($0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 150)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.lg, pinnedViews: .sectionHeaders) {
                    ForEach(Array(days.enumerated()), id: \.element.key) { i, day in
                        Section {
                            VStack(spacing: Space.sm) {
                                ForEach(day.value) { s in SessionRow(session: s, showProject: true) }
                            }
                            .padding(.leading, Space.lg)
                            .overlay(alignment: .leading) { Rectangle().fill(LinearGradient(colors: [HUD.routines.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom)).frame(width: 1) }
                        } header: {
                            HStack {
                                Text(dayTitle(day.key).uppercased()).font(HUD.label(10.5)).tracking(1.6).foregroundStyle(HUD.routines)
                                Spacer()
                                Text("\(day.value.count) sessions · \(Format.money(day.value.reduce(0) { $0 + $1.usage.cost }))").font(HUD.label(9.5)).foregroundStyle(HUD.text3)
                            }
                            .padding(.vertical, Space.sm)
                            .background(HUD.bg.opacity(0.92))
                        }
                        .appear(i)
                    }
                    if sessions.isEmpty { EmptyHUD(symbol: "clock", title: "No sessions", message: "Nothing matches this filter.") }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(Space.xl)
    }

    private func dayTitle(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Today" }
        if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }
}

// MARK: - Skills: sync matrix across every AI app

struct SkillsPage: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var gapsOnly = false
    @State private var pending: (skill: Skill, tool: String)?

    private let columns = ToolCatalog.skillTargets

    var body: some View {
        let user = model.snapshot.skills.filter { $0.source == "user" }
        let byName = Dictionary(grouping: user, by: \.name)
        let names = byName.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }.filter { name in
            (query.isEmpty || name.localizedCaseInsensitiveContains(query)) && (!gapsOnly || Set(byName[name]!.map(\.tool)).count < columns.count)
        }
        let plugins = Dictionary(grouping: model.snapshot.skills.filter { $0.source != "user" }, by: \.source).sorted { $0.value.count > $1.value.count }

        VStack(alignment: .leading, spacing: Space.lg) {
            PageHeader(title: "Skill sync matrix", subtitle: "\(byName.count) skills · \(plugins.count) plugins", tint: HUD.skills) {
                HStack(spacing: Space.sm) {
                    SearchField(text: $query, prompt: "Filter skills").frame(width: 220)
                    Toggle("Gaps only", isOn: $gapsOnly).toggleStyle(.switch).controlSize(.small).font(HUD.mono(11))
                }
            }
            Panel(padding: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        Text("SKILL").font(HUD.label(9.5)).tracking(1).foregroundStyle(HUD.text3).frame(maxWidth: .infinity, alignment: .leading)
                        ForEach(columns, id: \.id) { c in
                            Text(c.name.uppercased()).font(HUD.label(8.5)).tracking(0.6).foregroundStyle(HUD.text2)
                                .frame(width: 88).multilineTextAlignment(.center).lineLimit(2)
                        }
                    }
                    .padding(.horizontal, Space.lg).padding(.vertical, Space.md)
                    Rectangle().fill(HUD.line).frame(height: 1)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(names, id: \.self) { name in
                                let have = byName[name] ?? []
                                MatrixRow(name: name, description: have.first?.description ?? "", have: have, columns: columns) { tool in
                                    if let source = have.first { pending = (source, tool) }
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            if !plugins.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.sm) {
                        Text("CLAUDE PLUGINS").font(HUD.label(9.5)).tracking(1).foregroundStyle(HUD.text3)
                        ForEach(plugins, id: \.key) { p in Tag(text: "\(p.key) · \(p.value.count)", tint: HUD.skills) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(Space.xl)
        .alert("Install skill?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Install") {
                guard let p = pending else { return }
                do {
                    let path = try Actions.installSkill(from: p.skill.path, name: p.skill.name, toTool: p.tool)
                    model.flash("Installed \(p.skill.name) → \(ToolCatalog.name(p.tool))")
                    _ = path
                    Task { await model.refresh() }
                } catch { model.flash(error.localizedDescription) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let p = pending {
                Text("Copy “\(p.skill.name)” from \(ToolCatalog.name(p.skill.tool)) into \(ToolCatalog.name(p.tool))’s skills folder (~/\(ToolCatalog.spec(p.tool)?.skillDirs.first ?? "")).")
            }
        }
    }
}

private struct MatrixRow: View {
    let name: String
    let description: String
    let have: [Skill]
    let columns: [ToolSpec]
    let install: (String) -> Void
    @State private var hover = false

    var body: some View {
        let tools = Set(have.map(\.tool))
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(HUD.mono(11.5, .medium)).foregroundStyle(HUD.text).lineLimit(1)
                Text(description).font(.system(size: 10)).foregroundStyle(HUD.text3).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(columns, id: \.id) { c in
                Group {
                    if tools.contains(c.id) {
                        Circle().fill(HUD.skills.opacity(0.25)).overlay(Circle().strokeBorder(HUD.on, lineWidth: 1.5))
                            .frame(width: 13, height: 13)
                            .help("Installed in \(c.name)")
                    } else {
                        Button { install(c.id) } label: {
                            Image(systemName: "plus").font(.system(size: 8, weight: .bold)).foregroundStyle(hover ? HUD.text : HUD.text3)
                                .frame(width: 15, height: 15)
                                .overlay(Circle().strokeBorder(HUD.off.opacity(hover ? 1 : 0.5), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("Install into \(c.name)")
                    }
                }
                .frame(width: 88)
            }
        }
        .padding(.horizontal, Space.lg).padding(.vertical, Space.sm)
        .background(hover ? HUD.panelHi : .clear)
        .onHover { hover = $0 }
    }
}

// MARK: - Connectors: MCP health across apps

struct ConnectorsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let groups = Dictionary(grouping: model.snapshot.connectors, by: \.name).sorted { $0.key < $1.key }
        let broken = model.snapshot.connectors.filter { $0.health == .missing }
        VStack(alignment: .leading, spacing: Space.lg) {
            PageHeader(title: "Connectors", subtitle: "\(groups.count) MCP servers · \(broken.count) broken", tint: HUD.high)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 360), spacing: Space.lg)], spacing: Space.lg) {
                    ForEach(Array(groups.enumerated()), id: \.element.key) { i, g in
                        let ok = g.value.allSatisfy { $0.health != .missing }
                        Panel(title: g.key, dot: ok ? HUD.memory : HUD.pink, trailing: "\(g.value.count) apps") {
                            Text(g.value.first?.command ?? "").font(HUD.mono(10.5)).foregroundStyle(HUD.text2).lineLimit(1).truncationMode(.middle)
                            FlowTags(items: g.value)
                            if !ok {
                                Text("The command can't be found on this Mac. Reinstall the server or fix the path in the config file.")
                                    .font(.system(size: 11)).foregroundStyle(HUD.text2)
                            }
                        }
                        .appear(i)
                    }
                }
                if groups.isEmpty { EmptyHUD(symbol: "point.3.connected.trianglepath.dotted", title: "No connectors", message: "No MCP servers are configured in your AI apps.") }
            }
            .scrollIndicators(.never)
            Text("Connectors added on claude.ai (Gmail, Figma, Notion…) live in your account, not on this Mac, so they aren't listed.")
                .font(HUD.mono(10)).foregroundStyle(HUD.text3)
        }
        .padding(Space.xl)
    }
}

private struct FlowTags: View {
    @Environment(AppModel.self) private var model
    let items: [Connector]

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(items) { c in
                Button { model.reveal(c.configFile) } label: {
                    Tag(text: ToolCatalog.name(c.tool), tint: HUD.high, state: c.health == .missing ? HUD.off : HUD.on.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help("\(c.health == .missing ? "Broken" : c.health == .remote ? "Remote" : "OK") · \(c.configFile)")
            }
        }
    }
}
