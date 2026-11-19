import AgentOSKit
import AppKit
import SwiftUI

// AgentOS
//   AgentOS                      the app
//   APP_STORE=<file> AgentOS     test mode: no session cache is written (tests, snapshots)
//   APP_SNAPSHOT=<dir> AgentOS   save a PNG of every page and Settings tab, then quit (tools/snap.sh)
//   AgentOS --selftest           run the self-test and quit with 0 or 1 (tools/selftest.sh)
//   APP_GRID=1 AgentOS           draw the grid and the layout probes over the window

@main
struct AgentOSApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Agent OS", id: "main") {
            Shell()
                .environment(model)
                .overlay { if GridOverlay.enabled { GridOverlay() } }
                .frame(minWidth: 1180, minHeight: 760)
                .onAppear { delegate.model = model }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1500, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Go") {
                ForEach(Page.allCases) { page in
                    Button(page.title) { model.go(page) }.keyboardShortcut(page.key)
                }
            }
            CommandMenu("Jarvis") {
                Button("Search Everything…") { withAnimation(HUD.spring) { model.paletteOpen = true } }.keyboardShortcut("k")
                Button(model.jarvisOpen ? "Hide Jarvis" : "Show Jarvis") { withAnimation(HUD.spring) { model.jarvisOpen.toggle() } }.keyboardShortcut("j")
                Button("Talk to Jarvis") {
                    withAnimation(HUD.spring) { model.jarvisOpen = true }
                    model.jarvis.toggleListening()
                }
                .keyboardShortcut("j", modifiers: [.command, .shift])
                Button("Brief Me") { model.jarvis.briefing() }.keyboardShortcut("b", modifiers: [.command, .shift])
                Divider()
                Button("Rescan") { Task { await model.refresh() } }.keyboardShortcut("r")
                Divider()
                Menu("Brain Style") {
                    ForEach(BrainStyle.allCases) { s in
                        Button(s.title) { model.brainStyle = s }
                    }
                }
                Button("Next Brain Style") {
                    let all = BrainStyle.allCases
                    model.brainStyle = all[((all.firstIndex(of: model.brainStyle) ?? 0) + 1) % all.count]
                }
                .keyboardShortcut("y")
            }
        }

        // Only write when the value really changes: MenuBarExtra sets it back on every update,
        // and an unconditional write would loop forever.
        MenuBarExtra(isInserted: Binding(get: { model.showMenuBar }, set: { if model.showMenuBar != $0 { model.showMenuBar = $0 } })) {
            MenuBarContent().environment(model)
        } label: {
            Image(systemName: "circle.hexagongrid.fill")
            Text(model.today.cost > 0 ? Format.money(model.today.cost) : "")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    override init() {
        // Indian Standard Time for every date and clock in the app.
        NSTimeZone.default = TimeZone(identifier: "Asia/Kolkata")!
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dock = UserDefaults.standard.object(forKey: "ui.dock") as? Bool ?? true
        NSApp.setActivationPolicy(dock || SelfTest.requested ? .regular : .accessory)
        NSApp.activate()
        NSApp.appearance = NSAppearance(named: .darkAqua)
        HotKey.register { [weak self] in
            NSApp.activate()
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            guard let model = self?.model else { return }
            withAnimation(HUD.spring) { model.jarvisOpen = true }
            if !model.jarvis.listening { model.jarvis.toggleListening() }
        }
    }

    /// Closing the window keeps Agent OS in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { SelfTest.requested }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        model?.ai.stopServer()
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

/// Test runs set APP_STORE to a /tmp path; then nothing is cached to disk.
enum Store {
    static var isOverridden: Bool {
        !(ProcessInfo.processInfo.environment["APP_STORE"] ?? "").isEmpty
    }
}

/// The menu bar companion: today, cache, briefing, quick actions.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                Text("AGENT OS").font(.system(size: 12, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(HUD.text)
                Spacer()
                Circle().fill(model.cacheLeft > 0 ? HUD.on : HUD.off).frame(width: 7, height: 7)
                Text(model.cacheLeft > 0 ? "CACHE \(Int(model.cacheLeft / 60))M" : "CACHE COLD").font(HUD.label(9.5)).foregroundStyle(HUD.text2)
            }
            HStack(spacing: Space.xl) {
                Metric(label: "Today", value: Format.money(model.today.cost), tint: HUD.routines)
                Metric(label: "Week", value: Format.money(model.week.cost), tint: HUD.skills)
                Metric(label: "Tokens", value: Format.tokens(model.today.tokens))
            }
            Text(model.briefing).font(.system(size: 11.5)).foregroundStyle(HUD.text2).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Agent OS") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.hud(HUD.apps, prominent: true))
                Button("Brief me") { model.jarvis.speak(model.briefing) }.buttonStyle(.hud(HUD.cyan))
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.hud(HUD.text3)).help("Quit Agent OS")
            }
        }
        .padding(Space.lg)
        .frame(width: 360)
        .background(HUD.bgRaised)
        .preferredColorScheme(.dark)
        .task { model.start() }
    }
}
