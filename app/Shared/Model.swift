import Foundation

/// App Group shared by app, widget and intents. Set per build from the signing team
/// (Info.plist key `TMAppGroup` = `$(DEVELOPMENT_TEAM).tokenmaccer`).
let appGroup: String? = Bundle.main.object(forInfoDictionaryKey: "TMAppGroup") as? String

struct Point: Codable, Hashable {
    let t: String
    let input: Int
    let usd: Double
}

struct Period: Codable {
    let input: Int
    let output: Int
    let usd: Double
    let ratio: Int?
    let change_input: Double?
    let change_usd: Double?
    let series: [Point]
    let from: String
    let to: String
}

struct WidgetData: Codable {
    let updated: String
    let periods: [String: Period]
    let order: [String]

    /// The collector writes to ~/.claude/tools/tokenmaccer/; the sandbox grants read access there.
    /// Inside the sandbox NSHomeDirectory() points at the container, so take the real home from passwd.
    static var defaultURL: URL? {
        guard let pw = getpwuid(getuid()), let home = String(validatingCString: pw.pointee.pw_dir) else { return nil }
        return URL(fileURLWithPath: home + "/.claude/tools/tokenmaccer/widget.json")
    }

    static func load(from url: URL? = defaultURL) -> WidgetData? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetData.self, from: data)
    }

    var updatedDate: Date? { ISO8601DateFormatter().date(from: updated) }
}

enum Unit: String { case tokens, usd }

/// Selection in the widget (period, unit), shared between app, widget and App Intents.
enum Selection {
    static let periods = ["1D", "7D", "30D", "YTD", "1Y", "ALL"]
    static var defaults: UserDefaults { appGroup.flatMap { UserDefaults(suiteName: $0) } ?? .standard }

    static var period: String {
        get { defaults.string(forKey: "period") ?? "1D" }
        set { defaults.set(newValue, forKey: "period") }
    }
    static var unit: Unit {
        get { Unit(rawValue: defaults.string(forKey: "unit") ?? "tokens") ?? .tokens }
        set { defaults.set(newValue.rawValue, forKey: "unit") }
    }
    static func nextPeriod() {
        let i = periods.firstIndex(of: period) ?? 0
        period = periods[(i + 1) % periods.count]
    }
}

enum Format {
    static func tokens(_ n: Int) -> String {
        let d = Double(n)
        if d >= 1e9 { return number(d / 1e9, digits: d >= 1e11 ? 0 : 1) + "B" }
        if d >= 1e6 { return number(d / 1e6, digits: d >= 1e8 ? 0 : 1) + "M" }
        if d >= 1e3 { return number(d / 1e3, digits: 0) + "K" }
        return number(d, digits: 0)
    }
    static func usd(_ v: Double) -> String {
        "$" + number(v, digits: v >= 1000 ? 0 : 2)
    }
    static func percent(_ v: Double?) -> String {
        guard let v else { return "–" }
        return (v > 0 ? "+" : v < 0 ? "−" : "±") + number(abs(v), digits: 1) + "%"
    }
    static func number(_ v: Double, digits: Int) -> String {
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .decimal
        f.maximumFractionDigits = digits
        f.minimumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
    static func periodName(_ k: String) -> String {
        switch k {
        case "1D": return "Today"
        case "7D": return "7 days"
        case "30D": return "30 days"
        case "YTD": return "Year to date"
        case "1Y": return "1 year"
        default: return "All time"
        }
    }
}
