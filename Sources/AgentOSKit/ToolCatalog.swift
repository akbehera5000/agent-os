import Foundation

/// Where each AI tool keeps its app, config, skills, connectors and instructions.
public struct ToolSpec: Sendable {
    public enum MCPFormat: Sendable { case jsonKey(String), claudeJSON, codexTOML }

    public var id: String
    public var name: String
    public var kind: String
    public var apps: [String]          // absolute .app paths
    public var configDir: String?      // relative to home
    public var skillDirs: [String]     // relative to home
    public var mcp: [(path: String, format: MCPFormat)]
    public var instructions: String?   // relative to home
    public var symbol: String
    public var hue: Double
}

public enum ToolCatalog {
    public static let all: [ToolSpec] = [
        ToolSpec(id: "claude-code", name: "Claude Code", kind: "CLI", apps: [], configDir: ".claude",
                 skillDirs: [".claude/skills"], mcp: [(".claude.json", .claudeJSON)],
                 instructions: ".claude/CLAUDE.md", symbol: "terminal", hue: 0.06),
        ToolSpec(id: "claude-desktop", name: "Claude", kind: "Desktop app", apps: ["/Applications/Claude.app"],
                 configDir: "Library/Application Support/Claude", skillDirs: [],
                 mcp: [("Library/Application Support/Claude/claude_desktop_config.json", .jsonKey("mcpServers"))],
                 instructions: nil, symbol: "sparkle", hue: 0.05),
        ToolSpec(id: "codex", name: "Codex", kind: "CLI + app", apps: ["/Applications/Codex.app"], configDir: ".codex",
                 skillDirs: [".codex/skills"], mcp: [(".codex/config.toml", .codexTOML)],
                 instructions: ".codex/AGENTS.md", symbol: "chevron.left.forwardslash.chevron.right", hue: 0.0),
        ToolSpec(id: "chatgpt", name: "ChatGPT", kind: "Desktop app", apps: ["/Applications/ChatGPT.app"],
                 configDir: nil, skillDirs: [], mcp: [], instructions: nil, symbol: "bubble.left.and.text.bubble.right", hue: 0.45),
        ToolSpec(id: "gemini", name: "Gemini", kind: "CLI + app", apps: ["/Applications/Gemini.app"], configDir: ".gemini",
                 skillDirs: [".gemini/skills"], mcp: [(".gemini/settings.json", .jsonKey("mcpServers"))],
                 instructions: ".gemini/GEMINI.md", symbol: "diamond", hue: 0.6),
        ToolSpec(id: "antigravity", name: "Antigravity", kind: "IDE", apps: ["/Applications/Antigravity IDE.app"],
                 configDir: ".gemini/antigravity", skillDirs: [], mcp: [], instructions: nil, symbol: "atom", hue: 0.55),
        ToolSpec(id: "copilot", name: "GitHub Copilot", kind: "Desktop app", apps: ["/Applications/GitHub Copilot.app"],
                 configDir: ".copilot", skillDirs: [".copilot/skills"], mcp: [(".copilot/mcp-config.json", .jsonKey("mcpServers"))],
                 instructions: ".copilot/copilot-instructions.md", symbol: "airplane", hue: 0.75),
        ToolSpec(id: "opencode", name: "OpenCode", kind: "CLI", apps: [], configDir: ".config/opencode",
                 skillDirs: [".config/opencode/skills"], mcp: [(".config/opencode/opencode.json", .jsonKey("mcp"))],
                 instructions: ".config/opencode/AGENTS.md", symbol: "curlybraces", hue: 0.3),
        ToolSpec(id: "qwen", name: "Qwen Code", kind: "CLI", apps: [], configDir: ".qwen",
                 skillDirs: [".qwen/skills"], mcp: [(".qwen/settings.json", .jsonKey("mcpServers"))],
                 instructions: ".qwen/QWEN.md", symbol: "q.circle", hue: 0.7),
        ToolSpec(id: "shared", name: "Shared agents", kind: "Skill library", apps: [], configDir: ".agents",
                 skillDirs: [".agents/skills"], mcp: [], instructions: nil, symbol: "square.stack.3d.up", hue: 0.15),
        ToolSpec(id: "ollama", name: "Ollama", kind: "Local models", apps: ["/Applications/Ollama.app"], configDir: ".ollama",
                 skillDirs: [], mcp: [], instructions: nil, symbol: "cpu", hue: 0.35),
    ]

    public static func spec(_ id: String) -> ToolSpec? { all.first { $0.id == id } }
    public static func name(_ id: String) -> String { spec(id)?.name ?? id }
    /// Tools whose skills folder Agent OS can install into.
    public static var skillTargets: [ToolSpec] { all.filter { !$0.skillDirs.isEmpty } }
    /// Instruction files that receive rules from the corrections inbox.
    public static var ruleTargets: [ToolSpec] { all.filter { $0.instructions != nil } }
}
