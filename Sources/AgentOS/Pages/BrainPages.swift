import AgentOSKit
import Charts
import QuickLookThumbnailing
import SwiftUI

// MARK: - Usage & cost

struct UsagePage: View {
    @Environment(AppModel.self) private var model

    private struct DayModel: Identifiable { let id = UUID(); let day: Date; let family: String; let cost: Double }

    var body: some View {
        let s = model.snapshot
        let month = Analytics.tokens(in: s.sessions, since: model.now.addingTimeInterval(-30 * 86_400))
        let all = s.sessions.reduce(Usage()) { $0 + $1.usage }
        let since = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: model.now))!
        let byDay: [DayModel] = {
            var map: [String: Double] = [:]
            for x in s.sessions where x.end >= since {
                let short = Pricing.shortName(x.model)
                // Charts traps on values outside the color scale, so every model maps to a known family.
                let fam = ["Opus", "Sonnet", "Haiku", "Fable", "Mythos"].first { short.hasPrefix($0) } ?? "Other"
                for p in x.points where p.date >= since && p.cost > 0 {
                    map["\(Calendar.current.startOfDay(for: p.date).timeIntervalSince1970)|\(fam)", default: 0] += p.cost
                }
            }
            return map.map { k, v in
                let parts = k.split(separator: "|")
                return DayModel(day: Date(timeIntervalSince1970: Double(parts[0])!), family: String(parts[1]), cost: v)
            }
        }()
        let projects = s.projects.filter { $0.usage.cost > 0 }.sorted { $0.usage.cost > $1.usage.cost }.prefix(8)
        let topCost = projects.first?.usage.cost ?? 1
        let cacheBase = Double(all.input + all.cacheRead + all.cacheWrite)
        let hitRate = cacheBase > 0 ? Double(all.cacheRead) / cacheBase : 0
        let light = s.sessions.filter { $0.tool == "claude-code" && $0.usage.output < 4_000 && $0.messages <= 3 }
        let lightCost = light.reduce(0) { $0 + $1.usage.cost }

        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                PageHeader(title: "Usage & cost", subtitle: "API-equivalent · your plan may bill differently", tint: HUD.routines)
                HStack(spacing: Space.lg) {
                    Panel { Metric(label: "Last 5 hours", value: Format.money(model.fiveHours.cost), tint: HUD.high, sub: "\(Format.tokens(model.fiveHours.tokens)) tokens").frame(maxWidth: .infinity, alignment: .leading) }
                    Panel { Metric(label: "Last 7 days", value: Format.money(model.week.cost), tint: HUD.skills, sub: "\(Format.tokens(model.week.tokens)) tokens").frame(maxWidth: .infinity, alignment: .leading) }
                    Panel { Metric(label: "Last 30 days", value: Format.money(month.cost), tint: HUD.routines, sub: "\(Format.tokens(month.tokens)) tokens").frame(maxWidth: .infinity, alignment: .leading) }
                    Panel { Metric(label: "Cache hit rate", value: "\(Int(hitRate * 100))%", tint: HUD.memory, sub: "\(Format.tokens(all.cacheRead)) read from cache").frame(maxWidth: .infinity, alignment: .leading) }
                }
                .appear(0)

                Panel(title: "Daily spend by model · 30 days", dot: HUD.routines) {
                    Chart(byDay) { d in
                        BarMark(x: .value("Day", d.day, unit: .day), y: .value("USD", d.cost))
                            .foregroundStyle(by: .value("Model", d.family))
                            .cornerRadius(2)
                    }
                    .chartForegroundStyleScale(["Opus": HUD.high, "Sonnet": HUD.apps, "Haiku": HUD.memory, "Fable": HUD.skills, "Mythos": HUD.pink, "Other": HUD.text3])
                    .chartLegend(position: .top, alignment: .trailing)
                    .chartYAxis { AxisMarks { v in AxisGridLine().foregroundStyle(HUD.line); AxisValueLabel { if let d = v.as(Double.self) { Text(Format.money(d)).foregroundStyle(HUD.text3) } } } }
                    .chartXAxis { AxisMarks(values: .stride(by: .day, count: 5)) { _ in AxisValueLabel(format: .dateTime.month().day()).foregroundStyle(HUD.text3) } }
                    .frame(height: 220)
                }
                .appear(1)

                HStack(alignment: .top, spacing: Space.lg) {
                    Panel(title: "Cost per project", dot: HUD.apps) {
                        VStack(spacing: Space.md) {
                            ForEach(Array(projects)) { p in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(p.name).font(.system(size: 12, weight: .medium)).foregroundStyle(HUD.text)
                                        Spacer()
                                        Text(Format.money(p.usage.cost)).font(HUD.mono(11)).foregroundStyle(HUD.text2)
                                    }
                                    Meter(value: p.usage.cost / topCost, colors: [HUD.apps, HUD.cyan], height: 4)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { model.focusedProject = p.id; model.go(.projects) }
                            }
                        }
                    }
                    VStack(spacing: Space.lg) {
                        Panel(title: "Where tokens go", dot: HUD.skills) {
                            tokenRow("Fresh input", all.input, HUD.apps)
                            tokenRow("Cache writes", all.cacheWrite, HUD.routines)
                            tokenRow("Cache reads", all.cacheRead, HUD.memory)
                            tokenRow("Output", all.output, HUD.skills)
                        }
                        Panel(title: "Local vs cloud router", dot: HUD.memory, trailing: s.ollamaRunning ? "ollama running" : "ollama stopped") {
                            Text("\(light.count) quick Claude sessions (≤3 prompts, short answers) cost \(Format.money(lightCost)). Jobs like these — summaries, tagging, renames — can run free on a local model.")
                                .font(.system(size: 11.5)).foregroundStyle(HUD.text2).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: Space.xs) {
                                ForEach(s.localModels, id: \.self) { Tag(text: $0, tint: HUD.memory, state: s.ollamaRunning ? HUD.on : HUD.off) }
                                if s.localModels.isEmpty { Text("No local models installed.").font(HUD.mono(10)).foregroundStyle(HUD.text3) }
                            }
                        }
                    }
                    .frame(width: 380)
                }
                .appear(2)
            }
            .padding(Space.xl)
        }
        .scrollIndicators(.never)
    }

    private func tokenRow(_ label: String, _ n: Int, _ c: Color) -> some View {
        let total = max(1, model.snapshot.sessions.reduce(0) { $0 + $1.usage.total })
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(HUD.mono(11)).foregroundStyle(HUD.text2)
                Spacer()
                Text(Format.tokens(n)).font(HUD.mono(11, .medium)).foregroundStyle(HUD.text)
            }
            Meter(value: Double(n) / Double(total), colors: [c.opacity(0.6), c], height: 4)
        }
    }
}

