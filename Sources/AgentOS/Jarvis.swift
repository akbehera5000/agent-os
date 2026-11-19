import AgentOSKit
import AVFoundation
import Carbon.HIToolbox
import Foundation
@preconcurrency import Speech
import SwiftUI

/// Jarvis: answers instantly from local data when it can (no tokens), otherwise asks
/// Claude through your own Claude Code login (`claude -p`), streaming the reply.
/// Speaks replies aloud and listens through the microphone when you ask it to.
@Observable
final class Jarvis {
    struct Message: Identifiable, Hashable {
        enum Role { case user, jarvis }
        let id = UUID()
        var role: Role
        var text: String
        var local = false
        var cost: Double?
        /// Which engine answered, shown under the reply ("GEMMA4:12B · OFFLINE").
        var engine: String?
    }

    var messages: [Message] = []
    var draft = ""
    var busy = false
    var listening = false
    var level: Double = 0
    weak var app: AppModel?

    var speaks: Bool = UserDefaults.standard.object(forKey: "jarvis.speak") as? Bool ?? true {
        didSet { UserDefaults.standard.set(speaks, forKey: "jarvis.speak") }
    }
    var model: String { UserDefaults.standard.string(forKey: "jarvis.model") ?? "sonnet" }

    private var process: Process?
    private let synth = AVSpeechSynthesizer()
    private var audio: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?

    // MARK: Ask

