import SwiftUI

/// The Agent OS design system: a dark HUD. Every color, radius, font and motion lives here.
/// State colors (on = green, off = red-grey) go on outlines only; hue colors are decorative backgrounds.
enum HUD {
    // Surfaces
    static let bg = Color(hex: 0x060609)
    static let bgRaised = Color(hex: 0x0B0B10)
    static let panel = Color(hex: 0x101016)
    static let panelHi = Color(hex: 0x16161E)
    static let line = Color(hex: 0x222230)
    static let lineHi = Color(hex: 0x34344A)

    // Text
    static let text = Color(hex: 0xEDEDF4)
    static let text2 = Color(hex: 0x9A9AAA)
    static let text3 = Color(hex: 0x5C5C6E)

    // Pillars (decorative)
    static let skills = Color(hex: 0xF97316)
    static let memory = Color(hex: 0x22C55E)
    static let routines = Color(hex: 0xEAB308)
    static let apps = Color(hex: 0x3B82F6)
    static let high = Color(hex: 0xA855F7)
    static let cyan = Color(hex: 0x22D3EE)
    static let pink = Color(hex: 0xEC4899)

    // State (outlines only)
    static let on = Color(hex: 0x22C55E)
    static let off = Color(hex: 0x8B5A5A)
    static let warn = Color(hex: 0xEAB308)

    static let radius: CGFloat = 14
    static let radiusSmall: CGFloat = 8

    static func hue(_ h: Double) -> Color { Color(hue: h, saturation: 0.75, brightness: 0.95) }

    // Motion
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let quick = Animation.easeOut(duration: 0.18)
    static let slow = Animation.easeInOut(duration: 0.8)

    // Type
    static func label(_ size: CGFloat = 10.5) -> Font { .system(size: size, weight: .semibold, design: .monospaced) }
    static func mono(_ size: CGFloat = 12, _ w: Font.Weight = .regular) -> Font { .system(size: size, weight: w, design: .monospaced) }
    static func title(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold) }
    static func display(_ size: CGFloat) -> Font { .system(size: size, weight: .light, design: .rounded) }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: alpha)
    }
}

// MARK: - Building blocks

/// A HUD panel: dark glassy surface, hairline border, brighter edge on hover.
struct Panel<Content: View>: View {
    var title: String?
    var dot: Color = HUD.apps
    var trailing: String?
    var padding: CGFloat = Space.lg
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let title {
                HStack(spacing: Space.sm) {
                    Circle().fill(dot).frame(width: 6, height: 6).shadow(color: dot, radius: 4)
                    Text(title.uppercased()).font(HUD.label(11)).tracking(1.6).foregroundStyle(HUD.text)
                    Spacer()
                    if let trailing { Text(trailing.uppercased()).font(HUD.label(9.5)).tracking(1).foregroundStyle(HUD.text3) }
                }
            }
            content
        }
        .padding(padding)
        .background(panelBackground)
        .overlay(HUDCorners(color: hover ? dot : HUD.lineHi).padding(3).allowsHitTesting(false))
        .onHover { h in withAnimation(HUD.quick) { hover = h } }
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
            .fill(LinearGradient(colors: [HUD.panel.opacity(0.92), HUD.bgRaised.opacity(0.92)], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [hover ? HUD.lineHi : HUD.line, HUD.line.opacity(0.5)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }
}

/// Small uppercase mono tag. `state` colors the outline; `tint` colors the background.
struct Tag: View {
    var text: String
    var tint: Color = HUD.text3
    var state: Color?

    var body: some View {
        Text(text.uppercased())
            .font(HUD.label(9))
            .tracking(0.8)
            .foregroundStyle(HUD.text)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.16)))
            .overlay(Capsule().strokeBorder(state ?? tint.opacity(0.35), lineWidth: 1))
    }
}

/// Label + big number, animating when it changes.
struct Metric: View {
    var label: String
    var value: String
    var tint: Color = HUD.text
    var sub: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(HUD.label(9.5)).tracking(1.2).foregroundStyle(HUD.text3)
            Text(value).font(HUD.display(26)).foregroundStyle(tint).contentTransition(.numericText()).monospacedDigit()
            if let sub { Text(sub).font(HUD.mono(10)).foregroundStyle(HUD.text2) }
        }
    }
}

/// Thin progress bar with a gradient fill and glow.
struct Meter: View {
    var value: Double
    var colors: [Color]
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(HUD.line)
                Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, g.size.width * min(1, max(0, value))))
                    .shadow(color: colors.last?.opacity(0.6) ?? .clear, radius: 5)
            }
        }
        .frame(height: height)
        .animation(HUD.spring, value: value)
    }
}