// MARK: - Memory: corrections → rules, session → notes, notes

struct MemoryPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage("memory.captured") private var capturedRaw = ""
    @State private var ruleDraft: RuleDraft?
    @State private var noteDraft: NoteDraft?
    @State private var capturing: String?

    static let noteSystemPrompt = "You write Basic Memory notes. Output Markdown only, no front matter, under 220 words: a one-line summary, then '## Decisions', '## What worked', '## Preferences learned' as bullet lists. Skip empty sections. Never include secrets."

    struct RuleDraft: Identifiable { let id: String; var text: String; var tools: Set<String> }
    struct NoteDraft: Identifiable { let id: String; var title: String; var body: String; var project: String }

    private var captured: Set<String> { Set(capturedRaw.split(separator: "\n").map(String.init)) }

    var body: some View {
        let s = model.snapshot
        let corrections = model.pendingCorrections
        let fillable = s.sessions.filter { $0.tool == "claude-code" && !captured.contains($0.id) && $0.messages >= 3 }.prefix(12)
        HStack(alignment: .top, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.lg) {
                PageHeader(title: "Memory", subtitle: "Teach every AI once", tint: HUD.memory)
                Panel(title: "Corrections inbox", dot: HUD.memory, trailing: "\(corrections.count) waiting") {
                    Text("Times you corrected an AI. Make one a rule and it's added to CLAUDE.md, AGENTS.md, GEMINI.md and the rest, so no app repeats the mistake.")
                        .font(.system(size: 11.5)).foregroundStyle(HUD.text2)
                    ScrollView {
                        LazyVStack(spacing: Space.sm) {
                            ForEach(corrections.prefix(80)) { c in
                                HoverRow {
                                    VStack(alignment: .leading, spacing: Space.sm) {
                                        Text("“\(c.text)”").font(.system(size: 12.5)).foregroundStyle(HUD.text).fixedSize(horizontal: false, vertical: true)
                                        HStack {
                                            Text("\(c.project) · \(c.date.relative)").font(HUD.mono(9.5)).foregroundStyle(HUD.text3)
                                            Spacer()
                                            Button("Dismiss") { withAnimation(HUD.spring) { _ = model.dismissedCorrections.insert(c.id) } }.buttonStyle(.hud(HUD.text3))
                                            Button("Make rule") {
                                                let targets = ToolCatalog.ruleTargets.filter { t in model.snapshot.tools.contains { $0.id == t.id } }.map(\.id)
                                                ruleDraft = RuleDraft(id: c.id, text: c.text, tools: Set(targets))
                                            }
                                            .buttonStyle(.hud(HUD.memory, prominent: true))
                                        }
                                    }
                                }
                            }
                            if corrections.isEmpty { EmptyHUD(symbol: "checkmark.seal", title: "Inbox zero", message: "No corrections waiting.") }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(spacing: Space.lg) {
                Panel(title: "Memory filler", dot: HUD.routines, trailing: "uses Haiku") {
                    Text("Turn a finished session into a Basic Memory note, so every AI app starts with your decisions.")
                        .font(.system(size: 11.5)).foregroundStyle(HUD.text2)
                    ScrollView {
                    VStack(spacing: Space.sm) {
                        ForEach(Array(fillable)) { x in
                            HoverRow {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(x.title).font(.system(size: 12, weight: .medium)).foregroundStyle(HUD.text).lineLimit(1)
                                        Text("\(TextRules.projectName(x.cwd)) · \(x.end.relative)").font(HUD.mono(9.5)).foregroundStyle(HUD.text3)
                                    }
                                    Spacer()
                                    if capturing == x.id {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Button("Capture") { capture(x) }.buttonStyle(.hud(HUD.routines)).disabled(capturing != nil)
                                    }
                                }
                            }
                        }
                    }
                    }
                    .scrollIndicators(.never)
                }
                .frame(maxHeight: .infinity)
                Panel(title: "Notes", dot: HUD.memory, trailing: "~/basic-memory · \(s.notes.count)") {
                    ScrollView {
                        VStack(spacing: Space.sm) {
                            ForEach(s.notes.prefix(40)) { n in
                                HoverRow {
                                    HStack {
                                        Image(systemName: "doc.text").foregroundStyle(HUD.memory)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(n.title).font(.system(size: 12, weight: .medium)).foregroundStyle(HUD.text).lineLimit(1)
                                            Text("\(n.folder) · \(n.words) words · \(n.modified.relative)").font(HUD.mono(9.5)).foregroundStyle(HUD.text3)
                                        }
                                        Spacer()
                                    }
                                }
                                .onTapGesture { model.open(n.path) }
                            }
                            if s.notes.isEmpty { Text("Your shared memory is empty. Capture a session to start it.").font(HUD.mono(10.5)).foregroundStyle(HUD.text3) }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
            .frame(width: 420)
        }
        .padding(Space.xl)
        .sheet(item: $ruleDraft) { draft in RuleSheet(draft: draft) { saved in if saved { withAnimation(HUD.spring) { _ = model.dismissedCorrections.insert(draft.id) } } } }
        .sheet(item: $noteDraft) { draft in NoteSheet(draft: draft) { saved in if saved { capturedRaw += "\n\(draft.id)" } } }
    }

    private func capture(_ session: Session) {
        capturing = session.id
        let project = TextRules.projectName(session.cwd)
        Task {
            let transcript = await Transcript.excerpt(session.file)
            let system = "You write Basic Memory notes. Output Markdown only, no front matter, under 220 words: a one-line summary, then '## Decisions', '## What worked', '## Preferences learned' as bullet lists. Skip empty sections. Never include secrets."
            do {
                let body = try await ClaudeCLI.run(prompt: "Session in project \(project):\n\n\(transcript)", model: "haiku", system: system)
                noteDraft = NoteDraft(id: session.id, title: "\(project) — \(session.title)", body: body, project: project)
            } catch {
                model.flash("Capture failed: \(error.localizedDescription)")
            }
            capturing = nil
        }
    }
}

/// Reads the human and assistant text from a Claude Code session log, capped for a cheap summary.
enum Transcript {
    @concurrent static func excerpt(_ path: String, limit: Int = 24_000) async -> String {
        guard let data = FileManager.default.contents(atPath: path) else { return "" }
        var out: [String] = []
        for line in data.split(separator: 0x0A) {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = o["type"] as? String, type == "user" || type == "assistant",
                  let msg = o["message"] as? [String: Any] else { continue }
            var text = msg["content"] as? String ?? ""
            if let arr = msg["content"] as? [[String: Any]] {
                text = arr.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
            }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.hasPrefix("<") else { continue }
            out.append("\(type == "user" ? "USER" : "AI"): \(text.prefix(1500))")
        }
        let joined = out.joined(separator: "\n\n")
        // Keep the start (the goal) and the end (the outcome).
        return joined.count <= limit ? joined : String(joined.prefix(limit / 3)) + "\n…\n" + String(joined.suffix(limit * 2 / 3))
    }
}

private struct RuleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: MemoryPage.RuleDraft
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text("NEW RULE").font(HUD.label(10)).tracking(2).foregroundStyle(HUD.memory)
            Text("Write it as an instruction every AI should follow.").font(.system(size: 12)).foregroundStyle(HUD.text2)
            TextField("Rule", text: $draft.text, axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(HUD.text).lineLimit(2...6)
                .padding(Space.md).background(RoundedRectangle(cornerRadius: 9).fill(HUD.panel)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(HUD.line))
            Text("ADD TO").font(HUD.label(9.5)).tracking(1.2).foregroundStyle(HUD.text3)
            ForEach(ToolCatalog.ruleTargets, id: \.id) { t in
                Toggle(isOn: Binding(get: { draft.tools.contains(t.id) }, set: { on in if on { draft.tools.insert(t.id) } else { draft.tools.remove(t.id) } })) {
                    HStack {
                        Text(t.name).font(.system(size: 12)).foregroundStyle(HUD.text)
                        Text("~/\(t.instructions ?? "")").font(HUD.mono(10)).foregroundStyle(HUD.text3)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { done(false); dismiss() }.buttonStyle(.hud(HUD.text3)).keyboardShortcut(.cancelAction)
                Button("Add rule to \(draft.tools.count) files") {
                    do {
                        let files = try Actions.addRule(draft.text, toTools: Array(draft.tools))
                        model.flash("Rule added to \(files.count) files")
                        done(true); dismiss()
                    } catch { model.flash(error.localizedDescription) }
                }
                .buttonStyle(.hud(HUD.memory, prominent: true)).keyboardShortcut(.defaultAction)
                .disabled(draft.text.trimmingCharacters(in: .whitespaces).isEmpty || draft.tools.isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 540)
        .background(HUD.bgRaised)
        .preferredColorScheme(.dark)
    }
}

private struct NoteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: MemoryPage.NoteDraft
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("NEW MEMORY NOTE").font(HUD.label(10)).tracking(2).foregroundStyle(HUD.routines)
            TextField("Title", text: $draft.title).textFieldStyle(.plain).font(.system(size: 15, weight: .semibold)).foregroundStyle(HUD.text)
            TextEditor(text: $draft.body)
                .font(HUD.mono(11.5)).foregroundStyle(HUD.text).scrollContentBackground(.hidden)
                .padding(Space.sm).background(RoundedRectangle(cornerRadius: 9).fill(HUD.panel)).overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(HUD.line))
                .frame(height: 300)
            Text("Saves to ~/basic-memory/sessions/").font(HUD.mono(10)).foregroundStyle(HUD.text3)
            HStack {
                Spacer()
                Button("Discard") { done(false); dismiss() }.buttonStyle(.hud(HUD.text3)).keyboardShortcut(.cancelAction)
                Button("Save note") {
                    do {
                        _ = try Actions.writeNote(title: draft.title, body: draft.body, folder: "sessions", tags: ["agent-os", TextRules.slug(draft.project)])
                        model.flash("Saved to Basic Memory")
                        done(true); dismiss()
                        Task { await model.refresh() }
                    } catch { model.flash(error.localizedDescription) }
                }
                .buttonStyle(.hud(HUD.routines, prominent: true))
            }
        }
        .padding(Space.xl)
        .frame(width: 620)
        .background(HUD.bgRaised)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Janitor

struct JanitorPage: View {
    @Environment(AppModel.self) private var model
    @State private var picked: Set<String> = []
    @State private var confirm = false

    var body: some View {
        let items = model.snapshot.clutter
        let total = items.reduce(Int64(0)) { $0 + $1.bytes }
        let chosen = items.filter { picked.contains($0.path) }
        VStack(alignment: .leading, spacing: Space.lg) {
            PageHeader(title: "Clutter janitor", subtitle: "\(Format.bytes(total)) you could free", tint: HUD.pink) {
                HStack(spacing: Space.sm) {
                    Button(picked.count == items.count ? "Select none" : "Select all") {
                        picked = picked.count == items.count ? [] : Set(items.map(\.path))
                    }
                    .buttonStyle(.hud(HUD.text3))
                    Button("Move \(chosen.count) to Trash · \(Format.bytes(chosen.reduce(0) { $0 + $1.bytes }))") { confirm = true }
                        .buttonStyle(.hud(HUD.pink, prominent: true)).disabled(chosen.isEmpty)
                }
            }
            ScrollView {
                LazyVStack(spacing: Space.sm) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, c in
                        HoverRow {
                            HStack(spacing: Space.md) {
                                Image(systemName: picked.contains(c.path) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(picked.contains(c.path) ? HUD.pink : HUD.text3).font(.system(size: 15))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(c.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(HUD.mono(11)).foregroundStyle(HUD.text).lineLimit(1).truncationMode(.middle)
                                    Text("\(c.reason) · modified \(c.modified.relative)").font(HUD.mono(9.5)).foregroundStyle(HUD.text3)
                                }
                                Spacer()
                                Text(Format.bytes(c.bytes)).font(HUD.mono(11, .medium)).foregroundStyle(HUD.text2)
                                Button("Reveal") { model.reveal(c.path) }.buttonStyle(.hud(HUD.text3))
                            }
                        }
                        .onTapGesture { if picked.contains(c.path) { picked.remove(c.path) } else { picked.insert(c.path) } }
                        .appear(i)
                    }
                    if items.isEmpty { EmptyHUD(symbol: "sparkles", title: "All clean", message: "No spare workspaces, stale worktrees or duplicate zips found.") }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(Space.xl)
        .alert("Move \(chosen.count) items to the Trash?", isPresented: $confirm) {
            Button("Move to Trash", role: .destructive) {
                var failed = 0
                for c in chosen { do { try Actions.trash(c.path) } catch { failed += 1 } }
                picked = []
                model.flash(failed == 0 ? "Moved to Trash. Empty the Trash to free the space." : "\(failed) items could not be moved")
                Task { await model.refresh() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They go to the Trash, so you can put them back until you empty it.")
        }
    }
}

// MARK: - Asset shelf

struct ShelfPage: View {
    @Environment(AppModel.self) private var model
    @State private var kind = "All"

    var body: some View {
        let assets = model.snapshot.assets
        let kinds = ["All"] + Array(Set(assets.map(\.kind))).sorted()
        let shown = assets.filter { kind == "All" || $0.kind == kind }
        VStack(alignment: .leading, spacing: Space.lg) {
            PageHeader(title: "Asset shelf", subtitle: "Design files & media from the last 45 days", tint: HUD.apps) {
                Picker("Kind", selection: $kind) { ForEach(kinds, id: \.self) { Text($0).tag($0) } }.labelsHidden().frame(width: 160)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: Space.lg)], spacing: Space.lg) {
                    ForEach(shown) { a in AssetCard(asset: a) }
                }
                if shown.isEmpty { EmptyHUD(symbol: "photo.stack", title: "Nothing recent", message: "Images, videos and design files you touch show up here.") }
            }
            .scrollIndicators(.never)
        }
        .padding(Space.xl)
    }
}

private struct AssetCard: View {
    @Environment(AppModel.self) private var model
    let asset: DesignAsset
    @State private var image: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(HUD.panelHi)
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                } else {
                    Image(systemName: "photo").foregroundStyle(HUD.text3)
                }
            }
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(hover ? HUD.apps.opacity(0.7) : HUD.line))
            .scaleEffect(hover ? 1.02 : 1)
            Text(asset.name).font(.system(size: 11.5, weight: .medium)).foregroundStyle(HUD.text).lineLimit(1)
            Text("\(asset.kind) · \(Format.bytes(asset.bytes)) · \(asset.modified.relative)").font(HUD.mono(9)).foregroundStyle(HUD.text3).lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(HUD.quick) { hover = h } }
        .onTapGesture { model.open(asset.path) }
        .contextMenu {
            Button("Open") { model.open(asset.path) }
            Button("Reveal in Finder") { model.reveal(asset.path) }
            Button("Copy Path") { model.copy(asset.path) }
        }
        .task(id: asset.path) {
            let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: asset.path), size: CGSize(width: 340, height: 240),
                                                   scale: 2, representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                withAnimation(HUD.quick) { image = rep.nsImage }
            }
        }
    }
}

