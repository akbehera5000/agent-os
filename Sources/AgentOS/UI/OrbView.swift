import MetalKit
import SwiftUI

/// The particle brain: a GPU-rendered galaxy whose particles are your skills, memory,
/// sessions and apps. Runs on Metal at the display's refresh rate (120 Hz on ProMotion)
/// and pauses itself when the window is hidden.
struct OrbView: NSViewRepresentable {
    /// Particle counts per pillar, in the order: skills, memory, sessions, apps, high-tier.
    var weights: [Int]
    /// 0 = idle, 1 = thinking / speaking. Speeds up the swirl and brightens the core.
    var energy: Double

    func makeCoordinator() -> OrbRenderer { OrbRenderer() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        // 60 Hz at rest; full ProMotion rate only while Jarvis is thinking or listening.
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        context.coordinator.rebuild(weights: weights)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.targetEnergy = Float(energy)
        context.coordinator.updateRate()
        if context.coordinator.weights != weights { context.coordinator.rebuild(weights: weights) }
    }
}

final class OrbRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()
    private var queue: MTLCommandQueue?
    private var pointPipeline: MTLRenderPipelineState?
    private var linePipeline: MTLRenderPipelineState?
    private var points: MTLBuffer?
    private var lines: MTLBuffer?
    private var pointCount = 0
    private var lineCount = 0
    private let start = CACurrentMediaTime()
    private var energy: Float = 0
    private var spin: Float = 0
    private var last = CACurrentMediaTime()
    var targetEnergy: Float = 0
    var weights: [Int] = []
    private weak var view: MTKView?

    struct Vertex { var pos: SIMD4<Float>; var color: SIMD4<Float> }   // pos.w = size / alpha falloff
    struct Uniforms { var spin: Float; var time: Float; var aspect: Float; var energy: Float; var scale: Float }

    override init() {
        super.init()
        guard let device else { return }
        queue = device.makeCommandQueue()
        do {
            let lib = try device.makeLibrary(source: Self.shader, options: nil)
            pointPipeline = try pipeline(lib, vertex: "pointVertex", fragment: "pointFragment")
            linePipeline = try pipeline(lib, vertex: "lineVertex", fragment: "lineFragment")
        } catch {
            print("Orb shader error: \(error)")
        }
    }

    func attach(_ view: MTKView) {
        self.view = view
        NotificationCenter.default.addObserver(self, selector: #selector(occlusion), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(activity), name: name, object: nil)
        }
    }

    @objc private func activity(_ note: Notification) { updateRate() }

    /// 30 Hz when you're in another app, 60 Hz at rest, full ProMotion while Jarvis works.
    func updateRate() {
        guard let view else { return }
        view.preferredFramesPerSecond = !NSApp.isActive ? 30 : targetEnergy > 0.5 ? (NSScreen.main?.maximumFramesPerSecond ?? 120) : 60
    }

    @objc private func occlusion(_ note: Notification) {
        guard let view, let window = view.window, (note.object as? NSWindow) === window else { return }
        view.isPaused = !window.occlusionState.contains(.visible)
    }

    private func pipeline(_ lib: MTLLibrary, vertex: String, fragment: String) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: vertex)
        d.fragmentFunction = lib.makeFunction(name: fragment)
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.rgbBlendOperation = .add
        c.alphaBlendOperation = .add
        c.sourceRGBBlendFactor = .sourceAlpha
        c.destinationRGBBlendFactor = .one              // additive glow
        c.sourceAlphaBlendFactor = .one
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device!.makeRenderPipelineState(descriptor: d)
    }

    // MARK: Geometry

    func rebuild(weights: [Int]) {
        self.weights = weights
        guard let device else { return }
        var rng = SplitMix(seed: 7)
        let palette: [SIMD4<Float>] = [
            SIMD4(0.98, 0.45, 0.09, 1),   // skills
            SIMD4(0.13, 0.77, 0.37, 1),   // memory
            SIMD4(0.92, 0.70, 0.03, 1),   // sessions / routines
            SIMD4(0.23, 0.51, 0.96, 1),   // apps
            SIMD4(0.66, 0.33, 0.97, 1),   // high tier
        ]
        let w = weights.map { max(1, $0) }
        let total = Float(w.reduce(0, +))
        var verts: [Vertex] = []
        verts.reserveCapacity(26_000)

        // Core: dense warm nebula.
        for _ in 0..<5_000 {
            let r = pow(rng.float(), 2.2) * 0.32
            let p = rng.onSphere() * r
            let heat = 1 - r / 0.32
            verts.append(Vertex(pos: SIMD4(p, 1.2 + heat * 2.2), color: SIMD4(1, 0.72 + heat * 0.25, 0.45 + heat * 0.5, 0.55 + heat * 0.4)))
        }
        // Shell: one cloud per pillar, sized by how much you have of it.
        var anchors: [(SIMD3<Float>, SIMD4<Float>)] = []
        for (i, count) in w.enumerated() {
            let n = Int(14_000 * Float(count) / total) + 400
            let color = palette[i % palette.count]
            // Each pillar gathers around its own region of the sphere.
            let center = rng.onSphere()
            for k in 0..<n {
                var dir = simd_normalize(center * (0.9 + rng.float() * 0.6) + rng.onSphere() * 1.05)
                dir *= 0.78 + rng.gauss() * 0.06
                let jitter = SIMD4<Float>(rng.float() * 0.25, rng.float() * 0.25, rng.float() * 0.25, 0)
                verts.append(Vertex(pos: SIMD4(dir, 1.0 + rng.float() * 2.4), color: color + jitter))
                if k % 28 == 0 { anchors.append((dir, color)) }
            }
        }
        // Dust: faint far particles.
        for _ in 0..<3_500 {
            let p = rng.onSphere() * (1.15 + rng.float() * 1.1)
            verts.append(Vertex(pos: SIMD4(p, 0.6 + rng.float()), color: SIMD4(0.55, 0.6, 0.85, 0.22)))
        }
        pointCount = verts.count
        points = device.makeBuffer(bytes: verts, length: MemoryLayout<Vertex>.stride * verts.count, options: .storageModeShared)

        // Filaments: curved strands from the core to shell anchors, like neurons.
        var seg: [Vertex] = []
        let steps = 14
        for (tip, color) in anchors.prefix(700) {
            let swirl = simd_normalize(simd_cross(tip, SIMD3(0, 1, 0.3))) * (0.25 + rng.float() * 0.25)
            let mid = tip * 0.45 + swirl
            var prev = SIMD3<Float>(repeating: 0)
            for s in 1...steps {
                let t = Float(s) / Float(steps)
                let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
                let p = mid * b + tip * c + SIMD3<Float>(repeating: 0) * a
                let alpha = 0.05 + 0.22 * t
                seg.append(Vertex(pos: SIMD4(prev, t), color: SIMD4(color.x, color.y, color.z, alpha * 0.6)))
                seg.append(Vertex(pos: SIMD4(p, t), color: SIMD4(color.x, color.y, color.z, alpha)))
                prev = p
            }
        }
        lineCount = seg.count
        lines = device.makeBuffer(bytes: seg, length: MemoryLayout<Vertex>.stride * max(1, seg.count), options: .storageModeShared)
    }

    // MARK: Draw

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let queue, let pointPipeline, let linePipeline, let points, let lines,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, now - last))
        last = now
        energy += (targetEnergy - energy) * min(1, dt * 3)
        spin += dt * (0.10 + energy * 0.55)
        let size = view.drawableSize
        var u = Uniforms(spin: spin, time: Float(now - start), aspect: Float(size.width / max(1, size.height)), energy: energy,
                         scale: Float(min(size.width, size.height)) / 900)

        enc.setRenderPipelineState(linePipeline)
        enc.setVertexBuffer(lines, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineCount)

        enc.setRenderPipelineState(pointPipeline)
        enc.setVertexBuffer(points, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pointCount)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 pos; float4 color; };
    struct Uniforms { float spin; float time; float aspect; float energy; float scale; };
    struct Out { float4 position [[position]]; float4 color; float size [[point_size]]; };

    static float3 transform(float3 p, constant Uniforms& u, float wobble) {
        // Gentle breathing and turbulence, stronger when Jarvis is thinking.
        float breathe = 1.0 + 0.025 * sin(u.time * 0.9) + 0.04 * u.energy * sin(u.time * 4.0 + p.y * 6.0);
        p *= breathe;
        p += wobble * 0.012 * float3(sin(u.time * 1.3 + p.y * 9.0), cos(u.time * 1.1 + p.x * 8.0), sin(u.time * 0.7 + p.z * 7.0));
        float c = cos(u.spin), s = sin(u.spin);
        p = float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
        float t = 0.38, ct = cos(t), st = sin(t);
        p = float3(p.x, ct * p.y - st * p.z, st * p.y + ct * p.z);
        return p;
    }

    static float4 project(float3 p, constant Uniforms& u) {
        float cam = 3.0;
        float d = cam - p.z;
        float f = 2.35;
        float2 xy = p.xy * f / d;
        xy.x /= u.aspect;
        return float4(xy, 0.5 - p.z * 0.1, 1.0);
    }

    vertex Out pointVertex(uint id [[vertex_id]], const device Vertex* v [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        float3 p = transform(v[id].pos.xyz, u, 1.0);
        Out o;
        o.position = project(p, u);
        float depth = (p.z + 1.4) / 2.8;
        float twinkle = 0.75 + 0.25 * sin(u.time * 2.0 + float(id) * 0.37);
        o.size = v[id].pos.w * (0.7 + depth * 1.1) * u.scale * (1.0 + u.energy * 0.35) * 2.0;
        o.color = float4(v[id].color.rgb * (0.55 + depth * 0.7) * (1.0 + u.energy * 0.5), v[id].color.a * twinkle);
        return o;
    }

    fragment float4 pointFragment(Out in [[stage_in]], float2 pc [[point_coord]]) {
        float d = length(pc - 0.5) * 2.0;
        float a = exp(-d * d * 4.0);
        if (a < 0.01) discard_fragment();
        return float4(in.color.rgb, in.color.a * a);
    }

    vertex Out lineVertex(uint id [[vertex_id]], const device Vertex* v [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        float3 p = transform(v[id].pos.xyz, u, v[id].pos.w);
        Out o;
        o.position = project(p, u);
        o.size = 1.0;
        float pulse = 0.6 + 0.4 * sin(u.time * 2.2 - v[id].pos.w * 9.0 + float(id / 28) * 0.9);
        o.color = float4(v[id].color.rgb, v[id].color.a * pulse * (1.0 + u.energy));
        return o;
    }

    fragment float4 lineFragment(Out in [[stage_in]]) { return in.color; }
    """
}

/// Deterministic random numbers so the orb keeps its shape between launches.
struct SplitMix {
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
    mutating func gauss() -> Float { sqrt(-2 * log(max(1e-6, float()))) * cos(2 * .pi * float()) }
    mutating func onSphere() -> SIMD3<Float> {
        let z = float() * 2 - 1, a = float() * 2 * .pi, r = sqrt(1 - z * z)
        return SIMD3(r * cos(a), r * sin(a), z)
    }
}
