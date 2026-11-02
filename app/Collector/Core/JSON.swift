import Foundation

/// Dictionary that keeps insertion order, like a Python dict. The collector's sums depend on the
/// order models are added in (floating point), and store.json is written in that order.
struct OrderedDict<Value>: Sequence {
    private(set) var keys: [String] = []
    private var values: [Value] = []
    private var index: [String: Int] = [:]

    init() {}

    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }

    subscript(key: String) -> Value? {
        get { index[key].map { values[$0] } }
        set {
            if let i = index[key] {
                if let newValue {
                    values[i] = newValue
                } else {
                    removeAll { k, _ in k == key }
                }
            } else if let newValue {
                index[key] = keys.count
                keys.append(key)
                values.append(newValue)
            }
        }
    }

    func contains(_ key: String) -> Bool { index[key] != nil }

    /// Python's `d.setdefault(key, default)` followed by an in-place change.
    mutating func update(_ key: String, default make: @autoclosure () -> Value, _ body: (inout Value) -> Void) {
        let i: Int
        if let found = index[key] {
            i = found
        } else {
            i = keys.count
            index[key] = i
            keys.append(key)
            values.append(make())
        }
        body(&values[i])
    }

    mutating func removeAll(where drop: (String, Value) -> Bool) {
        var newKeys: [String] = []
        var newValues: [Value] = []
        for (k, v) in zip(keys, values) where !drop(k, v) {
            newKeys.append(k)
            newValues.append(v)
        }
        keys = newKeys
        values = newValues
        index = Dictionary(uniqueKeysWithValues: newKeys.enumerated().map { ($1, $0) })
    }

    func makeIterator() -> Zip2Sequence<[String], [Value]>.Iterator { zip(keys, values).makeIterator() }
}

extension OrderedDict: Sendable where Value: Sendable {}

/// A parsed JSON value. Integers and floats are kept apart, as Python's json module does.
indirect enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(OrderedDict<JSONValue>)

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var object: OrderedDict<JSONValue>? {
        if case .object(let o) = self { return o }
        return nil
    }

    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Python truthiness (`if x:`).
    var truthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }

    /// Integer value of a token count (`u.get(...) or 0`); anything that is not a number counts as 0.
    var intValue: Int {
        switch self {
        case .int(let i): return i
        case .double(let d): return d.isFinite ? Int(d) : 0
        case .bool(let b): return b ? 1 : 0
        default: return 0
        }
    }

    /// Python's `str(x)` for the values that occur as ids (`f'{m.get("id")}|...'`).
    var pythonStr: String {
        switch self {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return PyFloat.repr(d)
        case .string(let s): return s
        case .array, .object: return String(decoding: JSONWriter.encode(self), as: UTF8.self)
        }
    }
}

struct JSONParseError: Error {}

/// Strict JSON parser over UTF-8 bytes with the behaviour of Python's `json.loads(bytes)`:
/// NaN/Infinity accepted, control characters in strings rejected, invalid UTF-8 rejected,
/// trailing data rejected, a UTF-8 byte order mark at the start skipped.
struct JSONParser {
    /// Deeper documents are rejected instead of overflowing the stack (Python raises RecursionError
    /// near 1000 levels; transcript lines are a few levels deep).
    static let maxDepth = 512

    private let b: UnsafeRawBufferPointer
    private var i = 0
    private var depth = 0

    private init(_ b: UnsafeRawBufferPointer) { self.b = b }

    static func parse(_ bytes: UnsafeRawBufferPointer) throws -> JSONValue {
        var p = JSONParser(bytes)
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { p.i = 3 }
        p.skipWhitespace()
        let v = try p.value()
        p.skipWhitespace()
        guard p.i == bytes.count else { throw JSONParseError() }
        return v
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try data.withUnsafeBytes { try parse($0) }
    }

    private mutating func skipWhitespace() {
        while i < b.count {
            let c = b[i]
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { i += 1 } else { break }
        }
    }

    private mutating func literal(_ word: StaticString) -> Bool {
        let n = word.utf8CodeUnitCount
        guard i + n <= b.count else { return false }
        let w = word.utf8Start
        for k in 0..<n where b[i + k] != w[k] { return false }
        i += n
        return true
    }

    private mutating func value() throws -> JSONValue {
        guard i < b.count else { throw JSONParseError() }
        switch b[i] {
        case UInt8(ascii: "{"): return try objectValue()
        case UInt8(ascii: "["): return try arrayValue()
        case UInt8(ascii: "\""): return .string(try stringValue())
        case UInt8(ascii: "t"): if literal("true") { return .bool(true) }
        case UInt8(ascii: "f"): if literal("false") { return .bool(false) }
        case UInt8(ascii: "n"): if literal("null") { return .null }
        case UInt8(ascii: "N"): if literal("NaN") { return .double(.nan) }
        case UInt8(ascii: "I"): if literal("Infinity") { return .double(.infinity) }
        case UInt8(ascii: "-"):
            if literal("-Infinity") { return .double(-.infinity) }
            return try number()
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return try number()
        default: break
        }
        throw JSONParseError()
    }

