import Foundation
import XCTest

@testable import TokenMaccerCore

/// Mirrors tests/test_collector.py case by case (same names, camel-cased). "Now" is pinned to 15:00 today
/// so the cases do not depend on the time of day they run at.
final class CollectorTests: XCTestCase {
    var tmp = ""
    var claude = ""
    var data = ""
    var proj = ""
    let now = LocalTime(date: LocalTime.now().date, hour: 15, minute: 0, second: 0)
    var nowISO: String { now.date.iso + "T15:00:00" }

    static let pricesURL = Bundle(for: CollectorTests.self).url(forResource: "prices", withExtension: "json")!
    static let pricesTable: [String: [String: Double]] = {
        let raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: pricesURL)) as! [String: Any]
        return raw.compactMapValues { $0 as? [String: Double] }
    }()

    override func setUpWithError() throws {
        tmp = NSTemporaryDirectory() + "tokenmaccer-test-" + UUID().uuidString
        claude = tmp + "/claude"
        data = tmp + "/data"
        proj = claude + "/projects/-Users-demo-project"
        try FileManager.default.createDirectory(atPath: proj, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    // MARK: helpers (same shape as the Python test helpers)

    /// UTC timestamp for a local time `daysAgo` days back (local hour:30, or now minus one minute today).
    func ts(_ daysAgo: Int = 0, _ hour: Int? = nil) -> String {
        let day = now.date.adding(days: -daysAgo)
        var t = LocalTime(date: day, hour: now.hour, minute: now.minute, second: 0).instant
        if let hour {
            t = LocalTime(date: day, hour: hour, minute: 30, second: 0).instant
        } else if daysAgo == 0 {
            t = now.instant.addingTimeInterval(-60)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'.000Z'"
        return f.string(from: t)
    }

    func turn(
        _ mid: String, _ when: String, model: String = "claude-sonnet-5-5", inp: Int = 100, out: Int = 50,
        cread: Int = 1000, w5: Int = 0, w1h: Int = 0, req: String = "r", split: Bool = true
    ) -> [String: Any] {
        var usage: [String: Any] = [
            "input_tokens": inp, "output_tokens": out, "cache_read_input_tokens": cread,
            "cache_creation_input_tokens": w5 + w1h,
        ]
        if split { usage["cache_creation"] = ["ephemeral_5m_input_tokens": w5, "ephemeral_1h_input_tokens": w1h] }
        return [
            "type": "assistant", "timestamp": when, "requestId": req + mid,
            "message": ["id": mid, "model": model, "usage": usage],
        ]
    }

    func line(_ row: Any) -> String {
        if let s = row as? String { return s }
        return String(decoding: try! JSONSerialization.data(withJSONObject: row), as: UTF8.self)
    }

    @discardableResult
    func write(_ name: String, _ rows: [Any], append: Bool = false, rawTail: String = "") -> String {
        let path = proj + "/" + name
        try! FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var text = rows.map { line($0) + "\n" }.joined() + rawTail
        if append, let old = FileManager.default.contents(atPath: path) {
            text = String(decoding: old, as: UTF8.self) + text
        }
        try! Data(text.utf8).write(to: URL(fileURLWithPath: path))
        return path
    }

    func config(rebuild: Bool = false, now pinned: String? = nil) throws -> CollectorConfig {
        CollectorConfig(
            dataDir: data, sources: [claude + "/projects"], prices: try Prices(contentsOf: Self.pricesURL),
            now: pinned ?? nowISO, rebuild: rebuild)
    }

    @discardableResult
    func runCollector(rebuild: Bool = false, file: StaticString = #filePath, line: UInt = #line) throws
        -> CollectorResult
    {
        let r = Collector.run(try config(rebuild: rebuild))
        XCTAssertEqual(r.exitCode, 0, r.stderr, file: file, line: line)
        return r
    }

    func json(_ name: String) -> [String: Any] {
        let d = FileManager.default.contents(atPath: data + "/" + name)!
        return try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    }

    func store() -> [String: Any] { json("store.json") }
    func widget() -> [String: Any] { json("widget.json") }
    func periods() -> [String: [String: Any]] { widget()["periods"] as! [String: [String: Any]] }
    func total() -> Int { periods()["ALL"]!["input"] as! Int }
    func usd1D() -> Double { periods()["1D"]!["usd"] as! Double }

    /// First model row of the first day in store.json.
    func firstRow() -> [Int] {
        let days = store()["days"] as! [String: [String: [Int]]]
        return days.values.first!.values.first!
    }

    // MARK: positive control

    func testPositiveControlKnownSum() throws {
        write(
            "a.jsonl",
            [
                turn("m1", ts(0), inp: 10, cread: 200, w5: 30, w1h: 40),
                turn("m2", ts(3, 12), inp: 1, out: 7, cread: 2, w5: 3, w1h: 4),
            ])
        try runCollector()
        XCTAssertEqual(total(), 10 + 200 + 30 + 40 + 1 + 2 + 3 + 4)
        XCTAssertEqual(periods()["ALL"]!["output"] as? Int, 50 + 7)
    }

    func testUsdUsesPriceTable() throws {
        let m = 1_000_000
        write(
            "a.jsonl",
            [turn("m1", ts(0), model: "claude-opus-5-5", inp: m, out: m, cread: m, w5: m, w1h: m)])
        try runCollector()
        let p = Self.pricesTable["claude-opus-5-5"]!
        let expected = p["input"]! + p["output"]! + p["cache_read"]! + p["write_5m"]! + p["write_1h"]!
        XCTAssertEqual(usd1D(), expected, accuracy: 0.005)
    }

    func testUnknownModelUsesFallback() throws {
        write("a.jsonl", [turn("m1", ts(0), model: "claude-future-9", inp: 1_000_000, out: 0, cread: 0)])
        try runCollector()
        XCTAssertEqual(usd1D(), Self.pricesTable["_fallback"]!["input"]!, accuracy: 0.005)
    }

    // MARK: parsing edge cases

    func testDuplicateMessageCountedOnceAcrossFiles() throws {
        let t = turn("dup", ts(1, 10))
        write("a.jsonl", [t])
        write("b.jsonl", [t])
        try runCollector()
        XCTAssertEqual(total(), 100 + 1000)
    }

    func testSyntheticAndNonAssistantLinesIgnored() throws {
        let user: [String: Any] = ["type": "user", "timestamp": ts(0), "message": ["usage": ["input_tokens": 999]]]
        write(
            "a.jsonl",
            [turn("s1", ts(0), model: "<synthetic>"), user, "not json \"usage\"", turn("ok", ts(0), inp: 5, cread: 0)])
        try runCollector()
        XCTAssertEqual(total(), 5)
    }

    func testCacheWriteWithoutSplitCountsAs5m() throws {
        write("a.jsonl", [turn("m1", ts(0), inp: 0, cread: 0, w5: 100, split: false)])
        try runCollector()
        let row = firstRow()
        XCTAssertEqual(row[3], 100)  // write_5m
        XCTAssertEqual(row[4], 0)  // write_1h
    }

    func testSubagentInputTracked() throws {
        write("sess1/subagents/agent-1.jsonl", [turn("sub1", ts(0), inp: 10, cread: 0)])
        try runCollector()
        XCTAssertEqual(firstRow()[6], 10)
    }

    // MARK: incremental behaviour

    func testIncrementalAppendAndHalfWrittenLine() throws {
        let half = String(line(turn("m2", ts(0), inp: 2, cread: 0)).prefix(40))
        let path = write("a.jsonl", [turn("m1", ts(0), inp: 1, cread: 0)], rawTail: half)
        try runCollector()
        XCTAssertEqual(total(), 1, "half-written line must wait")
        // finish the half-written line by rewriting the file with both full lines
        let full = line(turn("m1", ts(0), inp: 1, cread: 0)) + "\n" + line(turn("m2", ts(0), inp: 2, cread: 0)) + "\n"
        try Data(full.utf8).write(to: URL(fileURLWithPath: path))
        try runCollector()
        XCTAssertEqual(total(), 3)
        write("a.jsonl", [turn("m3", ts(0), inp: 4, cread: 0)], append: true)
        let p = try runCollector()
        XCTAssertEqual(total(), 7)
        XCTAssertTrue(p.stdout.hasPrefix("1 new turns"), p.stdout)
    }

    func testSecondRunWithoutChangesAddsNothing() throws {
        write("a.jsonl", [turn("m1", ts(0))])
        try runCollector()
        let path = data + "/store.json"
        var before = stat()
        stat(path, &before)
        let p = try runCollector()
        XCTAssertTrue(p.stdout.hasPrefix("0 new turns"), p.stdout)
        XCTAssertEqual(total(), 1100)
        var after = stat()
        stat(path, &after)
        XCTAssertEqual(after.st_mtimespec.tv_sec, before.st_mtimespec.tv_sec)
        XCTAssertEqual(
            after.st_mtimespec.tv_nsec, before.st_mtimespec.tv_nsec, "store must not be rewritten without new turns")
    }

    func testShrunkFileRereadWithoutDoubleCount() throws {
        let path = write("a.jsonl", [turn("m1", ts(0)), turn("m2", ts(0))])
        try runCollector()
        try Data((line(turn("m1", ts(0))) + "\n").utf8).write(to: URL(fileURLWithPath: path))
        try runCollector()
        XCTAssertEqual(total(), 2200)
    }

    // MARK: durability

    func testHistorySurvivesTranscriptDeletion() throws {
        let path = write("old.jsonl", [turn("old", ts(40, 12), inp: 500, cread: 0)])
        try runCollector()
        try FileManager.default.removeItem(atPath: path)
        write("new.jsonl", [turn("new", ts(0), inp: 1, cread: 0)])
        try runCollector()
        XCTAssertEqual(total(), 501)
        try runCollector(rebuild: true)
        XCTAssertEqual(total(), 501, "--rebuild must keep days whose transcripts are gone")
    }

    func testCorruptStoreFallsBackToBackup() throws {
        write("a.jsonl", [turn("m1", ts(0), inp: 3, cread: 0)])
        try runCollector()
        try runCollector()  // creates today's backup from the good store
        try Data("{broken".utf8).write(to: URL(fileURLWithPath: data + "/store.json"))
        let p = try runCollector()
        XCTAssertTrue(p.stdout.contains("continuing with"), p.stdout)
        XCTAssertEqual(total(), 3)
    }

    func testMissingStoreWithBackupsRefusesToStartEmpty() throws {
        write("a.jsonl", [turn("m1", ts(0))])
        try runCollector()
        try runCollector()
        try FileManager.default.removeItem(atPath: data + "/store.json")
        let p = Collector.run(try config())
        XCTAssertNotEqual(p.exitCode, 0)
        XCTAssertTrue(p.stderr.contains("backups exist"), p.stderr)
    }

    func testConcurrentRunIsSkipped() throws {
        try FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        let fd = open(data + "/.lock", O_WRONLY | O_CREAT, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let p = try runCollector()
        XCTAssertTrue(p.stdout.contains("in progress"), p.stdout)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data + "/store.json"))
    }

    func testDatedModelIdUsesBasePrice() throws {
        write("a.jsonl", [turn("m1", ts(0), model: "claude-haiku-4-5-20251001", inp: 1_000_000, out: 0, cread: 0)])
        try runCollector()
        XCTAssertEqual(usd1D(), Self.pricesTable["claude-haiku-4-5"]!["input"]!, accuracy: 0.005)
    }

    func testBadTimestampAndMissingIds() throws {
        var bad = turn("b1", ts(0))
        bad["timestamp"] = 12345
        var a = turn("x", ts(0), inp: 1, cread: 0)
        var b = turn("y", ts(0), inp: 2, cread: 0)
        for i in 0..<2 {
            var t = i == 0 ? a : b
            var m = t["message"] as! [String: Any]
            m.removeValue(forKey: "id")
            t["message"] = m
            t.removeValue(forKey: "requestId")
            if i == 0 { a = t } else { b = t }
        }
        write("a.jsonl", [bad, a, b, turn("ok", ts(0), inp: 4, cread: 0)])
        try runCollector()
        XCTAssertEqual(total(), 7, "bad line skipped, id-less messages not merged")
    }

    func testIdleHoursGiveNoFakeBaseline() throws {
        let row = [1000, 0, 0, 0, 0, 1, 0]
        var store = Store()
        Store.add(&store.hours, "2026-03-10T15", "claude-sonnet-5-5", row)
        Store.add(&store.days, "2026-03-10", "claude-sonnet-5-5", row)
        let prices = try Prices(contentsOf: Self.pricesURL)
        let atNine = LocalTime(date: CivilDate(year: 2026, month: 3, day: 11), hour: 9, minute: 30, second: 0)
        XCTAssertEqual(WidgetBuilder(store: store, prices: prices).untilNow("2026-03-10", atNine).inp, 0)
        // a day without any hourly values falls back to the pro-rata daily total
        store.hours = Table()
        XCTAssertEqual(
            WidgetBuilder(store: store, prices: prices).untilNow("2026-03-10", atNine).inp, 1000 * 9.5 / 24,
            accuracy: 1e-9)
    }

    // MARK: widget numbers

    func test7dChangeAgainstPreviousWindow() throws {
        // previous window (days 7..13 ago): 100 per day on two days; current window: 400 on one day
        write(
            "a.jsonl",
            [
                turn("p1", ts(8, 12), inp: 100, cread: 0),
                turn("p2", ts(10, 12), inp: 100, cread: 0),
                turn("c1", ts(2, 12), inp: 400, cread: 0),
            ])
        try runCollector()
        let w = periods()["7D"]!
        XCTAssertEqual(w["input"] as? Int, 400)
        XCTAssertEqual(w["change_input"] as? Double, 100.0)
        XCTAssertEqual((w["series"] as! [Any]).count, 8)
        XCTAssertEqual(w["slots"] as? Int, 8)
    }

    func testLineEndsAtHeadlineAndGhostMatchesPill() throws {
        write(
            "a.jsonl",
            [
                turn("p1", ts(8, 12), inp: 100, cread: 0),
                turn("p2", ts(400, 12), inp: 50, cread: 0),
                turn("c1", ts(2, 12), inp: 400, cread: 0),
                turn("c2", ts(0), inp: 7, cread: 0),
            ])
        try runCollector()
        for (name, p) in periods() {
            let series = (p["series"] as! [[String: Any]]).map { $0["input"] as! Int }
            XCTAssertEqual(series.first, 0, name)
            XCTAssertEqual(series.last, p["input"] as? Int, "\(name): line must end at the headline")
            XCTAssertLessThanOrEqual(series.count, p["slots"] as! Int, name)
            XCTAssertEqual(series, series.sorted(), "\(name): running total never falls")
            if let change = p["change_input"] as? Double {
                let base = (p["previous"] as! [[String: Any]])[series.count - 1]["input"] as! Int
                XCTAssertEqual(Double(p["input"] as! Int) / Double(base) - 1, change / 100, accuracy: 0.005, name)
            }
        }
        XCTAssertEqual(periods()["1D"]!["slots"] as? Int, 25)
        XCTAssertEqual(widget()["order"] as! [String], ["1D", "7D", "30D", "YTD", "1Y", "ALL"])
    }

    func testPinnedNow() throws {
        // a pinned "now" moves "today": a turn on 2026-03-10 counts for 1D when now is pinned to that day
        write("a.jsonl", [turn("m1", "2026-03-10T11:00:00.000Z", inp: 5, cread: 0)])
        let r = Collector.run(try config(now: "2026-03-10T23:30"))
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        let d = periods()["1D"]!
        XCTAssertEqual(d["input"] as? Int, 5)
        XCTAssertEqual(d["from"] as? String, "2026-03-10")
        let updated = widget()["updated"] as! String
        XCTAssertTrue(updated.hasPrefix("2026-03-10T23:30:00"), updated)
    }

    func testEmptyInstallProducesValidWidgetJson() throws {
        try runCollector()
        XCTAssertEqual(periods()["ALL"]!["input"] as? Int, 0)
        XCTAssertTrue(periods()["7D"]!["change_input"] is NSNull)
    }
}

/// Swift-only checks of the pieces that make the output byte-compatible with Python.
final class CompatTests: XCTestCase {
    func testPythonRound() {
        XCTAssertEqual(PyFloat.roundInt(2.5), 2)
        XCTAssertEqual(PyFloat.roundInt(3.5), 4)
        XCTAssertEqual(PyFloat.roundInt(-2.5), -2)
        XCTAssertEqual(PyFloat.round(2.675, 2), 2.67)  // binary value is below 2.675
        XCTAssertEqual(PyFloat.round(0.125, 2), 0.12)  // exact tie: to even
        XCTAssertEqual(PyFloat.round(0.375, 2), 0.38)
        XCTAssertEqual(PyFloat.round(-0.04, 1).sign, .minus)  // Python gives -0.0
    }

    func testPythonFloatRepr() {
        let cases: [(Double, String)] = [
            (0.0, "0.0"), (-0.0, "-0.0"), (100.0, "100.0"), (12.34, "12.34"), (0.1, "0.1"), (1e-05, "1e-05"),
            (0.0001, "0.0001"), (1e16, "1e+16"), (1234567890123456.0, "1234567890123456.0"), (1.5e300, "1.5e+300"),
            (-33.3, "-33.3"), (123456.78, "123456.78"), (5e-324, "5e-324"),
        ]
        for (x, s) in cases { XCTAssertEqual(PyFloat.repr(x), s, "\(x)") }
    }

    func testJSONWriterEnsureAscii() throws {
        var o = OrderedDict<JSONValue>()
        o["b"] = .string("Grüße 😀 \u{7f}\t\"\\/")
        o["a"] = .array([.int(1), .double(2.5), .null, .bool(true)])
        let s = String(decoding: JSONWriter.encode(.object(o)), as: UTF8.self)
        let expected = #"{"b":"GrXu00fcXu00dfe Xud83dXude00 Xu007f\t\"\\/","a":[1,2.5,null,true]}"#
            .replacingOccurrences(of: "X", with: "\\")
        XCTAssertEqual(s, expected)
    }

    func testJSONParserMatchesPythonRules() {
        func ok(_ s: String) -> Bool { (try? JSONParser.parse(Data(s.utf8))) != nil }
        XCTAssertTrue(ok(#"{"a": [1, -2.5e3, NaN, Infinity, -Infinity, true, null, "Xu00e4Xud83dXude00"]}"#.replacingOccurrences(of: "X", with: "\\")))
        XCTAssertTrue(ok("\u{FEFF}{}"))
        XCTAssertFalse(ok("{broken"))
        XCTAssertFalse(ok("{} x"))
        XCTAssertFalse(ok("01"))
        XCTAssertFalse(ok("\"a\u{01}b\""))
        XCTAssertFalse(ok("1."))
        XCTAssertFalse(ok(#"not json "usage""#))
        XCTAssertFalse((try? JSONParser.parse(Data([0x22, 0xFF, 0x22]))) != nil)  // invalid UTF-8
        if case .object(let o)? = try? JSONParser.parse(Data(#"{"z":1,"a":2,"z":3}"#.utf8)) {
            XCTAssertEqual(o.keys, ["z", "a"])
            if case .int(let z)? = o["z"] { XCTAssertEqual(z, 3) } else { XCTFail("z") }
        } else {
            XCTFail("object expected")
        }
    }

    /// Python 3.9 `datetime.fromisoformat` acceptance, from a probe of /usr/bin/python3.
    func testTimestampRulesOfPython39() {
        let accepted = [
            "2026-10-01T12:34:56.789Z", "2026-10-01T12:34:56Z", "2026-10-01", "2026-10-01T12", "2026-10-01T12:34",
            "2026-10-01 12:34:56", "2026-10-01x12:34:56", "2026-10-01T12:34:56.123456Z", "2026-10-01T12:34:56+01:00:30",
            "2026-10-01T12:34:56.789+05:30", "2026-10-01T12:34:56.789-00:00",
        ]
        let rejected = [
            "2026-10-01T12:34:56.7Z", "2026-10-01T12:34:56.1234567Z", "2026-10-01T12:34:56+0100", "2026-10-01T",
            "20261001T123456", "2026-10-01T24:00:00", "2026-02-30T00:00:00", "2026-10-01T12:34:56,789Z",
            "2026-10-01T1:34", "  2026-10-01", "2026-10-01T12:34:56+01",
        ]
        for s in accepted { XCTAssertNotNil(LocalTime.parseISO(s), s) }
        for s in rejected { XCTAssertNil(LocalTime.parseISO(s), s) }
        // naive times are local already; aware times are converted
        XCTAssertEqual(LocalTime.parseISO("2026-10-01 12:34:56")?.hourKey, "2026-10-01T12")
        let utc = LocalTime(Date(timeIntervalSince1970: 1_790_850_896))  // 2026-10-01T10:34:56Z
        XCTAssertEqual(LocalTime.parseISO("2026-10-01T12:34:56.789+02:00")?.hourKey, utc.hourKey)
    }

    func testPricePrefixAndDateSuffix() throws {
        let p = try Prices(
            json: Data(
                #"""
                {"_source": "x", "claude-a": {"input": 1, "output": 0, "cache_read": 0, "write_5m": 0, "write_1h": 0},
                 "claude-a-5": {"input": 2.0, "output": 0, "cache_read": 0, "write_5m": 0, "write_1h": 0},
                 "_fallback": {"input": 9.0, "output": 0, "cache_read": 0, "write_5m": 0, "write_1h": 0}}
                """#.utf8))
        XCTAssertEqual(p.price("claude-a-5-20260101").input, 2.0)
        XCTAssertEqual(p.price("claude-a-5-1").input, 2.0)  // longest prefix
        XCTAssertEqual(p.price("claude-a-6").input, 1.0)
        XCTAssertEqual(p.price("claude-b").input, 9.0)
        XCTAssertEqual(p.price("_source").input, 9.0)  // underscore keys are not models
        XCTAssertEqual(Prices.dropDateSuffix("claude-haiku-4-5-20251001"), "claude-haiku-4-5")
        XCTAssertEqual(Prices.dropDateSuffix("claude-haiku-4-5-2025100"), "claude-haiku-4-5-2025100")
    }

    func testConfigurationFromEnvironment() throws {
        let prices = CollectorTests.pricesURL.path
        let env = [
            "HOME": "/Users/x", "CLAUDE_CONFIG_DIR": "~/cfg", "TOKENMACCER_EXTRA_SOURCES": "~/a::/b",
            "TOKENMACCER_PRICES": prices,
        ]
        let c = try Collector.configuration(arguments: ["--source", "/c", "--rebuild"], environment: env)
        XCTAssertEqual(c.sources, ["/Users/x/cfg/projects", "/Users/x/a", "/b", "/c"])
        XCTAssertEqual(c.dataDir, "/Users/x/Library/Application Support/TokenMaccer")
        XCTAssertEqual(c.widgetPath, "/Users/x/Library/Application Support/TokenMaccer/widget.json")
        XCTAssertTrue(c.rebuild)
        var env2 = env
        env2["TOKENMACCER_CLAUDE_DIR"] = "/t"
        env2["TOKENMACCER_DATA_DIR"] = "/d"
        let c2 = try Collector.configuration(arguments: ["--widget-out", "/w/widget.json"], environment: env2)
        XCTAssertEqual(c2.sources.first, "/t/projects")
        XCTAssertEqual(c2.dataDir, "/d")
        XCTAssertEqual(c2.widgetPath, "/w/widget.json")
        XCTAssertThrowsError(try Collector.configuration(arguments: ["--bogus"], environment: env))
    }
}