    func send(_ raw: String? = nil) {
        let text = (raw ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        draft = ""
        stopListening()
        withAnimation(HUD.spring) { messages.append(Message(role: .user, text: text)) }
        if let answer = localAnswer(text) {
            reply(answer, local: true)
        } else {
            askAI(text)
        }
    }

    func briefing() {
        guard let app else { return }
        withAnimation(HUD.spring) { app.jarvisOpen = true }
        reply(app.briefing, local: true)
    }

    private func reply(_ text: String, local: Bool, cost: Double? = nil) {
        withAnimation(HUD.spring) { messages.append(Message(role: .jarvis, text: text, local: local, cost: cost)) }
        speak(text)
    }

    /// Commands answered from the snapshot, with zero tokens.
    func localAnswer(_ q: String) -> String? {
        guard let app else { return nil }
        let t = q.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let s = app.snapshot
        func has(_ words: String...) -> Bool { words.contains { t.contains($0) } }

        if has("brief", "status", "how am i doing", "what's up", "whats up") { return app.briefing }
        for page in Page.allCases {
            let name = page.title.lowercased()
            if t == name || t == "open \(name)" || t == "go to \(name)" || t == "show \(name)" {
                app.go(page)
                return "Opening \(page.title)."
            }
        }
        if t.hasPrefix("open ") || t.hasPrefix("show ") {
            let name = String(t.dropFirst(5))
            if let p = s.projects.first(where: { $0.name.lowercased().contains(name) || name.contains($0.name.lowercased()) }) {
                app.focusedProject = p.id
                app.go(.projects)
                return "\(p.name): \(p.sessions) sessions across \(p.tools.map(ToolCatalog.name).joined(separator: ", ")), \(Format.money(p.usage.cost)) at API rates, last active \(p.lastActive.relative)."
            }
        }
        if has("spend", "cost", "spent", "how much") && !has("why", "reduce", "lower", "cut") {
            let top = s.projects.max { $0.usage.cost < $1.usage.cost }
            return "Today \(Format.money(app.today.cost)), this week \(Format.money(app.week.cost)), last 5 hours \(Format.money(app.fiveHours.cost)), at API rates. "
                + (top.map { "Your most expensive project is \($0.name) at \(Format.money($0.usage.cost))." } ?? "")
        }
        if has("cache") && !has("why", "how") {
            let m = Int(app.cacheLeft / 60)
            return m > 0 ? "Your prompt cache is warm for about \(m) more minutes." : "Your prompt cache is cold. The next Claude message rebuilds it."
        }
        if has("clean", "clutter", "janitor", "free space") {
            app.go(.janitor)
            let bytes = s.clutter.reduce(Int64(0)) { $0 + $1.bytes }
            return "I found \(s.clutter.count) clutter items, \(Format.bytes(bytes)) in total. They're on the Janitor page; nothing moves until you confirm."
        }
        if has("broken", "connector", "mcp") && !has("how", "why") {
            let bad = s.connectors.filter { $0.health == .missing }
            app.go(.connectors)
            return bad.isEmpty ? "All \(s.connectors.count) connectors resolve." : "Broken: " + bad.map { "\($0.name) in \(ToolCatalog.name($0.tool))" }.joined(separator: ", ") + "."
        }
        if has("correction", "rules") && !has("how", "why") {
            app.go(.memory)
            return "\(app.pendingCorrections.count) corrections are waiting. Turn the useful ones into rules on the Memory page."
        }
        if (t == "time" || t == "date" || has("what time", "what's the date", "what day")) {
            return "It's \(Date.now.formatted(date: .complete, time: .shortened))."
        }
        return nil
    }

    // MARK: Claude

    static var claudePath: String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// What an offline model needs to know, since it can't read files: the projects the question
    /// mentions with their recent sessions, plus the latest activity.
    private func offlineContext(for prompt: String, compact: Bool) -> String {
        guard let app else { return "" }
        let s = app.snapshot
        let q = prompt.lowercased()
        var lines = [context()]
        let mentioned = s.projects.filter { q.contains($0.name.lowercased()) }
        for p in mentioned.prefix(2) {
            let sessions = app.sessions(of: p).prefix(compact ? 4 : 10)
            lines.append("Project \(p.name) recent sessions (newest first): " + sessions.map {
                "\($0.end.formatted(date: .abbreviated, time: .shortened)) — \($0.title) [\(ToolCatalog.name($0.tool)), \($0.messages) prompts]"
            }.joined(separator: "; "))
            let acts = app.activity.filter { $0.project.lowercased() == p.name.lowercased() }.prefix(compact ? 5 : 15)
            if !acts.isEmpty { lines.append("Latest actions in \(p.name): " + acts.map { "\($0.verb) \($0.target)" }.joined(separator: "; ")) }
        }
        if mentioned.isEmpty {
            lines.append("Latest AI activity: " + app.activity.prefix(compact ? 6 : 15).map { "\($0.project): \($0.verb) \($0.target)" }.joined(separator: "; "))
        }
        if !app.pendingCorrections.isEmpty { lines.append("Recent corrections the user gave AIs: " + app.pendingCorrections.prefix(3).map(\.text).joined(separator: " | ")) }
        let text = lines.joined(separator: "\n")
        // Apple's on-device model has a small context window.
        return compact ? String(text.prefix(5_000)) : text
    }

    private func askAI(_ prompt: String) {
        guard let ai = app?.ai else { return }
        let (engine, modelName) = ai.resolved
        switch engine {
        case .claude: askClaude(prompt)
        case .ollama, .apple: askOffline(prompt, engine: engine, model: modelName)
        case .auto: askClaude(prompt)
        }
    }

    /// Answers with an offline model: no internet, no tokens billed.
    private func askOffline(_ prompt: String, engine: LocalAI.Engine, model: String) {
        guard let ai = app?.ai else { return }
        busy = true
        let index = messages.count
        let label = engine == .apple ? "APPLE ON-DEVICE · OFFLINE" : "\(model.uppercased()) · OFFLINE"
        withAnimation(HUD.spring) { messages.append(Message(role: .jarvis, text: "", local: true, engine: label)) }
        let history = messages.dropLast(2).suffix(6).filter { !$0.text.isEmpty }.map { ($0.role == .user ? "user" : "assistant", $0.text) }
        Task {
            do {
                if engine == .ollama {
                    guard await ai.ensureServer() else { throw NSError(domain: "Ollama", code: 2, userInfo: [NSLocalizedDescriptionKey: "Ollama isn't installed. Open Settings › AI Models."]) }
                    for try await piece in ai.ollamaChat(model: model, system: offlineContext(for: prompt, compact: false), history: Array(history), prompt: prompt) {
                        messages[index].text += piece
                    }
                } else {
                    for try await full in ai.appleChat(system: offlineContext(for: prompt, compact: true), prompt: prompt) {
                        messages[index].text = full
                    }
                }
            } catch {
                if messages[index].text.isEmpty { messages[index].text = "The offline model couldn't answer: \(error.localizedDescription)" }
            }
            if messages[index].text.isEmpty { messages[index].text = "No answer came back from the offline model." }
            busy = false
            speak(messages[index].text)
        }
    }

    /// Compact context so Claude can answer questions about your setup.
    private func context() -> String {
        guard let app else { return "" }
        let s = app.snapshot
        let projects = s.projects.prefix(12).map { "\($0.name) (\($0.tools.joined(separator: "/")), \($0.sessions) sessions, \(Format.money($0.usage.cost)), last \($0.lastActive.relative), at \($0.locations.first ?? ""))" }
        let tools = s.tools.map { "\($0.name): \($0.skillCount) skills, \($0.connectorCount) connectors, \($0.sessionCount) sessions" }
        return """
        You are Jarvis, the personal assistant inside Agent OS, a Mac app that watches \(app.userName)'s AI tools. \
        Be brief and direct, like a sharp chief of staff. Plain sentences, no headings or tables. Under 120 words unless asked.
        Now: \(Date.now.formatted(date: .complete, time: .shortened)).
        Usage at API rates: today \(Format.money(app.today.cost)), week \(Format.money(app.week.cost)).
        AI tools: \(tools.joined(separator: "; ")).
        Recent projects: \(projects.joined(separator: "; ")).
        Pending: \(app.pendingCorrections.count) corrections, \(s.connectors.filter { $0.health == .missing }.count) broken connectors, \(s.clutter.count) clutter items.
        Memory notes live in ~/basic-memory. You may read files to answer when you have file tools.
        """
    }

    private func askClaude(_ prompt: String) {
        guard let claude = Self.claudePath else {
            reply("I can't find the claude command. Install Claude Code, then ask again.", local: true)
            return
        }
        busy = true
        let index = messages.count
        withAnimation(HUD.spring) { messages.append(Message(role: .jarvis, text: "", engine: "CLAUDE \(model.uppercased())")) }
        let args = ["-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                    "--append-system-prompt", context(), "--allowedTools", "Read,Grep,Glob"]
        Task {
            do {
                let stream = ClaudeCLI.stream(claude, args: args, cwd: NSHomeDirectory()) { p in
                    Task { @MainActor in self.process = p }
                }
                for try await event in stream {
                    switch event {
                    case .delta(let d): messages[index].text += d
                    case .full(let f): if messages[index].text.isEmpty { messages[index].text = f }
                    case .done(let cost, let result):
                        if messages[index].text.isEmpty { messages[index].text = result }
                        messages[index].cost = cost
                    }
                }
            } catch {
                messages[index].text = "Claude didn't answer: \(error.localizedDescription)"
            }
            if messages[index].text.isEmpty { messages[index].text = "No answer came back. Check that `claude` works in Terminal." }
            busy = false
            process = nil
            // The standalone claude command isn't signed in (Claude desktop signs in its own copy): answer offline instead.
            if messages[index].text.localizedCaseInsensitiveContains("not logged in") || messages[index].text.contains("/login"),
               let ai = app?.ai {
                messages[index].text = "Claude isn't signed in on this Mac's command line (run `claude` then `/login` in Terminal to enable it). Answering offline instead."
                messages[index].cost = nil
                let fallback: (LocalAI.Engine, String)? = !ai.models.isEmpty ? (.ollama, ai.models.first { $0.name == ai.ollamaModel }?.name ?? ai.models[0].name)
                    : ai.appleAvailable ? (.apple, "Apple on-device") : nil
                if let (engine, name) = fallback { askOffline(prompt, engine: engine, model: name) }
                return
            }
            speak(messages[index].text)
        }
    }

    func stop() {
        process?.terminate()
        synth.stopSpeaking(at: .immediate)
        busy = false
    }

    // MARK: Voice out

    func speak(_ text: String) {
        guard speaks, !text.isEmpty else { return }
        synth.stopSpeaking(at: .immediate)
        let clean = text.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "").replacingOccurrences(of: "#", with: "")
        let u = AVSpeechUtterance(string: clean)
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        let chosen = UserDefaults.standard.string(forKey: "jarvis.voice").flatMap { id in id.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: id) }
        u.voice = chosen ?? voices.first { $0.quality == .premium } ?? voices.first { $0.quality == .enhanced } ?? AVSpeechSynthesisVoice(language: "en-GB")
        u.rate = Float(UserDefaults.standard.object(forKey: "jarvis.rate") as? Double ?? 0.52)
        synth.speak(u)
    }

