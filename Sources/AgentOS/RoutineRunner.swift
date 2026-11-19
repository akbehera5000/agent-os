import AgentOSKit
import Foundation
import SwiftUI

/// Runs routines when they're due, enforcing each routine's weekly rupee cap, and logs every run.
extension AppModel {
    func saveRoutines() {
        do { try routineStore.save(routines) } catch { flash("Could not save routines: \(error.localizedDescription)") }
    }

    func lastRun(_ r: Routine) -> RoutineRun? { routineRuns.last { $0.routineID == r.id } }

    func weeklySpendINR(_ r: Routine) -> Double { RoutineStore.weeklySpendINR(routineRuns, routine: r.id, now: now) }

    /// Fires every enabled routine whose scheduled time passed since its last run (once per slot).
    func runDueRoutines() {
        guard runningRoutine == nil, !SelfTest.requested, !Store.isOverridden else { return }
        for r in routines where r.enabled {
            let since = lastRun(r)?.date ?? now.addingTimeInterval(-3600)
            if r.nextRun(after: since) <= now {
                Task { await run(r) }
                return
            }
        }
    }

    func run(_ r: Routine) async {
        guard runningRoutine == nil else { flash("Another routine is running"); return }
        if r.kind.usesClaude, r.weeklyCapINR > 0, weeklySpendINR(r) >= r.weeklyCapINR {
            record(r, status: "capped", cost: 0, summary: "Weekly cap of \(Format.inr(r.weeklyCapINR)) reached — skipped")
            flash("\(r.name) skipped: weekly cap reached")
            return
        }
        withAnimation(HUD.spring) { runningRoutine = r.id }
        defer { withAnimation(HUD.spring) { runningRoutine = nil } }
        do {
            switch r.kind {
            case .briefing:
                jarvis.speak(briefing)
                record(r, status: "ok", cost: 0, summary: briefing)
            case .costDigest:
                let path = try writeCostDigest()
                record(r, status: "ok", cost: 0, summary: "Wrote \(URL(fileURLWithPath: path).lastPathComponent)")
            case .clutterWatch:
                await refresh()
                let bytes = snapshot.clutter.reduce(Int64(0)) { $0 + $1.bytes }
                let msg = "\(snapshot.clutter.count) clutter items · \(Format.bytes(bytes))"
                if bytes > 500_000_000 { flash("Clutter watch: \(msg). Open Janitor to clean up.") }
                record(r, status: "ok", cost: 0, summary: msg)
            case .memoryCapture:
                guard let s = snapshot.sessions.first(where: { $0.tool == "claude-code" && $0.messages >= 3 && now.timeIntervalSince($0.end) > 1800 }) else {
                    record(r, status: "skipped", cost: 0, summary: "No finished session to capture")
                    return
                }
                let project = TextRules.projectName(s.cwd)
                let transcript = await Transcript.excerpt(s.file)
                let (body, cost) = try await ClaudeCLI.runWithCost(prompt: "Session in project \(project):\n\n\(transcript)", model: r.model,
                                                                   system: MemoryPage.noteSystemPrompt)
                let path = try Actions.writeNote(title: "\(project) — \(s.title)", body: body, folder: "sessions", tags: ["agent-os", "routine"])
                record(r, status: "ok", cost: cost, summary: "Saved \(URL(fileURLWithPath: path).lastPathComponent)")
                await refresh()
            case .prompt:
                let (out, cost) = try await ClaudeCLI.runWithCost(prompt: r.prompt, model: r.model, system: "You are a scheduled routine in Agent OS. Be concise.")
                record(r, status: "ok", cost: cost, summary: TextRules.title(out, limit: 400))
            }
        } catch {
            record(r, status: "failed", cost: 0, summary: error.localizedDescription)
        }
    }

    private func record(_ r: Routine, status: String, cost: Double, summary: String) {
        let run = RoutineRun(routineID: r.id, date: .now, status: status, costUSD: cost, summary: summary)
        try? routineStore.append(run)
        withAnimation(HUD.spring) { routineRuns.append(run) }
    }

    /// A weekly spend note in Basic Memory, computed locally (zero tokens).
    private func writeCostDigest() throws -> String {
        let since = now.addingTimeInterval(-7 * 86_400)
        let rows = snapshot.projects.map { p -> (String, Double) in
            (p.name, sessions(of: p).flatMap(\.points).filter { $0.date >= since }.reduce(0) { $0 + $1.cost })
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        var body = "Week ending \(now.formatted(date: .long, time: .omitted)): \(Format.money(week.cost)) at API rates, \(Format.tokens(week.tokens)) tokens.\n\n## By project\n"
        body += rows.map { "- \($0.0): \(Format.money($0.1))" }.joined(separator: "\n")
        return try Actions.writeNote(title: "Cost digest \(now.formatted(.iso8601.year().month().day()))", body: body, folder: "digests", tags: ["agent-os", "cost"])
    }
}
