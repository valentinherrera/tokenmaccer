import Foundation
import MachO

/// USD per 1M tokens for one model.
struct Price: Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double
    let write5m: Double
    let write1h: Double
}

public struct CollectorError: Error, CustomStringConvertible {
    public let description: String
}

/// The price table from collector/prices.json (single source; the numbers are never copied into code).
public struct Prices: Sendable {
    private let table: OrderedDict<Price>

    public init(json data: Data) throws {
        guard let root = (try? JSONParser.parse(data))?.object else {
            throw CollectorError(description: "prices.json is not a JSON object")
        }
        var t = OrderedDict<Price>()
        for (key, value) in root where !key.hasPrefix("_") || key == "_fallback" {
            func field(_ name: String) throws -> Double {
                switch value[name] {
                case .int(let n): return Double(n)
                case .double(let d): return d
                default: throw CollectorError(description: "prices.json: \(key).\(name) missing")
                }
            }
            t[key] = Price(
                input: try field("input"), output: try field("output"), cacheRead: try field("cache_read"),
                write5m: try field("write_5m"), write1h: try field("write_1h"))
        }
        guard t.contains("_fallback") else { throw CollectorError(description: "prices.json has no _fallback") }
        table = t
    }

    public init(contentsOf url: URL) throws {
        try self.init(json: try Data(contentsOf: url))
    }

    /// prices.json linked into the running executable (`-sectcreate __TEXT __prices_json`), if any.
    public static func embedded() -> Prices? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var size: UInt = 0
        let start = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
            getsectiondata($0, "__TEXT", "__prices_json", &size)
        }
        guard let start, size > 0 else { return nil }
        return try? Prices(json: Data(bytes: start, count: Int(size)))
    }

    /// Exact id, then without a date suffix (claude-haiku-4-5-20251001), then the longest known prefix.
    func price(_ model: String) -> Price {
        if let p = table[model] { return p }
        let base = Self.dropDateSuffix(model)
        if let p = table[base] { return p }
        var best: String?
        for key in table.keys where !key.hasPrefix("_") && base.hasPrefix(key + "-") {
            if best == nil || key.count > best!.count { best = key }  // max(): first of equal length wins
        }
        return table[best ?? "_fallback"]!
    }

    /// `re.sub(r'-\d{8}$', '', model)`
    static func dropDateSuffix(_ model: String) -> String {
        let u = Array(model.utf8)
        guard u.count >= 9, u[u.count - 9] == UInt8(ascii: "-"),
            u[(u.count - 8)...].allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") })
        else { return model }
        return String(decoding: u[..<(u.count - 9)], as: UTF8.self)
    }

    func usd(_ model: String, _ v: [Int]) -> Double {
        let p = price(model)
        // Same operation order as Python: ((((in + out) + read) + w5) + w1h) / 1e6
        let a = Double(v.at(0)) * p.input + Double(v.at(1)) * p.output
        let b = a + Double(v.at(2)) * p.cacheRead
        let c = b + Double(v.at(3)) * p.write5m
        return (c + Double(v.at(4)) * p.write1h) / 1e6
    }
}