    // MARK: Voice in

    func toggleListening() {
        listening ? stopListening(send: true) : startListening()
    }

    private func startListening() {
        // TCC answers on a background queue; the callback must not be main-actor isolated (that crashed).
        SFSpeechRecognizer.requestAuthorization(Self.authCallback { [weak self] ok in
            Task { @MainActor in
                guard ok else {
                    self?.app?.flash("Allow Speech Recognition for Agent OS in System Settings › Privacy & Security")
                    return
                }
                self?.beginAudio()
            }
        })
    }

    nonisolated private static func authCallback(_ done: @escaping @Sendable (Bool) -> Void) -> @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void {
        { status in done(status == .authorized) }
    }

    private func beginAudio() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            app?.flash("Speech recognition is not available")
            return
        }
        synth.stopSpeaking(at: .immediate)
        let engine = AVAudioEngine()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0), block: Self.tap(req) { [weak self] level in
            Task { @MainActor in self?.level = level }
        })
        do {
            engine.prepare()
            try engine.start()
        } catch {
            app?.flash("Microphone unavailable: \(error.localizedDescription)")
            return
        }
        audio = engine
        request = req
        listening = true
        recognition = recognizer.recognitionTask(with: req, resultHandler: Self.handler { [weak self] text, final, failed in
            Task { @MainActor in
                guard let self else { return }
                if let text { self.draft = text }
                if final || failed { self.stopListening(send: final) }
            }
        })
    }

    /// Built outside the main actor: the audio thread calls it.
    nonisolated private static func tap(_ req: SFSpeechAudioBufferRecognitionRequest, level: @escaping @Sendable (Double) -> Void) -> AVAudioNodeTapBlock {
        { buffer, _ in
            req.append(buffer)
            level(rms(buffer))
        }
    }

    nonisolated private static func handler(_ out: @escaping @Sendable (String?, Bool, Bool) -> Void) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in out(result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil) }
    }

    func stopListening(send: Bool = false) {
        guard listening else { return }
        audio?.inputNode.removeTap(onBus: 0)
        audio?.stop()
        request?.endAudio()
        recognition?.cancel()
        audio = nil; request = nil; recognition = nil
        listening = false
        level = 0
        if send, !draft.isEmpty { self.send() }
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return Double(min(1, sqrt(sum / Float(n)) * 12))
    }
}

