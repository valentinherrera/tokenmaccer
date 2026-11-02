import Foundation

/// Fields per day and model: input, output, cache_read, write_5m, write_1h, turns, subagent_input
let fieldCount = 7
let seenDays = 60  // how long message ids are kept for de-duplication
let hourDays = 32  // hourly values: today's curve and a fair same-time comparison for 7D/30D
let keepBackups = 14  // daily store backups to keep

typealias Table = OrderedDict<OrderedDict<[Int]>>

extension Array where Element == Int {
    /// Element or 0, so a short row from a hand-edited store cannot crash the run.
    func at(_ i: Int) -> Int { i < count ? self[i] : 0 }
}

/// Everything the model read: uncached input + cache reads + cache writes.
func totalInput(_ v: [Int]) -> Int { v.at(0) + v.at(2) + v.at(3) + v.at(4) }

/// store.json, same schema as the Python collector's, so either can continue the other's history.
struct Store {
    var version: JSONValue = .int(1)
    var files = OrderedDict<Int>()
    var seen = OrderedDict<String>()
    var days = Table()
    var hours = Table()

    init() {}

    init?(json: JSONValue) {
        guard let o = json.object else { return nil }
        version = o["version"] ?? .int(1)
        for (k, v) in o["files"]?.object ?? OrderedDict() { files[k] = v.intValue }
        for (k, v) in o["seen"]?.object ?? OrderedDict() { seen[k] = v.string ?? v.pythonStr }
        days = Self.table(o["days"])
        hours = Self.table(o["hours"])
    }

    private static func table(_ v: JSONValue?) -> Table {
        var t = Table()
        for (key, models) in v?.object ?? OrderedDict() {
            var row = OrderedDict<[Int]>()
            for (model, values) in models.object ?? OrderedDict() {
                if case .array(let a) = values { row[model] = a.map(\.intValue) }
            }
            t[key] = row
        }
        return t
    }

    var json: JSONValue {
        func table(_ t: Table) -> JSONValue {
            var o = OrderedDict<JSONValue>()
            for (key, models) in t {
                var m = OrderedDict<JSONValue>()
                for (model, v) in models { m[model] = .array(v.map { .int($0) }) }
                o[key] = .object(m)
            }
            return .object(o)
        }
        var o = OrderedDict<JSONValue>()
        o["version"] = version
        var f = OrderedDict<JSONValue>()
        for (k, v) in files { f[k] = .int(v) }
        o["files"] = .object(f)
        var s = OrderedDict<JSONValue>()
        for (k, v) in seen { s[k] = .string(v) }
        o["seen"] = .object(s)
        o["days"] = table(days)
        o["hours"] = table(hours)
        return .object(o)
    }

    static func add(_ table: inout Table, _ key: String, _ model: String, _ v: [Int]) {
        table.update(key, default: OrderedDict()) { models in
            models.update(model, default: [Int](repeating: 0, count: fieldCount)) { row in
                if row.count < v.count { row += [Int](repeating: 0, count: v.count - row.count) }
                for (i, x) in v.enumerated() { row[i] += x }
            }
        }
    }
}

/// Files of one data directory: store.json, backups/, .lock
struct StoreFiles {
    let dataDir: String
    var store: String { dataDir + "/store.json" }
    var backups: String { dataDir + "/backups" }

    func backupFiles() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: backups)) ?? []
        return names.filter { $0.hasPrefix("store-") && $0.hasSuffix(".json") }.sorted().map { backups + "/" + $0 }
    }

    enum LoadResult {
        case loaded(Store, message: String?)
        case failed(String)
    }

    /// A corrupt store is set aside and the newest readable backup is used.
    /// If the store is missing but backups exist, stop instead of silently starting from zero.
    func load() -> LoadResult {
        let fm = FileManager.default
        if !fm.fileExists(atPath: store) {
            if !backupFiles().isEmpty {
                return .failed(
                    "store.json is missing but backups exist: restore one from backups/ instead of starting empty.")
            }
            return .loaded(Store(), message: nil)
        }
        let reason: String
        if let data = fm.contents(atPath: store) {
            if let json = try? JSONParser.parse(data), let s = Store(json: json) { return .loaded(s, message: nil) }
            reason = "invalid JSON"
        } else {
            reason = "cannot read the file"
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let broken = store + ".broken-" + stamp.string(from: Date())
        try? fm.removeItem(atPath: broken)
        try? fm.moveItem(atPath: store, toPath: broken)
        for b in backupFiles().reversed() {
            if let data = fm.contents(atPath: b), let json = try? JSONParser.parse(data), let s = Store(json: json) {
                return .loaded(s, message: "store.json unreadable (\(reason)), moved to \(broken); continuing with \(b)")
            }
        }
        return .failed("store.json unreadable (\(reason)) and no readable backup; moved to \(broken)")
    }

    /// One copy of the store per day; the last `keepBackups` are kept.
    func backup(today: CivilDate) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: store) else { return }
        try? fm.createDirectory(atPath: backups, withIntermediateDirectories: true)
        let target = backups + "/store-\(today.iso).json"
        if !fm.fileExists(atPath: target) { try? fm.copyItem(atPath: store, toPath: target) }
        let all = backupFiles()
        for old in all.dropLast(keepBackups) { try? fm.removeItem(atPath: old) }
    }
}

/// Write via a temporary file in the same directory, fsync, rename.
func saveAtomic(_ path: String, _ data: Data) throws {
    let dir = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var template = Array((dir + "/tmpXXXXXX.tmp").utf8CString)
    let fd = mkstemps(&template, 4)
    guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
    let tmp = String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let ok = data.withUnsafeBytes { buf -> Bool in
        var off = 0
        while off < buf.count {
            let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
            if n <= 0 { return false }
            off += n
        }
        return fsync(fd) == 0
    }
    close(fd)
    // mkstemp creates 0600; Python's mkstemp does the same, so keep it.
    guard ok, rename(tmp, path) == 0 else {
        unlink(tmp)
        throw CocoaError(.fileWriteUnknown)
    }
}
