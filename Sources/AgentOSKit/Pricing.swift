import Foundation

/// API-equivalent prices in USD per million tokens (Anthropic first-party rates, Nov 2026).
/// Subscription plans do not bill per token; this shows what the same work would cost on the API.
public enum Pricing {
    public struct Rate: Sendable { public var input, output, cacheRead: Double }

    /// Matched by substring, most specific first.
    static let table: [(String, Rate)] = [
        ("fable-5-2", Rate(input: 8, output: 40, cacheRead: 0.20)),
        ("mythos-5-2", Rate(input: 8, output: 40, cacheRead: 0.20)),
        ("fable", Rate(input: 10, output: 50, cacheRead: 1.0)),
        ("mythos", Rate(input: 10, output: 50, cacheRead: 1.0)),
        ("opus-5-5", Rate(input: 4, output: 20, cacheRead: 0.20)),
        ("opus", Rate(input: 5, output: 25, cacheRead: 0.50)),
        ("sonnet-5-5", Rate(input: 2, output: 10, cacheRead: 0.10)),
        ("sonnet-5", Rate(input: 2, output: 10, cacheRead: 0.20)),
        ("sonnet", Rate(input: 3, output: 15, cacheRead: 0.30)),
        ("haiku-5-5", Rate(input: 0.10, output: 0.50, cacheRead: 0.01)),
        ("haiku", Rate(input: 1, output: 5, cacheRead: 0.10)),
    ]

    public static func rate(for model: String) -> Rate? {
        let m = model.lowercased()
        return table.first { m.contains($0.0) }?.1
    }

    /// Cost of one Claude response. Cache writes: 1.25x input for 5 minutes, 2x for 1 hour.
    public static func cost(model: String, input: Int, output: Int, cacheWrite5m: Int, cacheWrite1h: Int, cacheRead: Int) -> Double {
        guard let r = rate(for: model) else { return 0 }
        let perM = 1_000_000.0
        return (Double(input) * r.input
            + Double(output) * r.output
            + Double(cacheWrite5m) * r.input * 1.25
            + Double(cacheWrite1h) * r.input * 2
            + Double(cacheRead) * r.cacheRead) / perM
    }

    public static func shortName(_ model: String) -> String {
        let m = model.lowercased()
        for family in ["fable", "mythos", "opus", "sonnet", "haiku"] where m.contains(family) {
            let version = m.components(separatedBy: family).last?
                .split(separator: "-").prefix(2).filter { $0.allSatisfy(\.isNumber) && $0.count <= 2 }
                .joined(separator: ".") ?? ""
            return family.capitalized + (version.isEmpty ? "" : " \(version)")
        }
        return model.isEmpty ? "—" : model
    }
}

public enum Format {
    public static func tokens(_ n: Int) -> String {
        switch n {
        case 1_000_000_000...: String(format: "%.1fB", Double(n) / 1e9)
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1e6)
        case 1_000...: String(format: "%.0fk", Double(n) / 1e3)
        default: "\(n)"
        }
    }

    public static func usd(_ v: Double) -> String {
        v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
    }

    /// Rupees per US dollar. The app refreshes it daily; 88 is the fallback.
    nonisolated(unsafe) public static var inrPerUSD = 88.0

    /// A dollar amount shown in rupees with Indian digit grouping: ₹1,23,456 or ₹45.60.
    public static func money(_ usd: Double) -> String { inr(usd * inrPerUSD) }

    public static func inr(_ rupees: Double) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_IN")
        f.numberStyle = .currency
        f.currencyCode = "INR"
        f.maximumFractionDigits = abs(rupees) < 100 ? 2 : 0
        f.minimumFractionDigits = abs(rupees) < 100 ? 2 : 0
        return f.string(from: NSNumber(value: rupees)) ?? "₹\(Int(rupees))"
    }

    public static func bytes(_ b: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}
