import AgentOSKit
import MetalKit
import SwiftUI

/// Commands from SwiftUI buttons to the renderer (zoom, reset, fly to the selection).
@Observable
final class BrainControl {
    fileprivate weak var renderer: BrainRenderer?
    var zoomLabel = "1.0×"
    func zoom(_ steps: Float) { renderer?.zoomBy(steps * 0.35) }
    func reset() { renderer?.resetCamera() }
    func focusSelected() { renderer?.focusSelected() }
}

/// The interactive second brain as a galaxy: tools and projects are planets orbiting you,
/// skills, sessions, docs and artifacts are moons orbiting them. Drag to orbit the camera,
/// scroll or pinch to zoom from the whole galaxy down to a single moon, hover to identify,
/// click to inspect, double-click to fly to a planet and follow it.
struct BrainView: NSViewRepresentable {
    var graph: BrainGraph
    var selected: Int?
    var highlight: Set<Int>?
    var energy: Double = 0
    var compact = false
    var control: BrainControl?
    var style: BrainStyle = .galaxy
    var onSelect: (Int?) -> Void

    func makeCoordinator() -> BrainRenderer { BrainRenderer() }

    func makeNSView(context: Context) -> BrainMTKView {
        let view = BrainMTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.preferredFramesPerSecond = 60
        view.renderer = context.coordinator
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ view: BrainMTKView, context: Context) {
        let r = context.coordinator
        r.onSelect = onSelect
        r.compact = compact
        r.targetEnergy = Float(energy)
        if r.style != style { r.setStyle(style) }
        control?.renderer = r
        r.control = control
        if r.graphSignature != signature { r.load(graph); r.graphSignature = signature }
        r.selected = selected
        if r.highlight != highlight { r.highlight = highlight; r.uploadNodes() }
        r.updateRate()
    }

    private var signature: String { "\(style.rawValue)-\(graph.nodes.count)-\(graph.edges.count)-\(graph.nodes.last?.id ?? "")-\(graph.nodes.last?.pos.x ?? 0)" }
}

/// MTKView that turns mouse and trackpad input into camera orbit, zoom, hover, click and double-click.
final class BrainMTKView: MTKView {
    weak var renderer: BrainRenderer?
    private var dragStart: NSPoint?
    private var dragged = false
    private var tracking: NSTrackingArea?
    let labels = LabelLayerView()

    override var acceptsFirstResponder: Bool { true }

    /// Lets clicks through to SwiftUI panels drawn on top (inspector, Jarvis, search).
    private func blocked(_ windowPoint: NSPoint) -> Bool {
        guard let content = window?.contentView else { return false }
        let p = content.convert(windowPoint, from: nil)
        return OverlayZones.covers(CGPoint(x: p.x, y: content.isFlipped ? p.y : content.bounds.height - p.y))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let sv = superview else { return super.hitTest(point) }
        if blocked(sv.convert(point, to: nil)) { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if labels.superview == nil {
            labels.frame = bounds
            labels.autoresizingMask = [.width, .height]
            addSubview(labels)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseMoved(with event: NSEvent) {
        if blocked(event.locationInWindow) {
            renderer?.hovered = nil
            return
        }
        renderer?.hover(at: convert(event.locationInWindow, from: nil), in: bounds.size)
        (renderer?.hovered != nil ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    override func mouseExited(with event: NSEvent) {
        renderer?.hovered = nil
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = convert(event.locationInWindow, from: nil)
        dragged = false
        renderer?.grab()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let s = dragStart, hypot(p.x - s.x, p.y - s.y) > 3 { dragged = true }
        renderer?.drag(dx: Float(event.deltaX), dy: Float(event.deltaY))
        NSCursor.closedHand.set()
    }

    override func mouseUp(with event: NSEvent) {
        renderer?.release()
        if !dragged {
            let p = convert(event.locationInWindow, from: nil)
            renderer?.hover(at: p, in: bounds.size)
            if event.clickCount >= 2 { renderer?.focusHovered() } else { renderer?.click() }
        }
        dragStart = nil
        NSCursor.arrow.set()
    }

    override func scrollWheel(with event: NSEvent) {
        renderer?.zoomBy(Float(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.006 : 0.06))
    }

    override func magnify(with event: NSEvent) {
        renderer?.zoomBy(Float(event.magnification) * 1.6)
    }
}

/// Node labels and the hover card, drawn with Core Graphics and always kept inside the view.
final class LabelLayerView: NSView {
    struct Label { var text: String; var detail: String?; var point: CGPoint; var color: NSColor; var alpha: CGFloat; var strong: Bool }
    var items: [Label] = [] { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func fit(_ s: String, _ attrs: [NSAttributedString.Key: Any], _ width: CGFloat) -> NSAttributedString {
        var text = s
        var a = NSAttributedString(string: text, attributes: attrs)
        while a.size().width > width && text.count > 4 {
            text = String(text.dropLast(2))
            a = NSAttributedString(string: text + "…", attributes: attrs)
        }
        return a
    }

    override func draw(_ dirtyRect: NSRect) {
        let w = bounds.width, h = bounds.height
        for l in items {
            if l.strong {
                let titleAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
                                                                 .foregroundColor: NSColor.white]
                let detailAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular),
                                                                  .foregroundColor: NSColor.white.withAlphaComponent(0.65)]
                let maxText = min(340, w - 32)
                let title = fit(l.text, titleAttrs, maxText)
                let detail = fit(l.detail ?? "", detailAttrs, maxText)
                let cw = max(title.size().width, detail.size().width) + 20
                // Prefer right of the point; flip left, then clamp so the card never leaves the view.
                var x = l.point.x + 16
                if x + cw > w - 6 { x = l.point.x - 16 - cw }
                x = min(max(6, x), w - cw - 6)
                let y = min(max(6, l.point.y - 20), h - 46)
                let rect = CGRect(x: x, y: y, width: cw, height: 40)
                let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
                NSColor(calibratedRed: 0.03, green: 0.03, blue: 0.06, alpha: 0.94).setFill()
                path.fill()
                l.color.withAlphaComponent(0.85).setStroke()
                path.lineWidth = 1
                path.stroke()
                title.draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 21))
                detail.draw(at: CGPoint(x: rect.minX + 10, y: rect.minY + 6))
                continue
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(l.alpha)]
            let text = fit(l.text, attrs, 180)
            let size = text.size()
            var origin = CGPoint(x: l.point.x + 9, y: l.point.y - 6)
            if origin.x + size.width > w - 4 { origin.x = l.point.x - 9 - size.width }
            origin.x = min(max(4, origin.x), w - size.width - 4)
            origin.y = min(max(4, origin.y), h - 16)
            text.draw(at: origin)
        }
    }
}

final class BrainRenderer: NSObject, MTKViewDelegate {
    let device = MTLCreateSystemDefaultDevice()
    private var queue: MTLCommandQueue?
    private var planetPipeline: MTLRenderPipelineState?
    private var linePipeline: MTLRenderPipelineState?
    private var orbitPipeline: MTLRenderPipelineState?
    private var dustPipeline: MTLRenderPipelineState?
    private var streakPipeline: MTLRenderPipelineState?
    private var streakBuffer: MTLBuffer?
    private var streakCount = 0
    private var nodeBuffer: MTLBuffer?
    private var edgeBuffer: MTLBuffer?
    private var orbitBuffer: MTLBuffer?
    private var dustBuffer: MTLBuffer?
    private var nodeCount = 0, edgeCount = 0, orbitCount = 0, dustCount = 0
    private weak var view: BrainMTKView?
    weak var control: BrainControl?

