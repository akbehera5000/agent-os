import AgentOSKit
import SwiftUI

/// Pick Jarvis's brain and download offline models, all inside Agent OS.
struct AIModelsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var ai = model.ai
        let (engine, name) = ai.resolved
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(spacing: Space.md) {
                IconTile(symbol: engine == .claude ? "cloud" : "cpu", tint: engine == .claude ? HUD.high : HUD.memory, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Jarvis answers with \(name)").font(.system(size: 14, weight: .semibold)).foregroundStyle(HUD.text)
                    Text(engine == .claude ? "Cloud · uses your Claude login" : "Offline · private · ₹0 per answer").font(HUD.mono(10.5)).foregroundStyle(HUD.text2)
                }
                Spacer()
                Picker("Engine", selection: $ai.engine) { ForEach(LocalAI.Engine.allCases) { Text($0.label).tag($0) } }
                    .labelsHidden().frame(width: 250)
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                Text("APPLE ON-DEVICE MODEL").font(HUD.label(9.5)).tracking(1.4).foregroundStyle(HUD.text3)
                HStack {
                    Circle().strokeBorder(ai.appleAvailable ? HUD.on : HUD.off, lineWidth: 1.5).frame(width: 9, height: 9)
                    Text("Built into macOS · nothing to download · \(ai.appleStatus)").font(.system(size: 12)).foregroundStyle(HUD.text2)
                }
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                HStack {
                    Text("OLLAMA MODELS ON THIS MAC").font(HUD.label(9.5)).tracking(1.4).foregroundStyle(HUD.text3)
                    Spacer()
                    Circle().strokeBorder(ai.serverRunning ? HUD.on : HUD.off, lineWidth: 1.5).frame(width: 9, height: 9)
                    Text(ai.ollamaBinary == nil ? "Ollama not installed" : ai.serverRunning ? "Server running" : "Server stopped").font(HUD.mono(10)).foregroundStyle(HUD.text2)
                }
                if ai.ollamaBinary == nil {
                    HStack {
                        Text(model.snapshot.localModels.isEmpty
                             ? "Ollama runs the models. Install it once, then download models here."
                             : "The Ollama app was removed, but \(model.snapshot.localModels.joined(separator: ", ")) is still on disk. Reinstall Ollama and it's ready, no download.")
                            .font(.system(size: 12)).foregroundStyle(HUD.text2).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Get Ollama") { NSWorkspace.shared.open(URL(string: "https://ollama.com/download")!) }.buttonStyle(.hud(HUD.memory, prominent: true))
                    }
                }
                ForEach(ai.models) { m in
                    HoverRow {
                        HStack {
                            Image(systemName: m.name == ai.ollamaModel ? "largecircle.fill.circle" : "circle").foregroundStyle(m.name == ai.ollamaModel ? HUD.memory : HUD.text3)
                            Text(m.name).font(HUD.mono(12, .semibold)).foregroundStyle(HUD.text)
                            Text(Format.bytes(m.bytes)).font(HUD.mono(10)).foregroundStyle(HUD.text3)
                            Spacer()
                            if m.name != ai.ollamaModel { Button("Use") { ai.ollamaModel = m.name }.buttonStyle(.hud(HUD.memory)) } else { Tag(text: "in use", tint: HUD.memory, state: HUD.on) }
                            Button { Task { await ai.delete(m.name) } } label: { Image(systemName: "trash") }.buttonStyle(.hud(HUD.text3)).help("Delete this model")
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                Text("RECOMMENDED FOR YOUR M2 PRO · 16 GB").font(HUD.label(9.5)).tracking(1.4).foregroundStyle(HUD.text3)
                ForEach(LocalAI.recommended) { r in
                    let installed = ai.models.contains { $0.name == r.name || $0.name == r.name + ":latest" }
                    HoverRow {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            HStack(spacing: Space.sm) {
                                Text(r.name).font(HUD.mono(12, .semibold)).foregroundStyle(HUD.text)
                                if r.best { Tag(text: "recommended", tint: HUD.skills) }
                                Text(r.size).font(HUD.mono(10)).foregroundStyle(HUD.text3)
                                Spacer()
                                if installed {
                                    Tag(text: "installed", tint: HUD.memory, state: HUD.on)
                                } else if ai.progress[r.name] != nil {
                                    Text("\(Int((ai.progress[r.name] ?? 0) * 100))%").font(HUD.mono(11, .medium)).foregroundStyle(HUD.memory).contentTransition(.numericText())
                                } else {
                                    Button { Task { await ai.pull(r.name) } } label: { Label("Download", systemImage: "arrow.down.circle") }
                                        .buttonStyle(.hud(HUD.memory, prominent: r.best)).disabled(ai.ollamaBinary == nil)
                                }
                            }
                            Text(r.why).font(.system(size: 11.5)).foregroundStyle(HUD.text2)
                            if let p = ai.progress[r.name] {
                                Meter(value: p, colors: [HUD.memory, HUD.cyan], height: 5)
                            }
                            if let s = ai.status[r.name], !installed { Text(s).font(HUD.mono(9.5)).foregroundStyle(HUD.text3).lineLimit(1) }
                        }
                    }
                }
            }
            Text("Offline models can't read your files, so Jarvis gives them a summary of your projects, sessions and recent activity with each question. For deep file-level answers, switch to Claude after running `claude` → `/login` once in Terminal.")
                .font(.system(size: 11)).foregroundStyle(HUD.text3).fixedSize(horizontal: false, vertical: true)
        }
        .task { await model.ai.refresh() }
    }
}
