import AppKit
import AgentOSKit
import Darwin
import Foundation
import Network
import ServiceManagement
import SwiftUI

/// The pages in the left rail. Screenshot mode walks through every case.
enum Page: String, CaseIterable, Identifiable {
    case home, brain, projects, timeline, skills, connectors, usage, memory, janitor, shelf, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "Command"
        case .brain: "Second Brain"
        case .projects: "Projects"
        case .timeline: "Timeline"
        case .skills: "Skills"
        case .connectors: "Connectors"
        case .usage: "Usage & Cost"
        case .memory: "Memory"
        case .janitor: "Janitor"
        case .shelf: "Asset Shelf"
        case .system: "System"
        }
    }

    var symbol: String {
        switch self {
        case .home: "circle.hexagongrid"
        case .brain: "atom"
        case .projects: "folder.badge.gearshape"
        case .timeline: "clock.arrow.circlepath"
        case .skills: "square.grid.3x3.square"
        case .connectors: "point.3.connected.trianglepath.dotted"
        case .usage: "chart.bar.xaxis"
        case .memory: "brain"
        case .janitor: "sparkles"
        case .shelf: "photo.stack"
        case .system: "cpu"
        }
    }

    var tint: Color {
        switch self {
        case .home: HUD.cyan
        case .brain: HUD.skills
        case .projects: HUD.apps
        case .timeline: HUD.routines
        case .skills: HUD.skills
        case .connectors: HUD.high
        case .usage: HUD.routines
        case .memory: HUD.memory
        case .janitor: HUD.pink
        case .shelf: HUD.apps
        case .system: HUD.cyan
        }
    }

    /// Command-1 … Command-0.
    var key: KeyEquivalent {
        let i = (Page.allCases.firstIndex(of: self) ?? 0) + 1
        return KeyEquivalent(Character(String(i % 10)))
    }
}

