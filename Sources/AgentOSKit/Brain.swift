import Foundation
import simd

/// The second brain as a galaxy: your AI tools and projects are planets orbiting a central star (you);
/// skills, sessions, docs, connectors and artifacts are moons orbiting their planet.
public struct BrainNode: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case core, tool, project, session, skill, note, doc, connector, artifact
    }
    public var id: String
    public var kind: Kind
    public var label: String
    public var detail: String
    public var path: String?
    public var size: Float
    /// Position at time 0.
    public var pos: SIMD3<Float>
    /// Index of the node this one orbits; nil for the core.
    public var parent: Int?
    /// Orbit: offset from the parent, rotated around `axis` at `omega` radians per second.
    public var offset: SIMD3<Float> = .zero
    public var axis: SIMD3<Float> = SIMD3(0, 1, 0)
    public var omega: Float = 0
}

public struct BrainGraph: Sendable {
    public var nodes: [BrainNode]
    public var edges: [(Int, Int)]
    public static let empty = BrainGraph(nodes: [], edges: [])

    public func count(_ kind: BrainNode.Kind) -> Int { nodes.filter { $0.kind == kind }.count }

    /// Where a node is at time `t` (seconds): its orbit around its parent, plus the parent's own orbit.
    /// The Metal shader runs the same math, so hit-testing matches what is drawn.
    public func position(_ i: Int, at t: Float) -> SIMD3<Float> {
        var p = SIMD3<Float>(repeating: 0)
        var j: Int? = i
        var depth = 0
        while let k = j, depth < 4 {
            let n = nodes[k]
            p += Brain.rotate(n.offset, around: n.axis, by: n.omega * t)
            j = n.parent
            depth += 1
        }
        return p
    }
}

/// How the second brain is drawn. Every style shows the same nodes and links.
public enum BrainStyle: String, CaseIterable, Sendable, Identifiable {
    case galaxy, neural, wormhole, warp, filament, holo, dial, flow, neuron
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .galaxy: "Galaxy"
        case .neural: "Neural"
        case .wormhole: "Black Hole"
        case .warp: "Warp Tunnel"
        case .filament: "Filament Star"
        case .holo: "Holo Globe"
        case .dial: "Radial Dial"
        case .flow: "Synapse Flow"
        case .neuron: "Neuron Burst"
        }
    }
    public var symbol: String {
        switch self {
        case .galaxy: "sparkles"
        case .neural: "brain"
        case .wormhole: "circle.circle.fill"
        case .warp: "hurricane"
        case .filament: "sun.max"
        case .holo: "globe.americas"
        case .dial: "dial.medium"
        case .flow: "point.3.filled.connected.trianglepath.dotted"
        case .neuron: "tree"
        }
    }
}

public enum Brain {
    /// Rodrigues rotation of `v` around unit axis `k`.
    public static func rotate(_ v: SIMD3<Float>, around k: SIMD3<Float>, by a: Float) -> SIMD3<Float> {
        let c = cos(a), s = sin(a)
        return v * c + simd_cross(k, v) * s + k * simd_dot(k, v) * (1 - c)
    }

