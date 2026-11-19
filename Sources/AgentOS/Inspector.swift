import AgentOSKit
import QuickLookThumbnailing
import SwiftUI

/// The right-hand drawer: shows whatever you clicked — a file to read and edit, a session to resume,
/// a project, a tool — plus its linked nodes, so you can walk the brain from node to node.
struct InspectorPanel: View {
    @Environment(AppModel.self) private var model
    let target: InspectTarget

    private var tint: Color { Color(nsColor: BrainRenderer.nsColor(target.kind)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(HUD.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    content
                    related
                }
                .padding(Space.lg)
            }
            .scrollIndicators(.never)
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(HUD.bgRaised.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(LinearGradient(colors: [tint.opacity(0.6), HUD.line], startPoint: .top, endPoint: .bottom)))
        .overlay(HUDCorners(color: tint).padding(4))
        .shadow(color: tint.opacity(0.15), radius: 30)
        .shadow(color: .black.opacity(0.6), radius: 30, y: 10)
        .id(target.path ?? target.title)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Space.sm) {
                    Circle().fill(tint).frame(width: 8, height: 8).shadow(color: tint, radius: 5)
                    Text(target.title).font(HUD.mono(13, .semibold)).foregroundStyle(HUD.text).lineLimit(2)
                }
                if let path = target.path {
                    Text(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(HUD.mono(9.5)).foregroundStyle(HUD.text3)
                        .lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: Space.xs) {
                    Tag(text: target.kind.rawValue, tint: tint)
                    if !target.detail.isEmpty { Text(target.detail).font(HUD.mono(9.5)).foregroundStyle(HUD.text2).lineLimit(1) }
                }
            }
            Spacer(minLength: 0)
            if let path = target.path {
                Button { model.copy(path) } label: { Image(systemName: "doc.on.doc") }.buttonStyle(.hud(HUD.text3)).help("Copy path")
                Button { model.reveal(path) } label: { Image(systemName: "folder") }.buttonStyle(.hud(HUD.text3)).help("Reveal in Finder")
            }
            Button { model.closeInspector() } label: { Image(systemName: "xmark") }.buttonStyle(.hud(HUD.text3)).keyboardShortcut(.cancelAction).help("Close (Esc)")
        }
        .padding(Space.lg)
    }

    @ViewBuilder private var content: some View {
        let s = model.snapshot
        switch target.kind {
        case .core:
            Text(model.briefing).font(.system(size: 13)).foregroundStyle(HUD.text).fixedSize(horizontal: false, vertical: true)
            Button { model.jarvis.briefing() } label: { Label("Speak briefing", systemImage: "waveform") }.buttonStyle(.hud(HUD.cyan, prominent: true))
        case .tool:
            if let t = s.tools.first(where: { $0.name == target.title }) {
                Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: Space.md) {
                    GridRow { Metric(label: "Sessions", value: "\(t.sessionCount)"); Metric(label: "Spend", value: Format.money(t.costUSD), tint: HUD.routines) }
                    GridRow { Metric(label: "Skills", value: "\(t.skillCount)", tint: HUD.skills); Metric(label: "Connectors", value: "\(t.connectorCount)", tint: HUD.high) }
                }
                HStack {
                    if let app = t.appPath { Button("Open \(t.name)") { model.open(app) }.buttonStyle(.hud(HUD.apps, prominent: true)) }
                    if let rules = ToolCatalog.spec(t.id)?.instructions {
                        Button("Edit rules") { model.inspect(path: NSHomeDirectory() + "/" + rules, kind: .doc) }.buttonStyle(.hud(HUD.memory))
                    }
                }
            }
        case .project:
            if let p = s.projects.first(where: { $0.name == target.title }) {
                Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: Space.md) {
                    GridRow { Metric(label: "Sessions", value: "\(p.sessions)"); Metric(label: "Spend", value: Format.money(p.usage.cost), tint: HUD.routines) }
                    GridRow { Metric(label: "Copies", value: "\(p.locations.count)"); Metric(label: "Last active", value: p.lastActive.relative) }
                }
                HStack {
                    Button("Open passport") { model.focusedProject = p.id; model.go(.projects); model.closeInspector() }.buttonStyle(.hud(HUD.apps, prominent: true))
                    if let loc = p.locations.first { Button("Open folder") { model.open(loc) }.buttonStyle(.hud(HUD.text3)) }
                }
            }
        case .session:
            if let x = s.sessions.first(where: { $0.file == target.path }) { SessionDetail(session: x) }
        default:
            if let path = target.path { FileBody(path: path) }
        }
    }

    /// Linked nodes: the parent and children of this node in the brain graph.
    @ViewBuilder private var related: some View {
        if let i = target.nodeIndex, model.graph.nodes.indices.contains(i) {
            let g = model.graph
            let parent = g.nodes[i].parent
            let children = g.edges.filter { $0.0 == i }.map(\.1)
            if parent != nil || !children.isEmpty {
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text("LINKED · \(children.count + (parent == nil ? 0 : 1))").font(HUD.label(9.5)).tracking(1.4).foregroundStyle(HUD.text3)
                    ForEach(([parent].compactMap { $0 } + children).prefix(40), id: \.self) { j in
                        let n = g.nodes[j]
                        Button { model.select(node: j) } label: {
                            HStack(spacing: Space.sm) {
                                Circle().fill(Color(nsColor: BrainRenderer.nsColor(n.kind))).frame(width: 6, height: 6)
                                Text(n.label).font(HUD.mono(11)).foregroundStyle(HUD.text).lineLimit(1)
                                Spacer()
                                Text(j == parent ? "PARENT" : n.kind.rawValue.uppercased()).font(HUD.label(8.5)).foregroundStyle(HUD.text3)
                            }
                            .padding(.horizontal, Space.sm).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7).fill(HUD.panel))
                            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(HUD.line))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// A text file you can read, edit and save; images and other files get a preview and Open.
private struct FileBody: View {
    @Environment(AppModel.self) private var model
    let path: String
    @State private var text = ""
    @State private var original = ""
    @State private var loaded = false
    @State private var thumb: NSImage?

    static let textTypes: Set<String> = ["md", "markdown", "txt", "json", "yaml", "yml", "toml", "swift", "sh", "py", "js", "ts", "html", "css", "plist", "csv", "command", "log"]

    private var isText: Bool { Self.textTypes.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
    private var attrs: [FileAttributeKey: Any] { (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:] }

    var body: some View {
        let size = (attrs[.size] as? Int) ?? 0
        let modified = attrs[.modificationDate] as? Date
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("\(Format.tokens(size / 4)) TOK · \(Format.bytes(Int64(size)))").font(HUD.label(9.5)).foregroundStyle(HUD.text3)
                Spacer()
                if let modified { Text("UPDATED \(modified.relative.uppercased())").font(HUD.label(9.5)).foregroundStyle(HUD.text3) }
            }
            if isText && size < 600_000 {
                TextEditor(text: $text)
                    .font(HUD.mono(11.5)).foregroundStyle(HUD.text).scrollContentBackground(.hidden)
                    .padding(Space.sm)
                    .frame(minHeight: 380)
                    .background(RoundedRectangle(cornerRadius: 9).fill(HUD.bg.opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(text != original ? HUD.warn.opacity(0.7) : HUD.line))
                HStack {
                    if text != original {
                        Text("UNSAVED CHANGES").font(HUD.label(9)).foregroundStyle(HUD.warn)
                        Spacer()
                        Button("Revert") { text = original }.buttonStyle(.hud(HUD.text3))
                        Button("Save") { save() }.buttonStyle(.hud(HUD.memory, prominent: true)).keyboardShortcut("s")
                    } else {
                        Spacer()
                        Button("Open in editor") { model.open(path) }.buttonStyle(.hud(HUD.text3))
                    }
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(HUD.panel)
                    if let thumb { Image(nsImage: thumb).resizable().scaledToFit().padding(Space.sm) } else { Image(systemName: "doc").font(.largeTitle).foregroundStyle(HUD.text3) }
                }
                .frame(height: 280)
                Button("Open") { model.open(path) }.buttonStyle(.hud(HUD.apps, prominent: true))
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        if isText, let s = try? String(contentsOfFile: path, encoding: .utf8) {
            text = s; original = s
        } else {
            let req = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 600, height: 500), scale: 2, representationTypes: .all)
            thumb = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
        }
        loaded = true
    }

    private func save() {
        do {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            original = text
            model.flash("Saved \(URL(fileURLWithPath: path).lastPathComponent)")
        } catch {
            model.flash("Could not save: \(error.localizedDescription)")
        }
    }
}

/// A session: numbers, actions, and the start of the conversation.
private struct SessionDetail: View {
    @Environment(AppModel.self) private var model
    let session: Session
    @State private var excerpt = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Grid(alignment: .leading, horizontalSpacing: Space.xl, verticalSpacing: Space.md) {
                GridRow { Metric(label: "Spend", value: session.usage.cost > 0 ? Format.money(session.usage.cost) : "Plan", tint: HUD.routines)
                          Metric(label: "Tokens", value: Format.tokens(session.usage.total)) }
                GridRow { Metric(label: "Model", value: Pricing.shortName(session.model)); Metric(label: "Prompts", value: "\(session.messages)") }
            }
            Text("\(TextRules.projectName(session.cwd)) · \(session.start.formatted(date: .abbreviated, time: .shortened)) → \(session.end.formatted(date: .omitted, time: .shortened)) IST")
                .font(HUD.mono(10)).foregroundStyle(HUD.text2)
            if !session.skillUse.isEmpty {
                HStack(spacing: Space.xs) { ForEach(session.skillUse.keys.sorted(), id: \.self) { Tag(text: $0, tint: HUD.skills) } }
            }
            HStack {
                Button { model.resume(session) } label: { Label("Resume", systemImage: "play.fill") }.buttonStyle(.hud(HUD.memory, prominent: true))
                Button("Reveal log") { model.reveal(session.file) }.buttonStyle(.hud(HUD.text3))
            }
            if !excerpt.isEmpty {
                Text("TRANSCRIPT").font(HUD.label(9.5)).tracking(1.4).foregroundStyle(HUD.text3)
                Text(excerpt).font(HUD.mono(10.5)).foregroundStyle(HUD.text2).textSelection(.enabled)
                    .padding(Space.md).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(HUD.bg.opacity(0.7)))
            }
        }
        .task(id: session.id) {
            if session.tool == "claude-code" { excerpt = String(await Transcript.excerpt(session.file, limit: 4_000).prefix(4_000)) }
        }
    }
}
