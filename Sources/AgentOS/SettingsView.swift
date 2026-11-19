import AgentOSKit
import AVFoundation
import ServiceManagement
import SwiftUI

/// The Settings window (Command-Comma). One tab per topic.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.settingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                page(tab)
                    .tabItem { Label(tab.title, systemImage: tab.symbol) }
                    .tag(tab)
            }
        }
        .noInitialFocus()
    }

    @ViewBuilder
    private func page(_ tab: SettingsTab) -> some View {
        Form {
            switch tab {
            case .general: GeneralSettings()
            case .appearance: AppearanceSettings()
            case .budgets: BudgetSettings()
            case .jarvis: JarvisSettings()
            case .models: Section { AIModelsView() }
            case .data: DataSettings()
            }
        }
        .formStyle(.grouped)
        .fitsContent(max: 760)
        .frame(width: tab == .models ? 640 : 560)
    }
}

/// The Settings tabs. Screenshot mode walks through every case.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, budgets, jarvis, models, data

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .budgets: "Budgets"
        case .jarvis: "Jarvis"
        case .models: "AI Models"
        case .data: "Data"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "sparkles"
        case .budgets: "gauge.with.dots.needle.50percent"
        case .jarvis: "waveform.circle"
        case .models: "cpu"
        case .data: "externaldrive"
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage("ui.dock") private var showDock = true
    @AppStorage("hotkey.enabled") private var hotkey = true
    @AppStorage("launch.page") private var launchPage = Page.home.rawValue
    @AppStorage("scan.interval") private var scanInterval = 60.0

    var body: some View {
        Section("Startup") {
            Toggle("Open Agent OS at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in setLogin(on) }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            if SMAppService.mainApp.status == .requiresApproval {
                HStack {
                    Text("macOS needs your approval in Login Items.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            Picker("Open on", selection: $launchPage) {
                ForEach(Page.allCases) { Text($0.title).tag($0.rawValue) }
            }
        }
        Section {
            Toggle("Show in the menu bar", isOn: Binding(get: { model.showMenuBar }, set: { model.showMenuBar = $0 }))
                .disabled(!showDock && model.showMenuBar)
            Toggle("Show in the Dock", isOn: $showDock)
                .disabled(!model.showMenuBar && showDock)
                .onChange(of: showDock) { _, on in NSApp.setActivationPolicy(on ? .regular : .accessory); if !on { NSApp.activate() } }
            Toggle("⌥⌘J talks to Jarvis from any app", isOn: $hotkey)
                .onChange(of: hotkey) { _, on in on ? HotKey.enable() : HotKey.disable() }
        } header: {
            Text("Presence")
        } footer: {
            Text("Agent OS keeps one of the menu bar or Dock so you can always reach it. Routines run while it's open.")
        }
        Section("Scanning") {
            Picker("Rescan your AI tools", selection: $scanInterval) {
                Text("Every 30 seconds").tag(30.0)
                Text("Every minute").tag(60.0)
                Text("Every 5 minutes").tag(300.0)
                Text("Every 15 minutes").tag(900.0)
            }
            LabeledContent("Last scan", value: model.snapshot.scannedAt.formatted(date: .abbreviated, time: .standard) + " IST")
            Button("Rescan now") { Task { await model.refresh() } }
        }
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("render.maxFPS") private var maxFPS = 120
    @AppStorage("brain.labels") private var labels = true

    var body: some View {
        @Bindable var model = model
        Section("Second brain") {
            Picker("Style", selection: $model.brainStyle) {
                ForEach(BrainStyle.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            Toggle("Show planet and project labels", isOn: $labels)
        }
        Section {
            Picker("Animation frame rate", selection: $maxFPS) {
                Text("Battery saver · 30 fps").tag(30)
                Text("Smooth · 60 fps").tag(60)
                Text("ProMotion · up to 120 fps").tag(120)
            }
        } header: {
            Text("Performance")
        } footer: {
            Text("The brain idles at 60 fps and drops to 30 fps in the background either way; this caps the top speed while you drag or Jarvis works.")
        }
    }
}

// MARK: - Budgets

struct BudgetSettings: View {
    @AppStorage("budget.week.inr") private var week = 25_000.0
    @AppStorage("budget.5h.inr") private var fiveHours = 3_500.0

    var body: some View {
        Section {
            TextField("Weekly budget", value: $week, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
            TextField("5-hour budget", value: $fiveHours, format: .currency(code: "INR").locale(Locale(identifier: "en_IN")))
            LabeledContent("Exchange rate", value: "₹\(String(format: "%.2f", Format.inrPerUSD)) per US dollar, updated daily")
        } header: {
            Text("Usage bars")
        } footer: {
            Text("Costs are Anthropic API rates converted to rupees. The 7D and 5H bars compare that spend with these budgets; subscription plans don't publish exact limits, so set what feels right for yours.")
        }
    }
}

// MARK: - Jarvis

struct JarvisSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage("jarvis.model") private var jarvisModel = "sonnet"
    @AppStorage("jarvis.voice") private var voiceID = ""
    @AppStorage("jarvis.rate") private var rate = 0.52

    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
            .sorted { ($0.quality.rawValue, $0.name) > ($1.quality.rawValue, $1.name) }
    }

    var body: some View {
        @Bindable var jarvis = model.jarvis
        Section("Voice") {
            Toggle("Speak replies aloud", isOn: $jarvis.speaks)
            Picker("Voice", selection: $voiceID) {
                Text("Best available").tag("")
                ForEach(voices, id: \.identifier) { v in
                    Text("\(v.name) · \(v.language)\(v.quality == .premium ? " · premium" : v.quality == .enhanced ? " · enhanced" : "")").tag(v.identifier)
                }
            }
            Slider(value: $rate, in: 0.4...0.62) { Text("Speed") } minimumValueLabel: { Text("Slow") } maximumValueLabel: { Text("Fast") }
            Button("Test voice") { model.jarvis.speak("Hello \(model.userName). Your second brain is online.") }
        }
        Section {
            Picker("Claude model (cloud engine)", selection: $jarvisModel) {
                Text("Haiku — fastest, cheapest").tag("haiku")
                Text("Sonnet — balanced").tag("sonnet")
                Text("Opus — deepest").tag("opus")
            }
            LabeledContent("claude command", value: Jarvis.claudePath ?? "Not found")
        } header: {
            Text("Cloud")
        } footer: {
            Text("Briefings, costs, navigation and status answers are computed on this Mac and use no tokens. Other questions use the engine chosen in AI Models.")
        }
    }
}

// MARK: - Data

struct DataSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false

    private var dataDir: URL { URL.applicationSupportDirectory.appending(path: "AgentOS") }

    var body: some View {
        Section {
            LabeledContent("Sessions indexed", value: "\(model.snapshot.sessions.count)")
            LabeledContent("Brain nodes", value: "\(model.graph.nodes.count)")
            LabeledContent("Routine runs logged", value: "\(model.routineRuns.count)")
        } header: {
            Text("What Agent OS knows")
        } footer: {
            Text("Agent OS only reads your AI tools' files. It writes its own cache, routines and run log to Application Support, and notes or rules only when you press a button.")
        }
        Section("Storage") {
            HStack {
                Text(dataDir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { NSWorkspace.shared.open(dataDir) }
            }
            Button("Clear session cache and rescan…") { confirmClear = true }
                .confirmationDialog("Clear the session cache?", isPresented: $confirmClear) {
                    Button("Clear and rescan") {
                        try? FileManager.default.removeItem(at: dataDir.appending(path: "session-cache.json"))
                        Task { await model.refresh() }
                    }
                } message: {
                    Text("Agent OS re-reads every session log on the next scan. Your AI tools' files are not touched.")
                }
        }
    }
}