/// Runs `claude -p` and turns its stream-json output into events.
enum ClaudeCLI {
    enum Event: Sendable { case delta(String), full(String), done(cost: Double?, result: String) }

    nonisolated static func stream(_ path: String, args: [String], cwd: String, onStart: @escaping @Sendable (Process) -> Void) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            var env = ProcessInfo.processInfo.environment
            // Apps start with a minimal PATH; give claude the usual tool folders.
            env["PATH"] = ["\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""].joined(separator: ":")
            p.environment = env
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            do { try p.run() } catch { continuation.finish(throwing: error); return }
            onStart(p)
            let reader = Task.detached {
                do {
                    for try await line in out.fileHandleForReading.bytes.lines {
                        if let e = parse(line) { continuation.yield(e) }
                    }
                } catch {}
                p.waitUntilExit()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                reader.cancel()
                if p.isRunning { p.terminate() }
            }
        }
    }

    nonisolated static func parse(_ line: String) -> Event? {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return nil }
        switch o["type"] as? String {
        case "stream_event":
            let ev = o["event"] as? [String: Any]
            if (ev?["type"] as? String) == "content_block_delta", let d = ev?["delta"] as? [String: Any],
               (d["type"] as? String) == "text_delta", let t = d["text"] as? String { return .delta(t) }
        case "assistant":
            let content = (o["message"] as? [String: Any])?["content"] as? [[String: Any]]
            let text = content?.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }.joined() ?? ""
            if !text.isEmpty { return .full(text) }
        case "result":
            return .done(cost: o["total_cost_usd"] as? Double, result: o["result"] as? String ?? "")
        default: break
        }
        return nil
    }

    /// Collects a whole reply and what it cost in US dollars (routines log the cost).
    static func runWithCost(prompt: String, model: String, system: String) async throws -> (String, Double) {
        guard let path = Jarvis.claudePath else {
            throw NSError(domain: "AgentOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "claude command not found"])
        }
        var text = "", result = "", cost = 0.0
        let args = ["-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose", "--append-system-prompt", system]
        for try await e in stream(path, args: args, cwd: NSHomeDirectory(), onStart: { _ in }) {
            switch e {
            case .delta(let d): text += d
            case .full(let f): if text.isEmpty { text = f }
            case .done(let c, let r): result = r; cost = c ?? 0
            }
        }
        let out = text.isEmpty ? result : text
        if out.isEmpty { throw NSError(domain: "AgentOS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Claude returned nothing"]) }
        return (out, cost)
    }

    /// Collects a whole reply (used by the memory filler).
    static func run(prompt: String, model: String, system: String) async throws -> String {
        guard let path = Jarvis.claudePath else {
            throw NSError(domain: "AgentOS", code: 1, userInfo: [NSLocalizedDescriptionKey: "claude command not found"])
        }
        var text = "", result = ""
        let args = ["-p", prompt, "--model", model, "--output-format", "stream-json", "--verbose", "--append-system-prompt", system]
        for try await e in stream(path, args: args, cwd: NSHomeDirectory(), onStart: { _ in }) {
            switch e {
            case .delta(let d): text += d
            case .full(let f): if text.isEmpty { text = f }
            case .done(_, let r): result = r
            }
        }
        return text.isEmpty ? result : text
    }
}

/// ⌥⌘J from anywhere summons Jarvis. Carbon hot keys need no Accessibility permission.
enum HotKey {
    nonisolated(unsafe) private static var handler: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            Task { @MainActor in HotKey.fire() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(optionKey | cmdKey), EventHotKeyID(signature: 0x414F_534A, id: 1),
                            GetApplicationEventTarget(), 0, &ref)
    }

    static func fire() {
        guard UserDefaults.standard.object(forKey: "hotkey.enabled") as? Bool ?? true else { return }
        handler?()
    }
    static func enable() { UserDefaults.standard.set(true, forKey: "hotkey.enabled") }
    static func disable() { UserDefaults.standard.set(false, forKey: "hotkey.enabled") }
}