    var graph = BrainGraph.empty
    var graphSignature = ""
    var selected: Int?
    var hovered: Int?
    var highlight: Set<Int>?
    var compact = false
    var targetEnergy: Float = 0
    var onSelect: ((Int?) -> Void)?
    private(set) var style: BrainStyle = .galaxy

    // Camera: orbits `target` at `distance`; goals are eased toward each frame.
    private var yaw: Float = 0.5, pitch: Float = 0.55
    private var distance: Float = 3.1, distanceGoal: Float = 3.1
    private var target = SIMD3<Float>(repeating: 0)
    private var follow: Int?
    private var vYaw: Float = 0, vPitch: Float = 0
    private var holding = false
    private var lastInput = CACurrentMediaTime() - 10
    private var energy: Float = 0
    private let start = CACurrentMediaTime()
    private var last = CACurrentMediaTime()
    private var labelTick = 0
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private static let defaultDistance: Float = 3.1

    struct GPUNode { var offset: SIMD4<Float>; var axis: SIMD4<Float>; var color: SIMD4<Float>; var meta: SIMD4<Float> }
    struct LineVertex { var info: SIMD4<Float> }
    struct Dust { var polar: SIMD4<Float>; var color: SIMD4<Float> }
    struct Uniforms {
        var target: SIMD4<Float>
        var yaw: Float; var pitch: Float; var distance: Float; var aspect: Float
        var time: Float; var energy: Float; var scale: Float; var dim: Float
        var selected: Float; var hovered: Float; var pad0: Float = 0; var pad1: Float = 0
    }

    static func kindIndex(_ k: BrainNode.Kind) -> Float { Float(BrainNode.Kind.allCases.firstIndex(of: k) ?? 0) }

    static func color(_ kind: BrainNode.Kind) -> SIMD4<Float> {
        switch kind {
        case .core: SIMD4(1, 0.82, 0.55, 1)
        case .tool: SIMD4(0.3, 0.58, 1, 1)
        case .project: SIMD4(0.25, 0.88, 0.95, 1)
        case .session: SIMD4(0.98, 0.76, 0.16, 1)
        case .skill: SIMD4(1, 0.5, 0.15, 1)
        case .note: SIMD4(0.25, 0.9, 0.5, 1)
        case .doc: SIMD4(0.6, 0.98, 0.65, 1)
        case .connector: SIMD4(0.74, 0.45, 1, 1)
        case .artifact: SIMD4(1, 0.4, 0.65, 1)
        }
    }