    /// Builds the graph (who links to whom) and lays it out in the chosen style.
    public static func build(_ s: Snapshot, style: BrainStyle = .galaxy) -> BrainGraph {
        var nodes: [BrainNode] = []
        var edges: [(Int, Int)] = []
        var index: [String: Int] = [:]

        @discardableResult
        func add(_ id: String, _ kind: BrainNode.Kind, _ label: String, _ detail: String, path: String? = nil, size: Float, parent: Int?) -> Int {
            if let i = index[id] { return i }
            let i = nodes.count
            nodes.append(BrainNode(id: id, kind: kind, label: label, detail: detail, path: path, size: size, pos: .zero, parent: parent))
            index[id] = i
            if let parent { edges.append((parent, i)) }
            return i
        }

        let core = add("core", .core, "You", "\(s.tools.count) AI tools · \(s.projects.count) projects", size: 18, parent: nil)
        for t in s.tools {
            add("tool:\(t.id)", .tool, t.name, "\(t.kind) · \(t.sessionCount) sessions · \(t.skillCount) skills",
                path: t.appPath ?? t.configDir, size: 11 + min(4, Float(t.skillCount) / 120), parent: core)
        }
        for p in s.projects {
            add("project:\(p.id)", .project, p.name, "\(p.sessions) sessions · \(p.locations.count) locations",
                path: p.locations.first, size: 8.5 + min(4, Float(p.sessions) / 3), parent: core)
        }
        for n in s.notes { add("note:\(n.path)", .note, n.title, "\(n.folder) · \(n.words) words", path: n.path, size: 5.5, parent: core) }
        let projectByRoot: [String: Int] = Dictionary(s.projects.flatMap { p in p.locations.map { ($0, index["project:\(p.id)"]!) } },
                                                      uniquingKeysWith: { a, _ in a })
        for x in s.sessions.prefix(400) {
            let parent = projectByRoot[TextRules.projectRoot(x.cwd)] ?? index["tool:\(x.tool)"] ?? core
            add("session:\(x.id)", .session, x.title, "\(ToolCatalog.name(x.tool)) · \(x.messages) prompts", path: x.file,
                size: 4 + max(0, min(3, log10(Float(max(1, x.usage.total))) - 4)), parent: parent)
        }
        for k in s.skills {
            add("skill:\(k.id)", .skill, k.name, k.description.isEmpty ? k.source : k.description, path: k.path + "/SKILL.md",
                size: 2.6, parent: index["tool:\(k.tool)"] ?? core)
        }
        for d in s.docs {
            add("doc:\(d.path)", .doc, d.title, "\(d.kind) · ~\(Format.tokens(d.estimatedTokens)) tokens", path: d.path, size: 4.6,
                parent: index["tool:\(d.tool)"] ?? core)
        }
        for c in s.connectors {
            add("connector:\(c.id)", .connector, c.name, "\(ToolCatalog.name(c.tool)) · \(c.health.rawValue)", path: c.configFile, size: 4,
                parent: index["tool:\(c.tool)"] ?? core)
        }
        for a in s.assets.prefix(80) {
            add("artifact:\(a.path)", .artifact, a.name, "\(a.kind) · \(Format.bytes(a.bytes))", path: a.path, size: 3.6,
                parent: projectByRoot.first { a.path.hasPrefix($0.key + "/") }?.value ?? core)
        }
        layout(&nodes, style: style)
        return BrainGraph(nodes: nodes, edges: edges)
    }

    static func rng(_ key: String) -> SplitMix64 {
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return SplitMix64(seed: h)
    }

    /// Each planet's ring plane, tilted up to ~30° from the galactic plane.
    static func ringAxis(_ key: String) -> SIMD3<Float> {
        var r = rng(key + "ring")
        return simd_normalize(SIMD3((r.float() - 0.5) * 1.1, 1, (r.float() - 0.5) * 1.1))
    }

    static func unit(_ key: String) -> SIMD3<Float> {
        var r = rng(key)
        let z = r.float() * 2 - 1, a = r.float() * 2 * .pi, rr = sqrt(max(0, 1 - z * z))
        return SIMD3(rr * cos(a), rr * sin(a), z)
    }