/// HUD-style button: outlined, mono, glows on hover.
struct HUDButtonStyle: ButtonStyle {
    var tint: Color = HUD.apps
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        HUDButtonBody(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct HUDButtonBody: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(HUD.label(10.5))
                .tracking(0.8)
                .foregroundStyle(enabled ? HUD.text : HUD.text3)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: HUD.radiusSmall, style: .continuous)
                    .fill(tint.opacity(prominent ? (hover ? 0.42 : 0.3) : (hover ? 0.16 : 0.07))))
                .overlay(RoundedRectangle(cornerRadius: HUD.radiusSmall, style: .continuous)
                    .strokeBorder(tint.opacity(hover ? 0.9 : 0.45), lineWidth: 1))
                .shadow(color: tint.opacity(hover ? 0.45 : 0), radius: 10)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(HUD.quick, value: hover)
                .animation(HUD.quick, value: configuration.isPressed)
                .onHover { hover = $0 }
                .contentShape(Rectangle())
        }
    }
}

extension ButtonStyle where Self == HUDButtonStyle {
    static var hud: HUDButtonStyle { HUDButtonStyle() }
    static func hud(_ tint: Color, prominent: Bool = false) -> HUDButtonStyle { HUDButtonStyle(tint: tint, prominent: prominent) }
}

/// A row that highlights on hover.
struct HoverRow<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hover = false

    var body: some View {
        content
            .padding(.horizontal, Space.md).padding(.vertical, Space.sm + 2)
            .background(RoundedRectangle(cornerRadius: HUD.radiusSmall + 2, style: .continuous)
                .fill(hover ? HUD.panelHi : HUD.bgRaised.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: HUD.radiusSmall + 2, style: .continuous)
                .strokeBorder(hover ? HUD.lineHi : HUD.line.opacity(0.6), lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(HUD.quick) { hover = h } }
    }
}

/// An icon in a tinted rounded square.
struct IconTile: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(tint.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }
}

/// The page header: small colored kicker, big title, trailing controls.
struct PageHeader<Trailing: View>: View {
    var title: String
    var subtitle: String
    var tint: Color = HUD.apps
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(subtitle.uppercased()).font(HUD.label(10)).tracking(2).foregroundStyle(tint)
                Text(title).font(.system(size: 28, weight: .semibold)).foregroundStyle(HUD.text)
            }
            Spacer()
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String, tint: Color = HUD.apps) {
        self.init(title: title, subtitle: subtitle, tint: tint) { EmptyView() }
    }
}

/// Empty state in the HUD style.
struct EmptyHUD: View {
    var symbol: String
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: Space.md) {
            Image(systemName: symbol).font(.system(size: 30, weight: .thin)).foregroundStyle(HUD.text3)
            Text(title).font(HUD.title()).foregroundStyle(HUD.text)
            Text(message).font(HUD.mono(11)).foregroundStyle(HUD.text2).multilineTextAlignment(.center).frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

/// Fades and lifts content in, one after another.
struct Appear: ViewModifier {
    var index: Int
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduce

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduce ? 0 : 10)
            .onAppear {
                withAnimation(HUD.spring.delay(reduce ? 0 : Double(min(index, 14)) * 0.035)) { shown = true }
            }
    }
}

extension View {
    func appear(_ index: Int = 0) -> some View { modifier(Appear(index: index)) }
}

extension Date {
    var relative: String {
        let s = Date.now.timeIntervalSince(self)
        if s < 60 { return "now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86_400 { return "\(Int(s / 3600))h ago" }
        if s < 86_400 * 30 { return "\(Int(s / 86_400))d ago" }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Targeting-bracket corners, the signature HUD frame.
struct HUDCorners: View {
    var color: Color
    var length: CGFloat = 10

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            let l = length, w = size.width, h = size.height
            p.move(to: CGPoint(x: 0, y: l)); p.addLine(to: .zero); p.addLine(to: CGPoint(x: l, y: 0))
            p.move(to: CGPoint(x: w - l, y: 0)); p.addLine(to: CGPoint(x: w, y: 0)); p.addLine(to: CGPoint(x: w, y: l))
            p.move(to: CGPoint(x: w, y: h - l)); p.addLine(to: CGPoint(x: w, y: h)); p.addLine(to: CGPoint(x: w - l, y: h))
            p.move(to: CGPoint(x: l, y: h)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: 0, y: h - l))
            ctx.stroke(p, with: .color(color.opacity(0.7)), lineWidth: 1.2)
        }
        // Decoration only: never take clicks from the buttons it frames.
        .allowsHitTesting(false)
    }
}

/// Pill tabs used at the top of multi-view pages.
struct PillTabs<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var tint: Color = HUD.skills
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                Button { withAnimation(HUD.spring) { selection = item.0 } } label: {
                    Text(item.1).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(selection == item.0 ? Color.black : HUD.text2)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background {
                            if selection == item.0 {
                                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint).shadow(color: tint.opacity(0.6), radius: 10)
                                    .matchedGeometryEffect(id: "tab", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(HUD.panel))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(HUD.line))
    }
}