/// App-wide state that menus, views and the menu bar share.
@Observable
final class AppModel {
    var snapshot: Snapshot = .empty
    var scanning = false
    var firstScanDone = false
    var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "launch.page") ?? "") ?? .home
    var paletteOpen = false
    var jarvisOpen = false
    var focusedProject: String?
    var toast: String?
    var settingsTab: SettingsTab = .budgets
    var now = Date.now
    /// Corrections you dismissed or turned into rules; everything else is still waiting.
    var dismissedCorrections: Set<String> = Set((UserDefaults.standard.string(forKey: "memory.dismissed") ?? "").split(separator: "\n").map(String.init)) {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(dismissedCorrections.joined(separator: "\n"), forKey: "memory.dismissed") } }
    }
    var pendingCorrections: [Correction] { snapshot.corrections.filter { !dismissedCorrections.contains($0.id) } }

    /// Whether the menu bar item is shown (Settings › General).
    var showMenuBar: Bool = UserDefaults.standard.object(forKey: "ui.menuBar") as? Bool ?? true {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(showMenuBar, forKey: "ui.menuBar") } }
    }

    /// Real internet connectivity, from the system's network path monitor.
    var online = true
    private let pathMonitor = NWPathMonitor()

    /// The second brain graph and what the inspector shows.
    var graph: BrainGraph = .empty
    /// How the brain is drawn; every style shows the same nodes.
    var brainStyle: BrainStyle = BrainStyle(rawValue: UserDefaults.standard.string(forKey: "brain.style") ?? "") ?? .galaxy {
        didSet {
            if !Store.isOverridden { UserDefaults.standard.set(brainStyle.rawValue, forKey: "brain.style") }
            let keep = selectedNode.flatMap { graph.nodes.indices.contains($0) ? graph.nodes[$0].id : nil }
            graph = Brain.build(snapshot, style: brainStyle)
            selectedNode = keep.flatMap { id in graph.nodes.firstIndex { $0.id == id } }
        }
    }
    var selectedNode: Int?
    var inspector: InspectTarget?
    var activity: [Activity] = []
    var routines: [Routine] = []
    var routineRuns: [RoutineRun] = []
    var runningRoutine: String?
    let routineStore = RoutineStore(dir: Store.isOverridden ? URL(fileURLWithPath: "/tmp/AgentOS-routines")
                                                            : URL.applicationSupportDirectory.appending(path: "AgentOS"))

    let jarvis = Jarvis()
    let ai = LocalAI()
    let system = SystemMonitor()
    private var timer: Timer?
    private var tick = 0

    /// First name for greetings.
    let userName = Demo.enabled ? Demo.userName : (NSFullUserName().split(separator: " ").first.map(String.init) ?? NSUserName())

    /// Budgets are in rupees.
    var weeklyBudgetINR: Double { UserDefaults.standard.object(forKey: "budget.week.inr") as? Double ?? 25_000 }
    var fiveHourBudgetINR: Double { UserDefaults.standard.object(forKey: "budget.5h.inr") as? Double ?? 3_500 }

    private var scanner: AgentOSKit.Scanner {
        let cache = URL.applicationSupportDirectory.appending(path: "AgentOS/session-cache.json")
        return Scanner(cacheURL: Store.isOverridden ? nil : cache)
    }

    init() {
        jarvis.app = self
    }

    func start() {
        guard timer == nil else { return }
        Task { await refresh() }
        system.sample()
        routines = routineStore.load()
        routineRuns = routineStore.runs()
        refreshActivity()
        Task { await updateExchangeRate() }
        Task { await ai.refresh() }
        pathMonitor.pathUpdateHandler = Self.pathHandler { [weak self] up in
            Task { @MainActor in withAnimation(HUD.quick) { self?.online = up } }
        }
        pathMonitor.start(queue: DispatchQueue(label: "agentos.network"))
        // One clock drives the dock, the cache countdown and periodic rescans.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.heartbeat() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    private func heartbeat() {
        now = .now
        tick += 1
        if tick % 3 == 0 { system.sample() }
        if tick % 4 == 0 { refreshActivity() }
        if tick % 20 == 0 { runDueRoutines() }
        let interval = max(30, Int(UserDefaults.standard.object(forKey: "scan.interval") as? Double ?? 60))
        if tick % interval == 0 { Task { await refresh() } }
    }

    func refresh() async {
        guard !scanning else { return }
        scanning = true
        let fresh = Demo.enabled ? Demo.snapshot() : await scanner.scan()
        let newGraph = Brain.build(fresh, style: brainStyle)
        let keep = selectedNode.flatMap { graph.nodes.indices.contains($0) ? graph.nodes[$0].id : nil }
        withAnimation(HUD.spring) {
            snapshot = fresh
            graph = newGraph
            selectedNode = keep.flatMap { id in newGraph.nodes.firstIndex { $0.id == id } }
            firstScanDone = true
        }
        scanning = false
    }

    nonisolated private static func pathHandler(_ done: @escaping @Sendable (Bool) -> Void) -> @Sendable (NWPath) -> Void {
        { path in done(path.status == .satisfied) }
    }

    // MARK: Inspector

    func select(node: Int?) {
        withAnimation(HUD.spring) {
            selectedNode = node
            inspector = node.flatMap { graph.nodes.indices.contains($0) ? InspectTarget(graph.nodes[$0], index: $0) : nil }
        }
    }

    /// Opens any file in the inspector, linking it to its brain node when there is one.
    func inspect(path: String, title: String? = nil, kind: BrainNode.Kind = .artifact, detail: String = "") {
        if let i = graph.nodes.firstIndex(where: { $0.path == path }) { select(node: i); return }
        withAnimation(HUD.spring) {
            inspector = InspectTarget(title: title ?? URL(fileURLWithPath: path).lastPathComponent, kind: kind, detail: detail, path: path, nodeIndex: nil)
        }
    }

    func closeInspector() { withAnimation(HUD.spring) { inspector = nil; selectedNode = nil } }

    private var activityRunning = false
    func refreshActivity() {
        if Demo.enabled { activity = Demo.activity(); return }
        guard !activityRunning else { return }
        activityRunning = true
        let scanner = scanner
        Task {
            let items = await Task.detached(priority: .utility) { scanner.activity(limit: 40) }.value
            if items.map(\.id) != activity.map(\.id) { withAnimation(HUD.quick) { activity = items } }
            activityRunning = false
        }
    }

    /// Rupees per dollar, refreshed once a day from a public rate feed (no personal data is sent).
    func updateExchangeRate() async {
        let d = UserDefaults.standard
        if let saved = d.object(forKey: "fx.inrPerUSD") as? Double { Format.inrPerUSD = saved }
        let last = d.object(forKey: "fx.updated") as? Date ?? .distantPast
        guard Date.now.timeIntervalSince(last) > 86_400, !Store.isOverridden,
              let url = URL(string: "https://open.er-api.com/v6/latest/USD") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rate = (json["rates"] as? [String: Any])?["INR"] as? Double, rate > 50, rate < 200 else { return }
        Format.inrPerUSD = rate
        d.set(rate, forKey: "fx.inrPerUSD")
        d.set(Date.now, forKey: "fx.updated")
        now = .now
    }

    func go(_ page: Page) {
        withAnimation(HUD.spring) { self.page = page }
    }

    func flash(_ message: String) {
        withAnimation(HUD.spring) { toast = message }
        Task {
            try? await Task.sleep(for: .seconds(3))
            withAnimation(HUD.spring) { if toast == message { toast = nil } }
        }
    }

    // MARK: Derived numbers

    var today: (tokens: Int, cost: Double) { Analytics.tokens(in: snapshot.sessions, since: Calendar.current.startOfDay(for: now)) }
    var week: (tokens: Int, cost: Double) { Analytics.tokens(in: snapshot.sessions, since: now.addingTimeInterval(-7 * 86_400)) }
    var fiveHours: (tokens: Int, cost: Double) { Analytics.tokens(in: snapshot.sessions, since: now.addingTimeInterval(-5 * 3600)) }
    var cacheLeft: TimeInterval { Analytics.cacheRemaining(snapshot.sessions, now: now) }
    var briefing: String {
        var s = snapshot
        s.corrections = pendingCorrections
        return Analytics.briefing(s, name: userName, now: now)
    }

    func sessions(of project: Project) -> [Session] {
        let roots = Set(project.locations)
        return snapshot.sessions.filter { roots.contains(TextRules.projectRoot($0.cwd)) }
    }

    // MARK: Actions

    func reveal(_ path: String) { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
    func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }

    func resume(_ session: Session) {
        do { NSWorkspace.shared.open(try Actions.resumeScript(for: session)) } catch { flash("Could not resume: \(error.localizedDescription)") }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied")
    }
}