    /// Sets each node's resting position and orbit for a style. Positions are absolute; offsets are relative to the parent.
    static func layout(_ nodes: inout [BrainNode], style: BrainStyle) {
        // Planets: tools, projects and notes. Everything else (including artifacts outside any project) is a leaf.
        let hubKinds: Set<BrainNode.Kind> = [.tool, .project, .note]
        let hubs = nodes.indices.filter { nodes[$0].parent == 0 && hubKinds.contains(nodes[$0].kind) }
        let hubSet = Set(hubs)
        let hubRank = Dictionary(uniqueKeysWithValues: hubs.enumerated().map { ($1, $0) })
        let kindHubs: [BrainNode.Kind: [Int]] = Dictionary(grouping: hubs, by: { nodes[$0].kind })
        func rank(_ i: Int) -> (Int, Int) {
            let k = kindHubs[nodes[i].kind] ?? [i]
            return (k.firstIndex(of: i) ?? 0, max(1, k.count))
        }
        let golden: Float = 2.39996
        var pos = [SIMD3<Float>](repeating: .zero, count: nodes.count)

        // 1. Hubs (tools, projects, notes)
        for i in hubs {
            let n = nodes[i]
            let (k, count) = rank(i)
            let f = Float(k) / Float(max(1, count - 1))
            var r = rng(n.id)
            switch style {
            case .galaxy:
                let radius: Float = n.kind == .tool ? 0.5 + 0.38 * f : n.kind == .project ? 1.0 + 0.62 * f : 0.3 + 0.06 * Float(k % 3)
                let a = Float(k) * golden + (n.kind == .project ? 1.1 : n.kind == .note ? 0.5 : 0)
                pos[i] = SIMD3(cos(a) * radius, (r.float() - 0.5) * 0.08, sin(a) * radius)
            case .neural:
                let a = Float(k) / Float(count) * 2 * .pi + (n.kind == .project ? 0.4 : 0)
                pos[i] = n.kind == .tool ? SIMD3(cos(a) * 0.42, sin(a * 2) * 0.1, sin(a) * 0.42)
                    : n.kind == .project ? SIMD3(cos(a) * 0.72, sin(a) * 0.3, sin(a) * 0.66) : unit(n.id) * 0.9
            case .wormhole:
                let radius: Float = n.kind == .note ? 0.56 : n.kind == .tool ? 0.72 : 0.88
                let a = Float(k) / Float(count) * 2 * .pi + (n.kind == .project ? 0.3 : 0)
                pos[i] = SIMD3(cos(a) * radius, (r.float() - 0.5) * 0.03, sin(a) * radius)
            case .warp:
                let a = Float(hubRank[i] ?? 0) / Float(hubs.count) * 2 * .pi
                pos[i] = SIMD3(cos(a) * 0.42, (r.float() - 0.5) * 0.3, sin(a) * 0.42)
            case .filament, .neuron:
                var d = unit(n.id + "hub")
                if style == .neuron { d.z *= 0.35; d = simd_normalize(d) }
                pos[i] = d * (style == .neuron ? 0.38 : 0.5)
            case .holo:
                let total = Float(hubs.count), idx = Float(hubRank[i] ?? 0)
                let y = 1 - 2 * (idx + 0.5) / total, rr = sqrt(max(0, 1 - y * y)), a = idx * golden
                pos[i] = SIMD3(cos(a) * rr, y, sin(a) * rr) * 1.0
            case .dial:
                let a = Float(hubRank[i] ?? 0) / Float(hubs.count) * 2 * .pi
                pos[i] = SIMD3(cos(a) * 1.55, 0, sin(a) * 1.55)
            case .flow:
                switch n.kind {
                case .tool: pos[i] = SIMD3(-1.75, (f - 0.5) * 1.9, (r.float() - 0.5) * 0.3)
                case .project: pos[i] = SIMD3((r.float() - 0.5) * 0.6, (f - 0.5) * 1.5, (r.float() - 0.5) * 0.5)
                default: pos[i] = SIMD3(-0.3 + r.float() * 0.2, (r.float() - 0.5) * 0.4, 0.3)
                }
            }
        }

        // 2. Moons and leaves, placed relative to their hub
        for i in nodes.indices where i != 0 && !hubSet.contains(i) {
            let n = nodes[i]
            let p = n.parent ?? 0
            var r = rng(n.id)
            // Leaves hanging straight off the core get a virtual anchor in the style's outer region.
            if p == 0 {
                var h = rng(n.id + "anchor")
                let a = h.float() * 2 * .pi
                pos[0] = switch style {
                case .galaxy: SIMD3(cos(a) * 1.85, 0, sin(a) * 1.85)
                case .neural: unit(n.id + "anchor") * 0.72
                case .wormhole: SIMD3(cos(a) * 0.88, 0, sin(a) * 0.88)
                case .warp: SIMD3(cos(a) * 0.42, 0, sin(a) * 0.42)
                case .filament: unit(n.id + "anchor") * 0.5
                case .holo: unit(n.id + "anchor")
                case .dial: SIMD3(cos(a) * 1.55, 0, sin(a) * 1.55)
                case .flow: SIMD3(1.5, (h.float() - 0.5) * 1.8, 0)
                case .neuron: simd_normalize(unit(n.id + "anchor") * SIMD3(1, 1, 0.35)) * 0.38
                }
            }
            defer { pos[0] = .zero }
            let base: Float = switch n.kind {
            case .session: 0.13
            case .skill: 0.2
            case .doc: 0.09
            case .connector: 0.12
            default: 0.16
            }
            switch style {
            case .galaxy:
                // Moons form a thin ring around their planet, tilted per planet like Saturn's rings.
                let axis = ringAxis(nodes[p].id)
                let band: (Float, Float) = switch n.kind {
                case .session: (0.075, 0.1)
                case .doc: (0.065, 0.08)
                case .connector: (0.1, 0.115)
                case .skill: (0.12, 0.2)
                default: (0.2, 0.23)
                }
                let t = simd_normalize(simd_cross(axis, SIMD3(0.3, 0.1, 1)))
                let b = simd_cross(axis, t)
                let a = r.float() * 2 * .pi
                let rad = band.0 + r.float() * (band.1 - band.0)
                pos[i] = pos[p] + (t * cos(a) + b * sin(a)) * rad + axis * (r.float() - 0.5) * 0.008
            case .neural:
                let regions: [BrainNode.Kind: SIMD3<Float>] = [.skill: SIMD3(0.9, 0.5, 0.2), .session: SIMD3(0.1, -0.8, 0.6),
                                                                .doc: SIMD3(-0.6, 0.7, -0.4), .connector: SIMD3(0.5, 0.2, -0.85), .artifact: SIMD3(-0.5, -0.6, -0.6)]
                let toward = simd_normalize(pos[p] == .zero ? (regions[n.kind] ?? unit(n.id)) : pos[p] * 0.6 + simd_normalize(regions[n.kind] ?? unit(n.id)) * 0.4)
                pos[i] = simd_normalize(toward + unit(n.id) * 0.45) * (1.0 + (r.float() - 0.5) * 0.18)
            case .wormhole:
                let band: (Float, Float) = switch n.kind {
                case .session: (1.0, 1.12)
                case .doc: (1.12, 1.2)
                case .connector: (1.2, 1.28)
                case .skill: (1.3, 1.78)
                default: (1.8, 1.95)
                }
                let pa = atan2(pos[p].z, pos[p].x)
                let a = pa + (r.float() - 0.5) * 0.9
                let rad = band.0 + r.float() * (band.1 - band.0)
                pos[i] = SIMD3(cos(a) * rad, (r.float() - 0.5) * 0.05, sin(a) * rad)
            case .filament:
                pos[i] = simd_normalize(simd_normalize(pos[p]) + unit(n.id) * 0.75) * (0.85 + r.float() * 0.55)
            case .neuron:
                var d = simd_normalize(simd_normalize(pos[p]) + unit(n.id) * 0.5)
                d.z *= 0.45
                pos[i] = simd_normalize(d) * (0.75 + pow(r.float(), 0.7) * 0.8)
            case .holo:
                pos[i] = simd_normalize(simd_normalize(pos[p]) + unit(n.id) * 0.35) * (0.93 + r.float() * 0.04)
            case .warp:
                // Streaming outward along the hub's direction, at varying depth like a tunnel.
                let pa = atan2(pos[p].z, pos[p].x)
                let a = pa + (r.float() - 0.5) * 0.35
                let rad = 0.6 + pow(r.float(), 0.8) * 1.35
                pos[i] = SIMD3(cos(a) * rad, (r.float() - 0.5) * 0.9, sin(a) * rad)
            case .dial:
                let band: Float = switch n.kind {
                case .session: 0.62
                case .doc: 0.78
                case .connector: 0.9
                case .skill: 1.05
                default: 1.3
                }
                let pa = atan2(pos[p].z, pos[p].x)
                let a = pa + (r.float() - 0.5) * 0.12
                let rad = band + r.float() * 0.18
                pos[i] = SIMD3(cos(a) * rad, (r.float() - 0.5) * 0.02, sin(a) * rad)
            case .flow:
                if n.kind == .artifact || n.kind == .doc {
                    pos[i] = SIMD3(1.45 + r.float() * 0.35, (r.float() - 0.5) * 1.8, (r.float() - 0.5) * 0.4)
                } else if nodes[p].kind == .tool {
                    // Inputs: a stream fanning out to the left of each source.
                    pos[i] = pos[p] + SIMD3(-0.15 - r.float() * 0.5, (r.float() - 0.5) * 0.18, (r.float() - 0.5) * 0.2)
                } else {
                    pos[i] = pos[p] + simd_normalize(unit(n.id) * SIMD3(1, 1, 0.5)) * base * 1.6
                }
            }
        }

        // 3. Offsets and orbits. Galaxy and wormhole move; the others hold still while the camera drifts.
        for i in nodes.indices {
            let parentPos = nodes[i].parent.map { pos[$0] } ?? .zero
            nodes[i].pos = pos[i]
            nodes[i].offset = pos[i] - parentPos
            nodes[i].axis = SIMD3(0, 1, 0)
            nodes[i].omega = 0
            var r = rng(nodes[i].id + "orbit")
            let dist = max(0.02, simd_length(nodes[i].offset))
            switch style {
            case .galaxy:
                if nodes[i].parent == 0 && hubSet.contains(i) {
                    nodes[i].omega = 0.035 / pow(dist, 1.5)
                } else if let p = nodes[i].parent, nodes[i].kind != .tool, nodes[i].kind != .project, nodes[i].kind != .note {
                    nodes[i].axis = p == 0 ? SIMD3(0, 1, 0) : ringAxis(nodes[p].id)
                    nodes[i].omega = (0.18 + r.float() * 0.08) / sqrt(dist / 0.1)
                }
            case .wormhole:
                if nodes[i].parent == 0 { nodes[i].omega = 0.05 / dist }
            default:
                break
            }
        }
        // Size tweaks so each style reads like its reference.
        for i in nodes.indices {
            switch style {
            case .galaxy:
                switch nodes[i].kind {
                case .skill: nodes[i].size = 1.9
                case .session: nodes[i].size = 3.2
                case .doc, .connector: nodes[i].size = 2.8
                case .artifact: nodes[i].size = 2.6
                case .tool: nodes[i].size = 13
                case .project: nodes[i].size = 10 + min(3, Float(nodes[i].size - 8.5))
                default: break
                }
            case .wormhole: if nodes[i].kind == .core { nodes[i].size = 30 } else if !hubSet.contains(i) { nodes[i].size *= 0.7 }
            case .warp: if nodes[i].kind == .core { nodes[i].size = 26 } else if !hubSet.contains(i) { nodes[i].size *= 0.75 }
            case .filament: if nodes[i].kind == .core { nodes[i].size = 46 } else if nodes[i].parent != 0 { nodes[i].size *= 0.8 }
            case .holo: if nodes[i].kind == .core { nodes[i].size = 8 }
            case .dial: if nodes[i].parent == 0 { nodes[i].size = 9 } else if nodes[i].kind == .core { nodes[i].size = 22 }
            default: break
            }
        }
    }