    private mutating func objectValue() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= JSONParser.maxDepth else { throw JSONParseError() }
        i += 1
        var o = OrderedDict<JSONValue>()
        skipWhitespace()
        if i < b.count, b[i] == UInt8(ascii: "}") {
            i += 1
            return .object(o)
        }
        while true {
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw JSONParseError() }
            let key = try stringValue()
            skipWhitespace()
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw JSONParseError() }
            i += 1
            skipWhitespace()
            o[key] = try value()  // duplicate key: last value wins, first position kept (like dict)
            skipWhitespace()
            guard i < b.count else { throw JSONParseError() }
            if b[i] == UInt8(ascii: ",") {
                i += 1
            } else if b[i] == UInt8(ascii: "}") {
                i += 1
                return .object(o)
            } else {
                throw JSONParseError()
            }
        }
    }

    private mutating func arrayValue() throws -> JSONValue {
        depth += 1
        defer { depth -= 1 }
        guard depth <= JSONParser.maxDepth else { throw JSONParseError() }
        i += 1
        var a: [JSONValue] = []
        skipWhitespace()
        if i < b.count, b[i] == UInt8(ascii: "]") {
            i += 1
            return .array(a)
        }
        while true {
            skipWhitespace()
            a.append(try value())
            skipWhitespace()
            guard i < b.count else { throw JSONParseError() }
            if b[i] == UInt8(ascii: ",") {
                i += 1
            } else if b[i] == UInt8(ascii: "]") {
                i += 1
                return .array(a)
            } else {
                throw JSONParseError()
            }
        }
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= b.count else { throw JSONParseError() }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = b[i]
            let d: UInt32
            switch c {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A") + 10)
            default: throw JSONParseError()
            }
            v = v * 16 + d
            i += 1
        }
        return v
    }

    private mutating func stringValue() throws -> String {
        i += 1
        var out = ""
        var runStart = i
        func flush(_ end: Int) throws {
            guard end > runStart else { return }
            let run = UnsafeRawBufferPointer(rebasing: b[runStart..<end])
            guard let s = String(validating: run, as: UTF8.self) else { throw JSONParseError() }
            out += s
        }
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                try flush(i)
                i += 1
                return out
            }
            if c < 0x20 { throw JSONParseError() }
            if c != UInt8(ascii: "\\") {
                i += 1
                continue
            }
            try flush(i)
            i += 1
            guard i < b.count else { throw JSONParseError() }
            let e = b[i]
            i += 1
            switch e {
            case UInt8(ascii: "\""): out += "\""
            case UInt8(ascii: "\\"): out += "\\"
            case UInt8(ascii: "/"): out += "/"
            case UInt8(ascii: "b"): out += "\u{08}"
            case UInt8(ascii: "f"): out += "\u{0C}"
            case UInt8(ascii: "n"): out += "\n"
            case UInt8(ascii: "r"): out += "\r"
            case UInt8(ascii: "t"): out += "\t"
            case UInt8(ascii: "u"):
                var u = try hex4()
                if (0xD800...0xDBFF).contains(u), i + 6 <= b.count, b[i] == UInt8(ascii: "\\"),
                    b[i + 1] == UInt8(ascii: "u")
                {
                    let save = i
                    i += 2
                    let low = try hex4()
                    if (0xDC00...0xDFFF).contains(low) {
                        u = 0x10000 + ((u - 0xD800) << 10) + (low - 0xDC00)
                    } else {
                        i = save
                    }
                }
                // A lone surrogate cannot live in a Swift String; Python keeps it. Replacement character.
                out.unicodeScalars.append(Unicode.Scalar(u) ?? "\u{FFFD}")
            default:
                throw JSONParseError()
            }
            runStart = i
        }
        throw JSONParseError()
    }

    private mutating func number() throws -> JSONValue {
        let start = i
        if b[i] == UInt8(ascii: "-") { i += 1 }
        func digits() -> Int {
            let s = i
            while i < b.count, b[i] >= UInt8(ascii: "0"), b[i] <= UInt8(ascii: "9") { i += 1 }
            return i - s
        }
        guard i < b.count else { throw JSONParseError() }
        if b[i] == UInt8(ascii: "0") {
            i += 1
        } else if digits() == 0 {
            throw JSONParseError()
        }
        var isFloat = false
        if i < b.count, b[i] == UInt8(ascii: "."), i + 1 < b.count, b[i + 1] >= UInt8(ascii: "0"),
            b[i + 1] <= UInt8(ascii: "9")
        {
            i += 1
            _ = digits()
            isFloat = true
        }
        if i < b.count, b[i] == UInt8(ascii: "e") || b[i] == UInt8(ascii: "E") {
            let save = i
            i += 1
            if i < b.count, b[i] == UInt8(ascii: "+") || b[i] == UInt8(ascii: "-") { i += 1 }
            if digits() == 0 { i = save } else { isFloat = true }
        }
        let text = String(decoding: UnsafeRawBufferPointer(rebasing: b[start..<i]), as: UTF8.self)
        if !isFloat, let n = Int(text) { return .int(n) }
        guard let d = Double(text) else { throw JSONParseError() }
        return .double(d)
    }
}

