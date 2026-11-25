import Foundation

/// Everything Agent OS knows about this Mac, built by `Scanner.scan()`.
public struct Snapshot: Sendable {
    public var scannedAt: Date
    public var tools: [AITool]
    public var sessions: [Session]
    public var projects: [Project]
    public var skills: [Skill]
    public var connectors: [Connector]
    public var corrections: [Correction]
    public var notes: [MemoryNote]
    public var clutter: [ClutterItem]
    public var assets: [DesignAsset]
    public var localModels: [String]
    public var ollamaRunning: Bool
    public var docs: [Doc] = []

    public init(scannedAt: Date = .now, tools: [AITool] = [], sessions: [Session] = [], projects: [Project] = [],
                skills: [Skill] = [], connectors: [Connector] = [], corrections: [Correction] = [],
                notes: [MemoryNote] = [], clutter: [ClutterItem] = [], assets: [DesignAsset] = [],
                localModels: [String] = [], ollamaRunning: Bool = false) {
        self.scannedAt = scannedAt; self.tools = tools; self.sessions = sessions; self.projects = projects
        self.skills = skills; self.connectors = connectors; self.corrections = corrections; self.notes = notes
        self.clutter = clutter; self.assets = assets; self.localModels = localModels; self.ollamaRunning = ollamaRunning
    }

    public static let empty = Snapshot()
}

public struct AITool: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var kind: String
    public var appPath: String?
    public var configDir: String?
    public var installed: Bool
    public var skillCount = 0
    public var connectorCount = 0
    public var sessionCount = 0
    public var lastUsed: Date?
    public var tokens = 0
    public var costUSD = 0.0
    public var symbol: String
    public var hue: Double
}

public struct Usage: Sendable, Hashable, Codable {
    public var input = 0
    public var output = 0
    public var cacheWrite = 0
    public var cacheRead = 0
    public var cost = 0.0
    /// Times a skill was invoked (only used in per-skill usage).
    public var runs = 0
    public init() {}
    public var total: Int { input + output + cacheWrite + cacheRead }
    public static func + (a: Usage, b: Usage) -> Usage {
        var u = a
        u.input += b.input; u.output += b.output; u.cacheWrite += b.cacheWrite; u.cacheRead += b.cacheRead; u.cost += b.cost; u.runs += b.runs
        return u
    }
}

/// One timestamped usage sample, for rolling 5-hour / 7-day windows and charts.
public struct UsagePoint: Sendable, Hashable, Codable {
    public var date: Date
    public var tokens: Int
    public var cost: Double
}

public struct Session: Sendable, Identifiable, Hashable, Codable {
    public var id: String
    public var tool: String
    public var cwd: String
    public var title: String
    public var start: Date
    public var end: Date
    public var model: String
    public var usage: Usage
    public var points: [UsagePoint]
    public var messages: Int
    public var branch: String?
    public var file: String
    public var corrections: [String]
    /// Tokens and cost per skill used in this session, keyed by skill name.
    public var skillUse: [String: Usage]
}

public struct Project: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var locations: [String]
    public var tools: [String]
    public var sessions: Int
    public var usage: Usage
    public var lastActive: Date
    public var existing: Int
}

public struct Skill: Sendable, Identifiable, Hashable {
    public var id: String { "\(tool)/\(name)" }
    public var name: String
    public var description: String
    public var tool: String
    public var path: String
    public var source: String
}

public struct Connector: Sendable, Identifiable, Hashable {
    public var id: String { "\(tool)/\(name)" }
    public var name: String
    public var tool: String
    public var transport: String
    public var command: String
    public var health: Health
    public var configFile: String

    public enum Health: String, Sendable, Hashable { case ok, missing, remote, disabled }
}

public struct Correction: Sendable, Identifiable, Hashable {
    public var id: String
    public var text: String
    public var project: String
    public var date: Date
    public var sessionID: String
}

public struct MemoryNote: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var title: String
    public var folder: String
    public var path: String
    public var modified: Date
    public var words: Int
}

public struct ClutterItem: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var reason: String
    public var bytes: Int64
    public var modified: Date
}

public struct DesignAsset: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var name: String
    public var kind: String
    public var modified: Date
    public var bytes: Int64
}

/// An instruction or memory file an AI reads: CLAUDE.md, AGENTS.md, GEMINI.md, auto-memory notes.
public struct Doc: Sendable, Identifiable, Hashable {
    public var id: String { path }
    public var path: String
    public var title: String
    public var kind: String            // "Rules", "Project rules", "Auto memory"
    public var tool: String
    public var bytes: Int
    public var modified: Date
    public var estimatedTokens: Int { bytes / 4 }
}

/// One line of the live activity log: what an AI just did.
public struct Activity: Sendable, Identifiable, Hashable {
    public var id: String
    public var date: Date
    public var verb: String
    public var target: String
    public var project: String
}