    static func nsColor(_ kind: BrainNode.Kind) -> NSColor {
        let c = color(kind)
        return NSColor(calibratedRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
    }

    override init() {
        super.init()
        guard let device else { return }
        queue = device.makeCommandQueue()
        do {
            let lib = try device.makeLibrary(source: Self.shader, options: nil)
            planetPipeline = try pipeline(lib, "planetVertex", "planetFragment", additive: false)
            linePipeline = try pipeline(lib, "lineVertex", "lineFragment", additive: true)
            orbitPipeline = try pipeline(lib, "orbitVertex", "lineFragment", additive: true)
            dustPipeline = try pipeline(lib, "dustVertex", "dustFragment", additive: true)
            streakPipeline = try pipeline(lib, "dustVertex", "lineFragment", additive: true)
        } catch {
            print("Galaxy shader error: \(error)")
        }
        buildDust()
    }

    /// Camera framing, idle drift and stardust for each style.
    private static func camera(_ s: BrainStyle) -> (yaw: Float, pitch: Float, distance: Float, spin: Float) {
        switch s {
        case .galaxy: (0.5, 0.55, 3.1, 0.025)
        case .neural: (0.6, 0.32, 3.0, 0.1)
        case .wormhole: (0, 0.26, 2.35, 0)
        case .warp: (0, 1.45, 2.6, 0)
        case .filament: (0.4, 0.25, 3.2, 0.08)
        case .holo: (0.3, 0.3, 3.6, 0.15)
        case .dial: (0, 0.95, 4.5, 0.04)
        case .flow: (0, 0.05, 4.2, 0)
        case .neuron: (0, 0.1, 3.4, 0.05)
        }
    }

    func setStyle(_ s: BrainStyle) {
        style = s
        let c = Self.camera(s)
        yaw = c.yaw; pitch = c.pitch
        distanceGoal = c.distance
        follow = nil
        buildDust()
        lastInput = CACurrentMediaTime()
        updateRate()
    }

    func attach(_ view: BrainMTKView) {
        self.view = view
        NotificationCenter.default.addObserver(self, selector: #selector(occlusion), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        for n in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(activity), name: n, object: nil)
        }
    }

    @objc private func occlusion(_ note: Notification) {
        guard let view, let w = view.window, (note.object as? NSWindow) === w else { return }
        view.isPaused = !w.occlusionState.contains(.visible)
    }

    @objc private func activity(_ note: Notification) { updateRate() }

    /// 30 Hz in the background, 60 at rest, full ProMotion while you move the camera or Jarvis works.
    func updateRate() {
        guard let view else { return }
        let busy = targetEnergy > 0.5 || holding || CACurrentMediaTime() - lastInput < 2 || abs(distance - distanceGoal) > 0.01
        let cap = UserDefaults.standard.object(forKey: "render.maxFPS") as? Int ?? 120
        view.preferredFramesPerSecond = min(cap, !NSApp.isActive ? 30 : busy ? (NSScreen.main?.maximumFramesPerSecond ?? 120) : 60)
    }

    private func pipeline(_ lib: MTLLibrary, _ v: String, _ f: String, additive: Bool) throws -> MTLRenderPipelineState {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = lib.makeFunction(name: v)
        d.fragmentFunction = lib.makeFunction(name: f)
        let c = d.colorAttachments[0]!
        c.pixelFormat = .bgra8Unorm
        c.isBlendingEnabled = true
        c.sourceRGBBlendFactor = .sourceAlpha
        c.destinationRGBBlendFactor = additive ? .one : .oneMinusSourceAlpha
        c.sourceAlphaBlendFactor = .one
        c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try device!.makeRenderPipelineState(descriptor: d)
    }

    // MARK: Data

    /// Background particles for the current style, stored as (radius, angle, height) around the vertical axis.
    private func buildDust() {
        guard let device else { return }
        var dust: [Dust] = []
        var streaks: [Dust] = []
        var rng = SplitMix(seed: 2026)
        func add(_ p: SIMD3<Float>, _ size: Float, _ c: SIMD4<Float>) {
            dust.append(Dust(polar: SIMD4(simd_length(SIMD2(p.x, p.z)), atan2(p.z, p.x), p.y, size), color: c))
        }
        func stars(_ n: Int, _ alpha: Float) {
            for _ in 0..<n { add(rng.onSphere() * (2.8 + rng.float() * 2.5), 0.8, SIMD4(0.7, 0.75, 1, alpha)) }
        }
        switch style {
        case .galaxy:
            for _ in 0..<9_000 {
                let arm = Float(Int(rng.float() * 2))
                let r = 0.15 + pow(rng.float(), 0.7) * 2.6
                let th = arm * .pi + log(r + 0.2) * 2.6 + rng.gauss() * 0.28
                let t = min(1, r / 2.6)
                add(SIMD3(cos(th) * r, rng.gauss() * 0.04 * (1.2 - t), sin(th) * r), 0.8 + rng.float() * 1.6,
                    SIMD4(0.75 - t * 0.35 + rng.float() * 0.15, 0.55 + rng.float() * 0.2, 0.85 + t * 0.15, 0.5 + rng.float() * 0.35))
            }
            for _ in 0..<2_500 { add(rng.onSphere() * pow(rng.float(), 2.5) * 0.35 * SIMD3(1, 0.3, 1), 1 + rng.float() * 2, SIMD4(1, 0.8, 0.55, 0.5)) }
            stars(1_500, 0.15)
        case .neural:
            for _ in 0..<2_600 {
                let r = pow(rng.float(), 2.6) * 0.3, heat = 1 - r / 0.3
                add(rng.onSphere() * r, 1 + heat * 2, SIMD4(1, 0.75 + heat * 0.2, 0.5 + heat * 0.45, 0.35 + heat * 0.4))
            }
            for _ in 0..<5_000 { add(rng.onSphere() * (1.22 + rng.gauss() * 0.04), 0.8 + rng.float(), SIMD4(0.55, 0.62, 1, 0.24)) }
            stars(1_800, 0.12)
        case .wormhole:
            // Accretion disk: white-hot at the event horizon, burning orange, cooling to violet and blue.
            for _ in 0..<18_000 {
                let r = 0.62 + pow(rng.float(), 1.8) * 1.9
                let t = min(1, (r - 0.62) / 1.9)
                let th = rng.float() * 2 * .pi
                let c: SIMD4<Float> = t < 0.12 ? SIMD4(1, 0.95, 0.85, 0.9)
                    : t < 0.35 ? SIMD4(1, 0.7 - t * 0.6, 0.4 - t * 0.6, 0.75)
                    : t < 0.65 ? SIMD4(0.85, 0.35, 0.35 + t * 0.3, 0.5)
                    : SIMD4(0.35, 0.45 + rng.float() * 0.2, 0.95, 0.4)
                add(SIMD3(cos(th) * r, rng.gauss() * 0.012 * (1 + t * 3), sin(th) * r), 1.6 + rng.float() * 2.2, SIMD4(c.x, c.y, c.z, min(1, c.w * 1.25)))
            }
            // Lensed photon ring (marked with a negative size so the shader draws it facing the camera).
            for _ in 0..<5_000 {
                let r = 0.6 + abs(rng.gauss()) * 0.11
                dust.append(Dust(polar: SIMD4(r, rng.float() * 2 * .pi, 0, -(1.6 + rng.float() * 2.2)),
                                 color: SIMD4(1, 0.85 + rng.float() * 0.12, 0.65, 1)))
            }
            stars(2_200, 0.18)
        case .warp:
            // Light streaks rushing outward from a white-hot center (drawn as lines).
            for _ in 0..<7_000 {
                let th = rng.float() * 2 * .pi
                let r0 = 0.08 + pow(rng.float(), 0.9) * 1.9
                let len = 0.05 + r0 * (0.2 + rng.float() * 0.35)
                let y = rng.gauss() * 0.35
                let bright = max(0.12, 0.6 - r0 * 0.22)
                let c = SIMD4<Float>(0.65 + rng.float() * 0.3, 0.78 + rng.float() * 0.15, 0.92, bright)
                streaks.append(Dust(polar: SIMD4(r0, th, y, 1), color: c))
                streaks.append(Dust(polar: SIMD4(r0 + len, th + 0.01, y * 1.15, 1), color: SIMD4(c.x, c.y, c.z, 0)))
            }
            for _ in 0..<3_000 {
                let r = pow(rng.float(), 3) * 0.3
                add(rng.onSphere() * r, 1 + rng.float() * 3, SIMD4(1, 1, 1, 0.5 * (1 - r / 0.3)))
            }
            stars(1_200, 0.12)
        case .filament:
            for _ in 0..<3_500 { add(rng.onSphere() * (0.36 + rng.float() * 0.12), 1 + rng.float() * 2, SIMD4(1, 0.8, 0.65, 0.35)) }
            for _ in 0..<2_000 { add(rng.onSphere() * (0.6 + rng.float() * 1.0), 0.8, SIMD4(0.8, 0.82, 1, 0.18)) }
            stars(1_200, 0.12)
        case .holo:
            // A dotted globe: latitude rings, an outer dotted shell and a particle stream.
            for lat in stride(from: -80, through: 80, by: 8) {
                let phi = Float(lat) * .pi / 180
                let count = Int(120 * cos(phi)) + 8
                for k in 0..<count {
                    let th = Float(k) / Float(count) * 2 * .pi
                    add(SIMD3(cos(phi) * cos(th), sin(phi), cos(phi) * sin(th)) * 0.9, 2.0, SIMD4(0.3, 0.7, 1, 0.75))
                }
            }
            for k in 0..<900 {
                let th = Float(k) / 900 * 2 * .pi
                add(SIMD3(cos(th) * 1.45, sin(th * 3) * 0.04 + 0.9, sin(th) * 1.45), 1, SIMD4(0.6, 0.75, 1, 0.35))
                add(SIMD3(cos(th) * 1.45, sin(th * 3) * 0.04 - 0.9, sin(th) * 1.45), 1, SIMD4(0.6, 0.75, 1, 0.35))
            }
            for _ in 0..<3_000 {
                let t = rng.float()
                let th = t * 4.5 + 2.2
                let r = 1.0 + t * 0.6
                add(SIMD3(cos(th) * r, -0.55 - t * 0.5 + rng.gauss() * 0.06, sin(th) * r), 1 + rng.float() * 1.5, SIMD4(0.2, 0.9, 1, 0.5 * (1 - t)))
            }
            stars(1_500, 0.15)
        case .dial:
            for ring in [0.42, 0.5, 1.42, 1.72] as [Float] {
                let count = Int(ring * 260)
                for k in 0..<count {
                    let th = Float(k) / Float(count) * 2 * .pi
                    add(SIMD3(cos(th) * ring, 0, sin(th) * ring), ring > 1.6 ? 0.9 : 1.3, ring > 1 ? SIMD4(0.95, 0.8, 0.7, 0.45) : SIMD4(0.4, 0.95, 0.85, 0.5))
                }
            }
            stars(1_200, 0.1)
        case .flow:
            for _ in 0..<5_000 {
                let x = -2.4 + rng.float() * 1.8
                let band = Float(Int(rng.float() * 7)) / 6 - 0.5
                add(SIMD3(x, band * 1.8 + rng.gauss() * 0.04, rng.gauss() * 0.08), 0.9 + rng.float(), SIMD4(0.7, 0.8, 1, 0.35))
            }
            stars(1_500, 0.12)
        case .neuron:
            stars(2_500, 0.14)
        }
        dustCount = dust.count
        dustBuffer = device.makeBuffer(bytes: dust, length: MemoryLayout<Dust>.stride * dust.count, options: .storageModeShared)
        streakCount = streaks.count
        streakBuffer = streaks.isEmpty ? nil : device.makeBuffer(bytes: streaks, length: MemoryLayout<Dust>.stride * streaks.count, options: .storageModeShared)
    }

    func load(_ g: BrainGraph) {
        graph = g
        guard let device, !g.nodes.isEmpty else { nodeCount = 0; edgeCount = 0; orbitCount = 0; return }
        uploadNodes()
        var lines: [LineVertex] = []
        for (a, b) in g.edges {
            let steps = 10
            for s in 0..<steps {
                lines.append(LineVertex(info: SIMD4(Float(a), Float(b), Float(s) / Float(steps), 0)))
                lines.append(LineVertex(info: SIMD4(Float(a), Float(b), Float(s + 1) / Float(steps), 0)))
            }
        }
        edgeCount = lines.count
        edgeBuffer = device.makeBuffer(bytes: lines, length: MemoryLayout<LineVertex>.stride * max(1, lines.count), options: .storageModeShared)
        // Orbit paths for every planet around the star.
        var orbits: [LineVertex] = []
        let seg = 128
        for (i, n) in g.nodes.enumerated() where n.parent == 0 && (n.kind == .tool || n.kind == .project) {
            for s in 0..<seg {
                orbits.append(LineVertex(info: SIMD4(Float(i), Float(s) / Float(seg) * 2 * .pi, 0, 0)))
                orbits.append(LineVertex(info: SIMD4(Float(i), Float(s + 1) / Float(seg) * 2 * .pi, 0, 0)))
            }
        }
        orbitCount = orbits.count
        orbitBuffer = device.makeBuffer(bytes: orbits, length: MemoryLayout<LineVertex>.stride * max(1, orbits.count), options: .storageModeShared)
    }

    func uploadNodes() {
        guard let device, !graph.nodes.isEmpty else { return }
        let gpu = graph.nodes.enumerated().map { i, n in
            GPUNode(offset: SIMD4(n.offset, n.size), axis: SIMD4(n.axis, n.omega), color: Self.color(n.kind),
                    meta: SIMD4(Float(n.parent ?? -1), Self.kindIndex(n.kind), highlight?.contains(i) == true ? 1 : 0, 0))
        }
        nodeCount = gpu.count
        nodeBuffer = device.makeBuffer(bytes: gpu, length: MemoryLayout<GPUNode>.stride * gpu.count, options: .storageModeShared)
    }

    // MARK: Camera and input

    private var now: Float { reduceMotion ? 0 : Float(CACurrentMediaTime() - start) }

    func grab() { holding = true; vYaw = 0; vPitch = 0; lastInput = CACurrentMediaTime(); updateRate() }
    func release() { holding = false; lastInput = CACurrentMediaTime() }

    func drag(dx: Float, dy: Float) {
        let k: Float = 0.006
        yaw += dx * k
        pitch = min(1.45, max(-1.45, pitch + dy * k))
        vYaw = dx * k * 60
        vPitch = dy * k * 60
        lastInput = CACurrentMediaTime()
    }

    /// Exponential zoom: from the whole galaxy (distance 12) down to a single moon (0.12).
    func zoomBy(_ d: Float) {
        distanceGoal = min(12, max(0.12, distanceGoal * exp(-d)))
        lastInput = CACurrentMediaTime()
        updateRate()
    }

    func resetCamera() {
        follow = nil
        let c = Self.camera(style)
        distanceGoal = c.distance
        yaw = c.yaw; pitch = c.pitch
        lastInput = CACurrentMediaTime()
        updateRate()
    }

    func focusHovered() {
        guard let h = hovered else { return }
        onSelect?(h)
        focus(h)
    }

    func focusSelected() { if let s = selected { focus(s) } }

    /// Flies the camera to a node and keeps following it along its orbit.
    func focus(_ i: Int) {
        guard graph.nodes.indices.contains(i) else { return }
        follow = i
        let n = graph.nodes[i]
        distanceGoal = n.kind == .core ? 1.6 : (n.parent == 0 ? 0.75 : 0.32)
        lastInput = CACurrentMediaTime()
        updateRate()
    }

    private func screen(_ p: SIMD3<Float>, _ size: CGSize) -> (CGPoint, Float) {
        let (ndc, depth) = Brain.project(p, target: target, yaw: yaw, pitch: pitch, distance: distance, aspect: Float(size.width / size.height))
        return (CGPoint(x: CGFloat(ndc.x + 1) / 2 * size.width, y: CGFloat(ndc.y + 1) / 2 * size.height), distance - depth)
    }

    func hover(at p: CGPoint, in size: CGSize) {
        guard !graph.nodes.isEmpty, size.width > 0 else { hovered = nil; return }
        let t = now
        let scale = Float(view?.window?.backingScaleFactor ?? 2)
        var best: (Int, CGFloat)?
        for i in graph.nodes.indices {
            let (sp, d) = screen(graph.position(i, at: t), size)
            guard d > 0.05 else { continue }
            let radius = CGFloat(min(240, graph.nodes[i].size * scale * 5.5 / d) / scale) * 0.5
            let dist = hypot(sp.x - p.x, sp.y - p.y)
            let reach = max(7, radius * 0.75)
            let score = dist / reach - CGFloat(1 / d) * 0.05
            if dist < reach, best == nil || score < best!.1 { best = (i, score) }
        }
        hovered = best?.0
    }

    func click() { onSelect?(hovered) }

    // MARK: Draw

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let queue, let planetPipeline, let linePipeline, let orbitPipeline, let dustPipeline, let dustBuffer,
              let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        let wall = CACurrentMediaTime()
        let dt = Float(min(0.05, wall - last))
        last = wall
        energy += (targetEnergy - energy) * min(1, dt * 3)
        if !holding {
            let spin = Self.camera(style).spin
            yaw += vYaw * dt
            pitch = min(1.45, max(-1.45, pitch + vPitch * dt))
            vYaw *= pow(0.05, dt)
            vPitch *= pow(0.05, dt)
            if wall - lastInput > 3 && follow == nil && !reduceMotion { yaw += dt * spin }
        }
        // Ease the camera toward its goals; follow a focused planet along its orbit.
        let goal = follow.map { graph.nodes.indices.contains($0) ? graph.position($0, at: now) : .zero } ?? .zero
        target += (goal - target) * min(1, dt * 4)
        distance += (distanceGoal - distance) * min(1, dt * 5)
        let size = view.drawableSize
        let scale = Float(view.window?.backingScaleFactor ?? 2)
        var u = Uniforms(target: SIMD4(target, 0), yaw: yaw, pitch: pitch, distance: distance, aspect: Float(size.width / max(1, size.height)),
                         time: now, energy: energy, scale: scale * (compact ? 0.85 : 1), dim: highlight == nil ? 0 : 1,
                         selected: Float(selected ?? -1), hovered: Float(hovered ?? -1),
                         pad0: Float(BrainStyle.allCases.firstIndex(of: style) ?? 0))

        enc.setRenderPipelineState(dustPipeline)
        enc.setVertexBuffer(dustBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
        enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: dustCount)
        if streakCount > 0, let streakBuffer, let streakPipeline {
            enc.setRenderPipelineState(streakPipeline)
            enc.setVertexBuffer(streakBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: streakCount)
        }

        if nodeCount > 0, let nodeBuffer {
            if orbitCount > 0, let orbitBuffer, [.galaxy, .wormhole, .dial].contains(style) {
                enc.setRenderPipelineState(orbitPipeline)
                enc.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setVertexBuffer(orbitBuffer, offset: 0, index: 2)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: orbitCount)
            }
            if edgeCount > 0, let edgeBuffer {
                enc.setRenderPipelineState(linePipeline)
                enc.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
                enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
                enc.setVertexBuffer(edgeBuffer, offset: 0, index: 2)
                enc.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeCount)
            }
            enc.setRenderPipelineState(planetPipeline)
            enc.setVertexBuffer(nodeBuffer, offset: 0, index: 0)
            enc.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 1)
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: nodeCount)
        }
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()

        labelTick += 1
        if labelTick % 2 == 0, let v = view as? BrainMTKView { updateLabels(v) }
        if labelTick % 15 == 0 { control?.zoomLabel = String(format: "%.1f×", Self.camera(style).distance / distance) }
    }

    /// Planets get labels; when you zoom in, nearby moons do too. Labels behind the camera are skipped.
    private func updateLabels(_ view: BrainMTKView) {
        let size = view.bounds.size
        guard size.width > 0, !graph.nodes.isEmpty else { view.labels.items = []; return }
        let t = now
        var items: [LabelLayerView.Label] = []
        if !compact && (UserDefaults.standard.object(forKey: "brain.labels") as? Bool ?? true) {
            var picks: [(Int, Float)] = []
            for i in graph.nodes.indices {
                let n = graph.nodes[i]
                let (_, d) = screen(graph.position(i, at: t), size)
                guard d > 0.08, i != hovered, i != selected else { continue }
                let isPlanet = n.kind == .core || n.parent == 0 && (n.kind == .tool || n.kind == .project)
                let nearMoon = (d < 0.9 && n.kind != .skill) || d < 0.45
                let matched = highlight?.contains(i) == true
                if isPlanet || nearMoon || matched { picks.append((i, d)) }
            }
            for (i, d) in picks.sorted(by: { $0.1 < $1.1 }).prefix(36) {
                let n = graph.nodes[i]
                let (p, _) = screen(graph.position(i, at: t), size)
                guard p.x > -40, p.x < size.width + 40, p.y > -40, p.y < size.height + 40 else { continue }
                items.append(.init(text: n.label, detail: nil, point: p, color: Self.nsColor(n.kind),
                                   alpha: CGFloat(max(0.35, min(1, 1.6 - d * 0.25))), strong: false))
            }
        }
        for i in [selected, hovered].compactMap({ $0 }) where graph.nodes.indices.contains(i) {
            let n = graph.nodes[i]
            let (p, d) = screen(graph.position(i, at: t), size)
            guard d > 0.05 else { continue }
            items.append(.init(text: n.label, detail: "\(n.kind.rawValue.uppercased()) · \(n.detail)", point: p,
                               color: Self.nsColor(n.kind), alpha: 1, strong: true))
        }
        view.labels.items = items
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Node { float4 offset; float4 axis; float4 color; float4 meta; };
    struct LineVertex { float4 info; };
    struct Dust { float4 polar; float4 color; };
    struct Uniforms { float4 target; float yaw; float pitch; float distance; float aspect; float time; float energy; float scale; float dim;
                      float selected; float hovered; float pad0; float pad1; };
    struct Out { float4 position [[position]]; float4 color; float size [[point_size]]; float2 light; float kind; float glow; float alpha; float sprite; };
    // Styles: 0 galaxy, 1 neural, 2 black hole, 3 warp, 4 filament, 5 holo, 6 dial, 7 flow, 8 neuron.
    static int styleOf(constant Uniforms& u) { return int(u.pad0 + 0.5); }

    static float3 rodrigues(float3 v, float3 k, float a) {
        float c = cos(a), s = sin(a);
        return v * c + cross(k, v) * s + k * dot(k, v) * (1.0 - c);
    }
    static float3 world(const device Node* n, int i, float t) {
        float3 p = float3(0.0);
        int j = i;
        for (int d = 0; d < 4 && j >= 0; d++) {
            p += rodrigues(n[j].offset.xyz, n[j].axis.xyz, n[j].axis.w * t);
            j = int(n[j].meta.x);
        }
        return p;
    }
    static float3 viewSpace(float3 p, constant Uniforms& u) {
        float3 r = p - u.target.xyz;
        float cy = cos(u.yaw), sy = sin(u.yaw);
        float3 q = float3(cy * r.x + sy * r.z, r.y, -sy * r.x + cy * r.z);
        float cp = cos(u.pitch), sp = sin(u.pitch);
        return float3(q.x, cp * q.y - sp * q.z, sp * q.y + cp * q.z);
    }
    static float4 project(float3 q, constant Uniforms& u, thread float& d) {
        d = u.distance - q.z;
        if (d < 0.04) { return float4(9.0, 9.0, 0.5, 1.0); }
        float2 xy = q.xy * 2.35 / d;
        xy.x /= u.aspect;
        return float4(xy, 0.5, 1.0);
    }

    // Planets and moons: lit spheres with an atmosphere, lit from the central star.
    vertex Out planetVertex(uint id [[vertex_id]], const device Node* n [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        float3 w = world(n, int(id), u.time);
        float3 q = viewSpace(w, u);
        float d;
        Out o;
        o.position = project(q, u, d);
        float dc;
        float4 core = project(viewSpace(float3(0.0), u), u, dc);
        float2 toCore = core.xy - o.position.xy;
        o.light = length(toCore) > 0.0001 ? normalize(float2(toCore.x * u.aspect, toCore.y)) : float2(0.0, 1.0);
        bool sel = float(id) == u.selected;
        bool hov = float(id) == u.hovered;
        float boost = sel ? 1.7 : (hov ? 1.35 : 1.0);
        float px = n[id].offset.w * u.scale * 5.5 / max(d, 0.04) * boost * (1.0 + u.energy * 0.15);
        o.size = min(px, 240.0);
        o.kind = n[id].meta.y;
        o.glow = sel ? 1.0 : (hov ? 0.6 : 0.0);
        float a = 1.0;
        if (u.dim > 0.5 && n[id].meta.z < 0.5 && !sel) { a = 0.1; }
        o.alpha = a;
        int st = styleOf(u);
        float4 c = n[id].color;
        if (st == 2 || st == 3) {
            // Black hole / warp: hot near the center, cool at the rim, tinted by kind.
            float r = length(w.xz);
            float t = saturate((r - 0.5) / 1.4);
            float3 heat = mix(float3(1.0, 0.75, 0.45), float3(0.3, 0.55, 1.0), t);
            c.rgb = mix(heat, c.rgb, 0.35);
        } else if (st == 5) {
            c.rgb = mix(c.rgb, float3(0.35, 0.85, 1.0), 0.55);
        } else if (st == 4) {
            c.rgb = mix(c.rgb, float3(1.0, 0.95, 0.9), 0.55);
        }
        o.color = c;
        bool planet = n[id].meta.x < 0.5;     // the core or a planet hanging off it
        o.sprite = ((st == 0 && planet) || st == 6 || (st == 4 && n[id].meta.y < 0.5)) ? 0.0 : 1.0;
        if (st == 4 && n[id].meta.y < 0.5) { o.kind = 9.0; }
        if (st == 2 && n[id].meta.y < 0.5) { o.kind = 10.0; o.sprite = 0.0; }
        if (st == 0 && !planet) { o.color.rgb = mix(o.color.rgb, float3(0.8, 0.9, 1.0), 0.4) * 1.3; o.color.a = 1.0; }
        if (st == 0 && planet && n[id].meta.y > 0.5) {
            // Futuristic palette: each planet gets its own hue between teal, violet, magenta, amber and ice.
            float h = fract(sin(float(id) * 78.233) * 43758.5453);
            float3 pal = h < 0.2 ? float3(0.2, 0.9, 0.85) : h < 0.4 ? float3(0.55, 0.4, 1.0) : h < 0.6 ? float3(1.0, 0.35, 0.7)
                       : h < 0.8 ? float3(1.0, 0.7, 0.3) : float3(0.6, 0.85, 1.0);
            o.color.rgb = mix(o.color.rgb, pal, 0.7);
        }
        return o;
    }

    fragment float4 planetFragment(Out in [[stage_in]], float2 pc [[point_coord]]) {
        float2 v = pc * 2.0 - 1.0;
        v.y = -v.y;
        float r = length(v);
        if (in.sprite > 1.5) {
            // Pixel square, like a data tile.
            float edge = max(abs(v.x), abs(v.y));
            if (edge > 0.7) discard_fragment();
            float a = (in.glow > 0.0 ? 1.0 : 0.9) * smoothstep(0.7, 0.55, edge);
            return float4(in.color.rgb * (1.0 + in.glow * 0.6), a * in.alpha);
        }
        if (in.sprite > 0.5) {
            // Glowing dot with a bright core.
            float core = smoothstep(0.45, 0.2, r);
            float halo = exp(-r * r * 3.5) * 0.6;
            float ring = in.glow * smoothstep(0.06, 0.0, abs(r - 0.82)) * 0.9;
            float a = max(core, halo) + ring;
            if (a < 0.01) discard_fragment();
            return float4(mix(in.color.rgb, float3(1.0), core * 0.4 + ring * 0.5), min(1.0, a) * in.alpha);
        }
        if (in.kind > 9.5) {
            // Event horizon: a perfectly black disk with a thin hot rim.
            float R = 0.5;
            if (r < R) return float4(0.0, 0.0, 0.0, in.alpha);
            float t = (r - R) / (1.0 - R);
            float rim = exp(-t * 7.0);
            if (rim < 0.01) discard_fragment();
            return float4(float3(1.0, 0.8, 0.55) * rim, rim * in.alpha);
        }
        if (in.kind > 8.5) {
            // Filament star core: a glowing sphere with a mottled surface.
            if (r > 1.0) discard_fragment();
            float R = 0.62;
            if (r < R) {
                float2 s = v / R;
                float z = sqrt(max(0.0, 1.0 - dot(s, s)));
                float mott = 0.6 + 0.4 * sin(s.x * 11.0 + sin(s.y * 9.0) * 2.0) * sin(s.y * 13.0 + s.x * 5.0);
                float3 col = mix(float3(0.55, 0.32, 0.2), float3(1.0, 0.85, 0.65), mott) * (0.5 + 0.6 * z);
                return float4(col, in.alpha);
            }
            float t = (r - R) / (1.0 - R);
            return float4(float3(1.0, 0.85, 0.7), exp(-t * 3.0) * 0.6 * in.alpha);
        }
        if (in.kind < 0.5) {
            // The central star: a hot core with a soft corona.
            float core = smoothstep(0.35, 0.0, r);
            float corona = exp(-r * r * 5.0) * 0.8;
            float a = core + corona;
            if (a < 0.01) discard_fragment();
            return float4(mix(in.color.rgb, float3(1.0), core), min(1.0, a) * in.alpha);
        }
        float R = 0.58;
        float3 col;
        float a;
        if (r < R) {
            float2 s = v / R;
            float3 nrm = float3(s, sqrt(max(0.0, 1.0 - dot(s, s))));
            float3 L = normalize(float3(in.light, 0.55));
            float diffuse = max(0.0, dot(nrm, L));
            float bands = 0.92 + 0.08 * sin(s.y * 18.0 + s.x * 3.0);
            col = in.color.rgb * (0.16 + 0.95 * diffuse) * bands + float3(1.0) * pow(max(0.0, dot(reflect(-L, nrm), float3(0, 0, 1))), 24.0) * 0.35;
            float rim = pow(1.0 - nrm.z, 3.0);
            col += in.color.rgb * rim * 0.6;
            a = 1.0;
        } else {
            // Atmosphere glow beyond the planet's edge.
            float t = (r - R) / (1.0 - R);
            a = exp(-t * 4.0) * 0.55;
            col = in.color.rgb * 1.2;
            if (a < 0.01 && in.glow < 0.1) discard_fragment();
        }
        if (in.glow > 0.0) {
            float ring = smoothstep(0.05, 0.0, abs(r - 0.86)) * in.glow;
            col = mix(col, float3(1.0), ring * 0.7);
            a = max(a, ring);
        }
        return float4(col, a * in.alpha);
    }

    // Faint strands from each moon to its planet; strands touching the hovered or selected node pulse.
    vertex Out lineVertex(uint id [[vertex_id]], const device Node* n [[buffer(0)]], constant Uniforms& u [[buffer(1)]],
                          const device LineVertex* l [[buffer(2)]]) {
        int a = int(l[id].info.x), b = int(l[id].info.y);
        float t = l[id].info.z;
        float3 pa = world(n, a, u.time), pb = world(n, b, u.time);
        float3 dir = pb - pa;
        float len = length(dir);
        float3 side = len > 0.0001 ? normalize(cross(dir, float3(0.0, 1.0, 0.25))) : float3(0.0);
        int st = styleOf(u);
        float hash = fract(sin(float(b) * 12.9898) * 43758.5453);
        float3 c1 = pa + dir / 3.0, c2 = pa + dir * 2.0 / 3.0;
        if (st == 1) { c1 += side * 0.05; c2 += side * 0.05; }
        if (st == 8) { float3 out = normalize(pa + pb + 0.0001); c1 += out * len * 0.25 + side * len * 0.15 * (hash - 0.5); c2 += out * len * 0.15; }
        if (st == 7) { c1 = pa + float3(dir.x * 0.55, 0.0, 0.0); c2 = pb - float3(dir.x * 0.55, 0.0, 0.0); }
        if (st == 4) {
            // Curling filaments that sway slowly.
            float3 up = normalize(cross(side, dir + 0.0001));
            float w = sin(u.time * 0.6 + hash * 6.28);
            c1 += side * len * (0.5 * (hash - 0.5) + 0.12 * w) + up * len * 0.3 * (fract(hash * 7.0) - 0.5);
            c2 += side * len * (-0.4 * (hash - 0.5)) + up * len * 0.35 * w * (fract(hash * 3.0) - 0.5);
        }
        float it = 1.0 - t;
        float3 p = it * it * it * pa + 3.0 * it * it * t * c1 + 3.0 * it * t * t * c2 + t * t * t * pb;
        float d;
        Out o;
        o.position = project(viewSpace(p, u), u, d);
        o.size = 1.0;
        bool hot = float(a) == u.selected || float(b) == u.selected || float(a) == u.hovered || float(b) == u.hovered;
        float base = a == 0 ? 0.035 : 0.07;
        if (st == 2) base = 0.012;
        if (st == 0 && a != 0) base = 0.0;
        if (st == 3) base = 0.05;
        if (st == 4) base = 0.16;
        if (st == 5) base = 0.03;
        if (st == 7 || st == 8) base = 0.13;
        if (u.dim > 0.5) { base *= 0.4; }
        float pulse = hot ? (0.45 + 0.55 * smoothstep(0.7, 1.0, sin((t - u.time * 0.8) * 14.0))) : 0.0;
        // Synapse flow: light keeps travelling along every strand.
        if (st == 7) pulse += 0.25 * smoothstep(0.85, 1.0, sin((t - u.time * 0.5 - hash) * 9.0));
        float3 lc = st == 4 ? mix(n[b].color.rgb, float3(0.85, 0.85, 1.0), 0.6) : n[b].color.rgb;
        o.color = float4(lc, base + pulse + u.energy * 0.04);
        o.light = float2(0.0); o.kind = 0.0; o.glow = 0.0; o.alpha = 1.0; o.sprite = 0.0;
        return o;
    }

    // Orbit paths of the planets around the star.
    vertex Out orbitVertex(uint id [[vertex_id]], const device Node* n [[buffer(0)]], constant Uniforms& u [[buffer(1)]],
                           const device LineVertex* l [[buffer(2)]]) {
        int i = int(l[id].info.x);
        float3 p = rodrigues(n[i].offset.xyz, n[i].axis.xyz, l[id].info.y);
        float d;
        Out o;
        o.position = project(viewSpace(p, u), u, d);
        o.size = 1.0;
        bool hot = float(i) == u.selected || float(i) == u.hovered;
        o.color = float4(n[i].color.rgb, (hot ? 0.45 : 0.09) * (u.dim > 0.5 ? 0.5 : 1.0));
        o.light = float2(0.0); o.kind = 0.0; o.glow = 0.0; o.alpha = 1.0; o.sprite = 0.0;
        return o;
    }

    fragment float4 lineFragment(Out in [[stage_in]]) { return in.color; }

    // Spiral-arm stardust with differential rotation: inner stars turn faster.
    vertex Out dustVertex(uint id [[vertex_id]], const device Dust* s [[buffer(0)]], constant Uniforms& u [[buffer(1)]]) {
        float r = s[id].polar.x;
        int st = styleOf(u);
        float spin = st == 0 ? 0.05 : (st == 2 ? 0.35 : (st == 3 ? 0.04 : (st == 5 ? 0.02 : 0.0)));
        float th = s[id].polar.y + u.time * spin / (r + 0.35);
        float d;
        Out o;
        if (s[id].polar.w < 0.0) {
            // Gravitationally lensed light: a ring drawn around the black hole facing the camera.
            float3 c = viewSpace(float3(0.0), u);
            float a = s[id].polar.y + u.time * 0.3;
            float3 q = c + float3(cos(a) * r, sin(a) * r * 0.96, 0.02);
            o.position = project(q, u, d);
            o.size = min(-s[id].polar.w * u.scale * 2.6 / max(d, 0.1), 10.0);
            float top = 0.55 + 0.45 * sin(a);
            o.color = float4(s[id].color.rgb, s[id].color.a * top);
            o.light = float2(0.0); o.kind = 0.0; o.glow = 0.0; o.alpha = 1.0; o.sprite = 0.0;
            return o;
        }
        float3 p = float3(cos(th) * r, s[id].polar.z, sin(th) * r);
        o.position = project(viewSpace(p, u), u, d);
        o.size = min(s[id].polar.w * u.scale * 2.8 / max(d, 0.1), st == 2 ? 12.0 : 9.0);
        float twinkle = 0.75 + 0.25 * sin(u.time * 1.3 + float(id) * 0.77);
        o.color = float4(s[id].color.rgb, s[id].color.a * twinkle * (1.0 + u.energy * 0.6));
        o.light = float2(0.0); o.kind = 0.0; o.glow = 0.0; o.alpha = 1.0; o.sprite = 0.0;
        return o;
    }

    fragment float4 dustFragment(Out in [[stage_in]], float2 pc [[point_coord]]) {
        if (in.sprite > 1.5) {
            float2 v = abs(pc - 0.5) * 2.0;
            if (max(v.x, v.y * 1.6) > 0.9) discard_fragment();
            return float4(in.color.rgb, in.color.a);
        }
        float r = length(pc - 0.5) * 2.0;
        float a = exp(-r * r * 4.0);
        if (a < 0.02) discard_fragment();
        return float4(in.color.rgb, in.color.a * a);
    }
    """
}