/// JSON output exactly like Python's `json.dump(data, f, separators=(',', ':'))`
/// (ensure_ascii, float repr, insertion order).
enum JSONWriter {
    static func encode(_ v: JSONValue) -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(1 << 16)
        write(v, into: &out)
        return Data(out)
    }

    static func write(_ v: JSONValue, into out: inout [UInt8]) {
        switch v {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let n): out.append(contentsOf: Array(String(n).utf8))
        case .double(let d): out.append(contentsOf: Array(PyFloat.jsonRepr(d).utf8))
        case .string(let s): writeString(s, into: &out)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (k, x) in a.enumerated() {
                if k > 0 { out.append(UInt8(ascii: ",")) }
                write(x, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            var first = true
            for (k, x) in o {
                if !first { out.append(UInt8(ascii: ",")) }
                first = false
                writeString(k, into: &out)
                out.append(UInt8(ascii: ":"))
                write(x, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)

    private static func writeU(_ unit: UInt16, into out: inout [UInt8]) {
        out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "u")])
        for shift in stride(from: 12, through: 0, by: -4) {
            out.append(hexDigits[Int((unit >> UInt16(shift)) & 0xF)])
        }
    }

    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\"")])
            case 0x5C: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "\\")])
            case 0x0A: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "t")])
            case 0x08: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [UInt8(ascii: "\\"), UInt8(ascii: "f")])
            case 0x20...0x7E: out.append(UInt8(scalar.value))
            default:
                for unit in String(scalar).utf16 { writeU(unit, into: &out) }
            }
        }
        out.append(UInt8(ascii: "\""))
    }
}

/// Python float semantics needed for byte-identical output.
enum PyFloat {
    /// `round(x, digits)`: correctly rounded decimal, ties to even on the exact binary value
    /// (Python's dtoa mode 3; Apple's printf uses the same algorithm).
    static func round(_ x: Double, _ digits: Int) -> Double {
        guard x.isFinite else { return x }
        return Double(String(format: "%.\(digits)f", x)) ?? x
    }

    /// `round(x)` without digits: nearest integer, ties to even.
    static func roundInt(_ x: Double) -> Int { Int(x.rounded(.toNearestOrEven)) }

    /// `repr(x)`: shortest round-trip digits, exponent form below 1e-4 and from 1e16 on.
    static func repr(_ x: Double) -> String {
        if x.isNaN { return "nan" }
        if x.isInfinite { return x < 0 ? "-inf" : "inf" }
        if x == 0 { return x.sign == .minus ? "-0.0" : "0.0" }
        // Swift's description has the same shortest digits; only the layout differs.
        var text = Swift.abs(x).description
        var exp10 = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp10 = Int(text[text.index(after: e)...]) ?? 0
            text = String(text[..<e])
        }
        var intPart = text
        var fracPart = ""
        if let dot = text.firstIndex(of: ".") {
            intPart = String(text[..<dot])
            fracPart = String(text[text.index(after: dot)...])
        }
        var digits = intPart + fracPart
        var point = intPart.count + exp10  // decimal point position within `digits`
        while digits.count > 1, digits.first == "0" {
            digits.removeFirst()
            point -= 1
        }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        let decExp = point - 1  // exponent in d.ddd form
        let sign = x < 0 ? "-" : ""
        if decExp < -4 || decExp >= 16 {
            let mantissa = digits.count > 1 ? "\(digits.first!).\(digits.dropFirst())" : String(digits)
            let e = Swift.abs(decExp)
            return sign + mantissa + "e" + (decExp < 0 ? "-" : "+") + (e < 10 ? "0\(e)" : "\(e)")
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + digits }
        if point >= digits.count { return sign + digits + String(repeating: "0", count: point - digits.count) + ".0" }
        let idx = digits.index(digits.startIndex, offsetBy: point)
        return sign + digits[..<idx] + "." + digits[idx...]
    }

    /// What json.dumps writes for a float.
    static func jsonRepr(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x < 0 ? "-Infinity" : "Infinity" }
        return repr(x)
    }
}