    /// Screen projection for a camera looking at the origin from `distance` (kept for tests and simple callers).
    /// Returns normalized device coordinates (-1…1) and view-space depth (bigger = closer).
    public static func project(_ p: SIMD3<Float>, yaw: Float, pitch: Float, zoom: Float, aspect: Float) -> (SIMD2<Float>, Float) {
        project(p, target: .zero, yaw: yaw, pitch: pitch, distance: 3 / max(0.01, zoom), aspect: aspect)
    }

    /// Camera orbiting `target` at `distance`. Same math as the shader.
    public static func project(_ p: SIMD3<Float>, target: SIMD3<Float>, yaw: Float, pitch: Float, distance: Float, aspect: Float) -> (SIMD2<Float>, Float) {
        let v = view(p, target: target, yaw: yaw, pitch: pitch)
        let d = max(0.001, distance - v.z)
        var xy = SIMD2(v.x, v.y) * 2.35 / d
        xy.x /= aspect
        return (xy, distance - d)
    }

    public static func view(_ p: SIMD3<Float>, target: SIMD3<Float>, yaw: Float, pitch: Float) -> SIMD3<Float> {
        let r = p - target
        let cy = cos(yaw), sy = sin(yaw)
        let q = SIMD3(cy * r.x + sy * r.z, r.y, -sy * r.x + cy * r.z)
        let cp = cos(pitch), sp = sin(pitch)
        return SIMD3(q.x, cp * q.y - sp * q.z, sp * q.y + cp * q.z)
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func float() -> Float { Float(next() >> 40) / Float(1 << 24) }
}