// MARK: - System

struct SystemPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let sys = model.system
        let s = model.snapshot
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                PageHeader(title: "System", subtitle: "\(sys.chip) · \(sys.cores) cores · \(Int(sys.memoryTotal)) GB", tint: HUD.cyan)
                HStack(alignment: .top, spacing: Space.lg) {
                    Panel(title: "CPU", dot: HUD.cyan, trailing: "\(Int(sys.cpu * 100))%") {
                        Chart(Array(sys.cpuHistory.enumerated()), id: \.offset) { i, v in
                            AreaMark(x: .value("t", i), y: .value("cpu", v))
                                .foregroundStyle(LinearGradient(colors: [HUD.cyan.opacity(0.5), HUD.cyan.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                                .interpolationMethod(.catmullRom)
                            LineMark(x: .value("t", i), y: .value("cpu", v)).foregroundStyle(HUD.cyan).interpolationMethod(.catmullRom)
                        }
                        .chartYScale(domain: 0...1).chartXAxis(.hidden).chartYAxis(.hidden)
                        .frame(height: 110)
                    }
                    VStack(spacing: Space.lg) {
                        Panel(title: "Memory", dot: HUD.high, trailing: String(format: "%.1f / %.0f GB", sys.memoryUsed, sys.memoryTotal)) {
                            Meter(value: sys.memoryUsed / max(1, sys.memoryTotal), colors: [HUD.high, HUD.pink], height: 6)
                        }
                        Panel(title: "Disk", dot: HUD.apps, trailing: "\(Format.bytes(sys.diskFree)) free") {
                            Meter(value: 1 - Double(sys.diskFree) / Double(max(1, sys.diskTotal)), colors: [HUD.apps, HUD.cyan], height: 6)
                        }
                        Panel(title: "Thermal", dot: thermalColor, trailing: thermalText) {
                            Text("\(sys.launchAgents) background launch agents in ~/Library/LaunchAgents").font(HUD.mono(10.5)).foregroundStyle(HUD.text2)
                        }
                    }
                    .frame(width: 360)
                }
                .appear(0)
                HStack(alignment: .top, spacing: Space.lg) {
                    Panel(title: "AI processes", dot: HUD.skills, trailing: "live") {
                        VStack(spacing: 6) {
                            ForEach(sys.processes) { p in
                                HStack {
                                    Text(p.name).font(HUD.mono(11)).foregroundStyle(HUD.text).lineLimit(1)
                                    Spacer()
                                    Text(String(format: "%.1f%%", p.cpu)).font(HUD.mono(10.5)).foregroundStyle(HUD.text2).frame(width: 60, alignment: .trailing)
                                    Text(String(format: "%.0f MB", p.memMB)).font(HUD.mono(10.5)).foregroundStyle(HUD.text2).frame(width: 80, alignment: .trailing)
                                }
                            }
                            if sys.processes.isEmpty { Text("No AI processes running.").font(HUD.mono(10.5)).foregroundStyle(HUD.text3) }
                        }
                    }
                    Panel(title: "Offline AI", dot: HUD.memory, trailing: "Jarvis's brain") {
                        AIModelsView()
                    }
                    .frame(maxWidth: .infinity)
                    Panel(title: "Tuned for this Mac", dot: HUD.memory) {
                        bullet("Orb renders on the GPU with Metal: 60 Hz at rest, \(NSScreen.main?.maximumFramesPerSecond ?? 120) Hz while Jarvis works, off when hidden")
                        bullet("Session logs parse in parallel on all \(sys.cores) cores")
                        bullet("Unchanged logs come from a cache, so rescans take milliseconds")
                        bullet("\(s.sessions.count) sessions · \(s.skills.count) skills indexed for ⌘K, zero tokens")
                        bullet(s.ollamaRunning ? "Ollama is running for free local answers" : "Start Ollama to answer simple jobs locally")
                    }
                    .frame(width: 360)
                }
                .appear(1)
            }
            .padding(Space.xl)
        }
        .scrollIndicators(.never)
    }

    private func bullet(_ t: String) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Circle().fill(HUD.memory).frame(width: 5, height: 5).padding(.top, 5)
            Text(t).font(.system(size: 11.5)).foregroundStyle(HUD.text2).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var thermalText: String {
        switch model.system.thermal {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    private var thermalColor: Color {
        switch model.system.thermal {
        case .nominal: HUD.on
        case .fair: HUD.warn
        default: HUD.pink
        }
    }
}
