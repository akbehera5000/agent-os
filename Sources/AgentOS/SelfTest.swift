import AgentOSKit
import AppKit

/// Self-test for agents: runs the app's real functions, prints PASS or FAIL per check,
/// and quits with exit code 0 or 1. Reads this Mac's AI files; writes only inside /tmp.
///   APP_STORE=/tmp/AgentOS-self.store ~/Applications/AgentOS.app/Contents/MacOS/AgentOS --selftest
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0

    static func runIfRequested(model: AppModel) {
        guard requested else { return }
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            let started = Date.now
            // The app starts its first scan at launch; wait for it, then time a second (cached) scan.
            while !model.firstScanDone { try? await Task.sleep(for: .milliseconds(50)) }
            print("INFO first scan took \(String(format: "%.2f", Date.now.timeIntervalSince(started)))s")
            let rescan = Date.now
            await model.refresh()
            print("INFO rescan took \(String(format: "%.2f", Date.now.timeIntervalSince(rescan)))s")
            let s = model.snapshot
            check("scan finds AI tools", !s.tools.isEmpty, "\(s.tools.count)")
            check("scan finds Claude Code sessions", s.sessions.contains { $0.tool == "claude-code" })
            check("sessions have token usage", s.sessions.contains { $0.usage.total > 0 })
            check("projects are grouped", !s.projects.isEmpty, "\(s.projects.count)")
            check("skills are found", !s.skills.isEmpty, "\(s.skills.count)")
            check("connectors are found", !s.connectors.isEmpty, "\(s.connectors.count)")
            print("INFO tools=\(s.tools.map(\.name)) sessions=\(s.sessions.count) codex=\(s.sessions.filter { $0.tool == "codex" }.count) projects=\(s.projects.count) skills=\(s.skills.count) connectors=\(s.connectors.count) broken=\(s.connectors.filter { $0.health == .missing }.map(\.id)) corrections=\(s.corrections.count) clutter=\(s.clutter.count) notes=\(s.notes.count) assets=\(s.assets.count) week=\(Format.money(model.week.cost)) models=\(s.localModels)")
            print("INFO top projects: \(s.projects.prefix(8).map { "\($0.name)[\($0.locations.count)]" })")

            check("brain graph has every pillar", model.graph.count(.skill) > 0 && model.graph.count(.tool) > 0 && model.graph.count(.session) > 0, "\(model.graph.nodes.count) nodes")
            if let skill = model.graph.nodes.firstIndex(where: { $0.kind == .skill }) {
                model.select(node: skill)
                check("clicking a node opens the inspector on its file", model.inspector?.path?.hasSuffix("SKILL.md") == true)
                model.closeInspector()
            }
            // Clicks on a panel drawn over the orb must reach the panel, not the Metal view underneath.
            model.page = .home
            if let i = model.graph.nodes.firstIndex(where: { $0.kind == .project }) { model.select(node: i) }
            try? await Task.sleep(for: .seconds(1.5))
            if let win = NSApp.windows.first(where: { $0.canBecomeMain }), let content = win.contentView, let frame = content.superview,
               let zone = OverlayZones.rects["inspector"], let brain = Self.find(BrainMTKView.self, in: content) {
                let brainRect = brain.convert(brain.bounds, to: content)
                let brainTopLeft = CGRect(x: brainRect.minX, y: content.isFlipped ? brainRect.minY : content.bounds.height - brainRect.maxY,
                                          width: brainRect.width, height: brainRect.height)
                let overlap = zone.intersection(brainTopLeft)
                if overlap.isEmpty {
                    print("INFO inspector does not overlap the orb at this window size")
                } else {
                    let pt = CGPoint(x: overlap.midX, y: overlap.midY)
                    let local = NSPoint(x: pt.x, y: content.isFlipped ? pt.y : content.bounds.height - pt.y)
                    let hit = frame.hitTest(content.convert(local, to: nil))
                    check("panel over the orb receives clicks", hit.map { !$0.isDescendant(of: brain) } ?? false, "\(type(of: hit as Any))")
                }
                model.closeInspector()
                try? await Task.sleep(for: .seconds(0.6))
                let center = brain.convert(NSPoint(x: brain.bounds.midX, y: brain.bounds.midY), to: nil)
                check("the orb still receives clicks where nothing covers it", frame.hitTest(center).map { $0.isDescendant(of: brain) } ?? false)
            } else {
                check("found the orb and the inspector", false)
            }
            if let first = model.snapshot.corrections.first {
                // Toggle one correction both ways; the user's own dismissals stay as they were.
                let wasDismissed = model.dismissedCorrections.contains(first.id)
                model.dismissedCorrections.remove(first.id)
                let waiting = model.pendingCorrections.count
                model.dismissedCorrections.insert(first.id)
                check("dismissing a correction lowers the badge count", model.pendingCorrections.count == waiting - 1)
                if !wasDismissed { model.dismissedCorrections.remove(first.id) }
            }
            check("settings tabs include General and Data", SettingsTab.allCases.contains(.general) && SettingsTab.allCases.contains(.data))
            check("money shows in rupees", Format.money(1).hasPrefix("₹"))
            check("clock runs on IST", TimeZone.current.identifier == "Asia/Kolkata")
            check("routines load", !model.routines.isEmpty, "\(model.routines.count)")
            if model.ai.appleAvailable {
                var reply = ""
                let started = Date.now
                do {
                    for try await full in model.ai.appleChat(system: "Answer in one short sentence.", prompt: "Say hello to \(model.userName).") { reply = full }
                } catch { reply = "error: \(error.localizedDescription)" }
                print("INFO apple model replied in \(String(format: "%.1f", Date.now.timeIntervalSince(started)))s: \(reply.prefix(120))")
                check("offline Apple model answers", !reply.isEmpty && !reply.hasPrefix("error"))
            }
            check("Jarvis answers spend locally", model.jarvis.localAnswer("how much did I spend this week?")?.contains("this week") == true)
            check("Jarvis navigates", model.jarvis.localAnswer("open janitor") != nil && model.page == .janitor)
            check("briefing greets by name", model.briefing.contains(model.userName))

            let home = URL(fileURLWithPath: "/tmp/AgentOS-selftest-home")
            try? FileManager.default.removeItem(at: home)
            do {
                let files = try Actions.addRule("Keep replies short", toTools: ["claude-code", "codex"], home: home)
                let text = (try? String(contentsOfFile: files[0], encoding: .utf8)) ?? ""
                check("rule is written under its section", files.count == 2 && text.contains("## Rules from corrections") && text.contains("Keep replies short"))
                let skillSrc = home.appending(path: ".claude/skills/demo")
                try FileManager.default.createDirectory(at: skillSrc, withIntermediateDirectories: true)
                try "---\nname: demo\n---\n".write(to: skillSrc.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
                let copied = try Actions.installSkill(from: skillSrc.path, name: "demo", toTool: "codex", home: home)
                check("skill installs into another app", FileManager.default.fileExists(atPath: copied + "/SKILL.md"))
                let note = try Actions.writeNote(title: "Test note", body: "Body", folder: "sessions", tags: ["t"], home: home)
                check("memory note is written", FileManager.default.fileExists(atPath: note))
            } catch {
                check("file actions", false, error.localizedDescription)
            }
            var parsed = false
            if case .delta("hi") = ClaudeCLI.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}}"#) { parsed = true }
            check("stream-json delta parses", parsed)

            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)\(detail.isEmpty ? "" : " (\(detail))")" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