/// Live Mac health: CPU, memory, disk, thermal state and AI processes.
@Observable
final class SystemMonitor {
    struct Proc: Identifiable, Hashable, Sendable { var id: Int32; var name: String; var cpu: Double; var memMB: Double }

    var cpu = 0.0
    var memoryUsed = 0.0
    let memoryTotal = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0
    var thermal = ProcessInfo.processInfo.thermalState
    var processes: [Proc] = []
    var cpuHistory: [Double] = Array(repeating: 0, count: 60)
    var launchAgents = 0
    private var lastTicks: (UInt64, UInt64)?
    private var psRunning = false

    let chip: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buf = [UInt8](repeating: 0, count: max(1, size))
        sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0)
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }()
    let cores = ProcessInfo.processInfo.activeProcessorCount

    func sample() {
        cpu = cpuLoad()
        cpuHistory.append(cpu)
        if cpuHistory.count > 60 { cpuHistory.removeFirst(cpuHistory.count - 60) }
        memoryUsed = usedMemoryGB()
        thermal = ProcessInfo.processInfo.thermalState
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            diskFree = v.volumeAvailableCapacityForImportantUsage ?? 0
            diskTotal = Int64(v.volumeTotalCapacity ?? 0)
        }
        launchAgents = ((try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents")) ?? []).count
        refreshProcesses()
    }

    private func cpuLoad() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let user = UInt64(info.cpu_ticks.0), sys = UInt64(info.cpu_ticks.1), idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        let busy = user + sys + nice, total = busy + idle
        defer { lastTicks = (busy, total) }
        guard let (b0, t0) = lastTicks, total > t0 else { return 0 }
        return Double(busy - b0) / Double(total - t0)
    }

    private func usedMemoryGB() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return 0 }
        let used = Double(UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * Double(getpagesize())
        return used / 1_073_741_824
    }

    /// AI-related processes, from `ps`, off the main thread.
    private func refreshProcesses() {
        guard !psRunning else { return }
        psRunning = true
        Task {
            let procs = await Self.aiProcesses()
            processes = procs
            psRunning = false
        }
    }

    @concurrent nonisolated private static func aiProcesses() async -> [Proc] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let keys = ["claude", "codex", "gemini", "ollama", "copilot", "chatgpt", "antigravity", "opencode", "qwen", "agentos", "basic-memory"]
        let procs: [Proc] = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let cpu = Double(parts[1]), let rss = Double(parts[2]) else { return nil }
            let name = URL(fileURLWithPath: String(parts[3])).lastPathComponent
            guard keys.contains(where: { name.lowercased().contains($0) }) else { return nil }
            return Proc(id: pid, name: name, cpu: cpu, memMB: rss / 1024)
        }
        return Array(procs.sorted { $0.memMB > $1.memMB }.prefix(14))
    }
}

/// What the inspector drawer shows: a brain node or any file.
struct InspectTarget: Equatable {
    var title: String
    var kind: BrainNode.Kind
    var detail: String
    var path: String?
    var nodeIndex: Int?

    init(title: String, kind: BrainNode.Kind, detail: String, path: String?, nodeIndex: Int?) {
        self.title = title; self.kind = kind; self.detail = detail; self.path = path; self.nodeIndex = nodeIndex
    }

    init(_ n: BrainNode, index: Int) {
        self.init(title: n.label, kind: n.kind, detail: n.detail, path: n.path, nodeIndex: index)
    }
}
