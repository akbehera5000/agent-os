import AgentOSKit
import Foundation
import FoundationModels
import SwiftUI

/// Offline AI for Jarvis. Two engines, both free and private:
///  - Ollama models on this Mac (Agent OS starts the Ollama server itself and downloads models in-app)
///  - Apple's on-device model (Apple Intelligence), built into macOS, nothing to download
/// Claude (through the `claude` command) stays available as the cloud option.
@Observable
final class LocalAI {
    enum Engine: String, CaseIterable, Identifiable {
        case auto, ollama, apple, claude
        var id: String { rawValue }
        var label: String {
            switch self {
            case .auto: "Auto (best offline model)"
            case .ollama: "Ollama model on this Mac"
            case .apple: "Apple on-device model"
            case .claude: "Claude (cloud, needs claude login)"
            }
        }
    }

    struct Model: Identifiable, Hashable { var id: String { name }; var name: String; var bytes: Int64 }

    /// Picked for an M2 Pro with 16 GB of memory: they run fully in RAM on the GPU.
    struct Recommendation: Identifiable { var id: String { name }; let name: String; let size: String; let why: String; let best: Bool }
    static let recommended: [Recommendation] = [
        .init(name: "gemma4:12b", size: "7.5 GB", why: "Best all-round quality that fits 16 GB. Great for briefings, summaries and questions about your projects.", best: true),
        .init(name: "qwen3:8b", size: "5.2 GB", why: "Strong reasoning and code; a good second model for technical questions.", best: false),
        .init(name: "llama3.2:3b", size: "2.0 GB", why: "Very fast replies for quick commands and voice.", best: false),
        .init(name: "phi4-mini", size: "2.5 GB", why: "Small and sharp at step-by-step answers.", best: false),
    ]

    static let ollamaPaths = ["/usr/local/bin/ollama", "/opt/homebrew/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
    var ollamaBinary: String? { Self.ollamaPaths.first { FileManager.default.isExecutableFile(atPath: $0) } }
    var serverRunning = false
    var models: [Model] = []
    var progress: [String: Double] = [:]
    var status: [String: String] = [:]
    private var server: Process?
    private let base = URL(string: "http://127.0.0.1:11434")!

    var engine: Engine = Engine(rawValue: UserDefaults.standard.string(forKey: "ai.engine") ?? "") ?? .auto {
        didSet { UserDefaults.standard.set(engine.rawValue, forKey: "ai.engine") }
    }
    var ollamaModel: String = UserDefaults.standard.string(forKey: "ai.ollamaModel") ?? "" {
        didSet { UserDefaults.standard.set(ollamaModel, forKey: "ai.ollamaModel") }
    }

    var appleAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var appleStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: "Ready"
        case .unavailable(let reason): "Unavailable: \(reason)"
        }
    }

    /// The engine and model Jarvis will actually use for a question.
    var resolved: (Engine, String) {
        let installed = models.map(\.name)
        let pick = installed.contains(ollamaModel) ? ollamaModel : (installed.first ?? "")
        switch engine {
        case .ollama: return (.ollama, pick)
        case .apple: return (.apple, "Apple on-device")
        case .claude: return (.claude, "Claude")
        case .auto:
            if ollamaBinary != nil && !pick.isEmpty { return (.ollama, pick) }
            if appleAvailable { return (.apple, "Apple on-device") }
            return (.claude, "Claude")
        }
    }

    // MARK: Ollama server and models

    /// Starts `ollama serve` if nothing answers on port 11434. Returns true when the server is up.
    @discardableResult
    func ensureServer() async -> Bool {
        if await ping() { serverRunning = true; return true }
        guard let bin = ollamaBinary else { serverRunning = false; return false }
        if server == nil || server?.isRunning == false {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["serve"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run(); server = p } catch { return false }
        }
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(250))
            if await ping() { serverRunning = true; return true }
        }
        return false
    }

    /// Stops the Ollama server only if Agent OS started it.
    func stopServer() { if server?.isRunning == true { server?.terminate() } }

    private func ping() async -> Bool {
        var req = URLRequest(url: base.appending(path: "api/version"))
        req.timeoutInterval = 1
        return ((try? await URLSession.shared.data(for: req))?.1 as? HTTPURLResponse)?.statusCode == 200
    }

    func refresh() async {
        guard await ensureServer() else { models = []; return }
        guard let (data, _) = try? await URLSession.shared.data(from: base.appending(path: "api/tags")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = json["models"] as? [[String: Any]] else { return }
        models = list.compactMap { m in (m["name"] as? String).map { Model(name: $0, bytes: (m["size"] as? NSNumber)?.int64Value ?? 0) } }
            .sorted { $0.name < $1.name }
        if ollamaModel.isEmpty || !models.contains(where: { $0.name == ollamaModel }) { ollamaModel = models.first?.name ?? "" }
    }

    /// Downloads a model through Ollama, with live progress.
    func pull(_ name: String) async {
        guard await ensureServer() else { status[name] = "Ollama is not installed"; return }
        progress[name] = 0
        status[name] = "Starting…"
        var req = URLRequest(url: base.appending(path: "api/pull"))
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
        req.timeoutInterval = 3600
        do {
            let (bytes, _) = try await URLSession.shared.bytes(for: req)
            for try await line in bytes.lines {
                guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                if let err = o["error"] as? String { status[name] = err; progress[name] = nil; return }
                if let s = o["status"] as? String { status[name] = s }
                if let total = (o["total"] as? NSNumber)?.doubleValue, total > 0, let done = (o["completed"] as? NSNumber)?.doubleValue {
                    progress[name] = done / total
                }
            }
            progress[name] = nil
            status[name] = "Installed"
            await refresh()
            if ollamaModel.isEmpty { ollamaModel = name }
        } catch {
            progress[name] = nil
            status[name] = "Download failed: \(error.localizedDescription)"
        }
    }

    func delete(_ name: String) async {
        var req = URLRequest(url: base.appending(path: "api/delete"))
        req.httpMethod = "DELETE"
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name])
        _ = try? await URLSession.shared.data(for: req)
        status[name] = nil
        await refresh()
    }

    // MARK: Chat

    /// Streams a reply from an Ollama model, piece by piece.
    func ollamaChat(model: String, system: String, history: [(String, String)], prompt: String) -> AsyncThrowingStream<String, Error> {
        let base = base
        return AsyncThrowingStream { continuation in
            let task = Task {
                var messages: [[String: String]] = [["role": "system", "content": system]]
                messages += history.map { ["role": $0.0, "content": $0.1] }
                messages.append(["role": "user", "content": prompt])
                var req = URLRequest(url: base.appending(path: "api/chat"))
                req.httpMethod = "POST"
                req.timeoutInterval = 600
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "messages": messages, "stream": true,
                                                                             "options": ["num_ctx": 8192]] as [String: Any])
                do {
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in bytes.lines {
                        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { continue }
                        if let err = o["error"] as? String { throw NSError(domain: "Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: err]) }
                        if let piece = (o["message"] as? [String: Any])?["content"] as? String, !piece.isEmpty { continuation.yield(piece) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Streams a reply from Apple's on-device model; each value is the full text so far.
    func appleChat(system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: system)
                    for try await partial in session.streamResponse(to: prompt) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
