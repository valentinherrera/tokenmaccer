import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import TokenMaccerCore

extension CollectorTests {
    /// A 2x2 PNG, as avatars.githubusercontent.com would answer.
    static func tinyPNG() -> Data {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    func topRows(me: String = "Synth") -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for p in ["1D", "7D", "30D", "YTD", "1Y", "ALL"] {
            for u in ["tokens", "usd"] {
                rows.append(["period": p, "unit": u, "rank": 1, "participants": 120, "display_name": "Leader",
                             "github_login": "leader-gh", "value": u == "usd" ? "12.50" : 900000, "is_me": false])
                rows.append(["period": p, "unit": u, "rank": 2, "participants": 120, "display_name": "Dots",
                             "github_login": "../../etc", "value": 800000, "is_me": false])
                rows.append(["period": p, "unit": u, "rank": 57, "participants": 120, "display_name": me,
                             "github_login": "synth-gh", "value": 1000, "is_me": true])
            }
        }
        return rows
    }

    /// An answer whose body is raw bytes (the spy's `answer` takes JSON).
    final class BytesTransport: HTTPTransport, @unchecked Sendable {
        let inner: SpyTransport
        let png: Data
        init(_ inner: SpyTransport, png: Data) {
            self.inner = inner
            self.png = png
        }
        func send(_ request: HTTPRequest) throws -> HTTPResponse {
            let r = try inner.send(request)
            if request.url.host == AvatarCache.host, r.status == 500 {
                return HTTPResponse(status: 200, headers: ["content-type": "image/png"], body: png)
            }
            return r
        }
    }

    // MARK: Opt-in gate for boards and avatars

    /// Without opt-in: no board request and no avatar request, even with old board files and logins on disk.
    func testNoBoardOrAvatarRequestsWithoutOptIn() throws {
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0)])
        let old = try XCTUnwrap(LeaderboardBoards.from(rows: topRows(), now: Date()))
        try old.save(dataDir: data)
        XCTAssertFalse(old.logins.isEmpty)
        let spy = SpyTransport()
        let built = Counter()
        let lb = sync(spy, MemorySessionStore(validSession)) { built.add() }
        XCTAssertEqual(Collector.run(try config(), leaderboard: lb).exitCode, 0)
        var off = LeaderboardState(joined: false)
        off.leavePending = true
        try off.save(dataDir: data)
        XCTAssertEqual(Collector.run(try config(), leaderboard: lb).exitCode, 0)
        XCTAssertEqual(spy.requests.count, 0, "no board or avatar request without opt-in")
        XCTAssertEqual(built.value, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: AvatarCache.directory(dataDir: data)))
    }

    /// Positive control: joined, the pass reports, fetches the boards and the avatars of who is on them.
    func testOptInFetchesBoardsAndAvatars() throws {
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0)])
        try joinedState()
        let spy = SpyTransport()
        spy.answer("/functions/v1/report", 200, ["stored": 6, "ranks": ranksJSON(tokens1D: 57, of: 120)])
        spy.answer("/rest/v1/rpc/leaderboard_top", 200, topRows())
        let png = CollectorTests.tinyPNG()
        let lb = LeaderboardSync(dataDir: data, endpoint: endpoint, sessions: MemorySessionStore(validSession)) {
            BytesTransport(spy, png: png)
        }
        let r = Collector.run(try config(), leaderboard: lb)
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(spy.paths, ["/functions/v1/report", "/rest/v1/rpc/leaderboard_top", "/leader-gh", "/synth-gh"],
                       "the invalid login is never requested")
        let top = try XCTUnwrap(spy.requests.first { $0.url.path.hasSuffix("leaderboard_top") })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: top.body ?? Data()) as? [String: Int], ["p_limit": 50])
        XCTAssertEqual(top.headers["Authorization"], "Bearer access-1")

        // avatars: GitHub's avatar host, no key, no token, nothing of ours in the request
        let avatars = spy.requests.filter { $0.url.host == AvatarCache.host }
        XCTAssertEqual(avatars.count, 2)
        for a in avatars {
            XCTAssertEqual(a.method, "GET")
            XCTAssertTrue(a.headers.isEmpty, "\(a.headers)")
            XCTAssertNil(a.body)
            XCTAssertEqual(a.url.scheme, "https")
            XCTAssertEqual(a.url.query, "s=64")
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: AvatarCache.file(dataDir: data, login: "leader-gh")!)), png)
        XCTAssertTrue(FileManager.default.fileExists(atPath: AvatarCache.file(dataDir: data, login: "synth-gh")!))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: AvatarCache.directory(dataDir: data)).sorted(),
                       ["leader-gh.png", "synth-gh.png"])

        // the boards file the app reads
        let boards = try XCTUnwrap(LeaderboardBoards.load(dataDir: data))
        XCTAssertEqual(boards.boards.count, 12)
        let b = try XCTUnwrap(boards.board(period: "7D", unit: "usd"))
        XCTAssertEqual(b.participants, 120)
        XCTAssertEqual(b.entries.map(\.rank), [1, 2, 57])
        XCTAssertEqual(b.entries.first?.value, 12.5)
        XCTAssertEqual(b.entries.last?.isMe, true)

        // the next pass within 30 minutes sends nothing; cached avatars are not fetched again either
        let before = spy.requests.count
        XCTAssertEqual(Collector.run(try config(), leaderboard: lb).exitCode, 0)
        XCTAssertEqual(spy.requests.count, before)
        XCTAssertTrue(AvatarCache(dataDir: data).due(boards.logins, now: Date()).isEmpty)
    }

    /// A failing board request changes nothing about the report: places stay, no error shown.
    func testBoardFailureIsQuiet() throws {
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0)])
        try joinedState()
        let spy = SpyTransport()
        spy.answer("/functions/v1/report", 200, ["stored": 6, "ranks": ranksJSON(tokens1D: 3, of: 12)])
        XCTAssertEqual(Collector.run(try config(), leaderboard: sync(spy, MemorySessionStore(validSession))).exitCode, 0)
        XCTAssertEqual(spy.paths, ["/functions/v1/report", "/rest/v1/rpc/leaderboard_top"])
        let state = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.place(period: "1D", unit: "tokens")?.rank, 3)
        XCTAssertNil(LeaderboardBoards.load(dataDir: data))
    }

    /// Leave deletes the boards and the avatar folder with the participation.
    func testLeaveRemovesBoardsAndAvatars() throws {
        try joinedState()
        try XCTUnwrap(LeaderboardBoards.from(rows: topRows(), now: Date())).save(dataDir: data)
        try FileManager.default.createDirectory(atPath: AvatarCache.directory(dataDir: data), withIntermediateDirectories: true)
        try CollectorTests.tinyPNG().write(to: URL(fileURLWithPath: AvatarCache.file(dataDir: data, login: "leader-gh")!))
        let spy = SpyTransport()
        spy.answer("/functions/v1/delete-account", 200, ["deleted": true])
        try sync(spy, MemorySessionStore(validSession)).leave()
        XCTAssertNil(LeaderboardBoards.load(dataDir: data))
        XCTAssertFalse(FileManager.default.fileExists(atPath: AvatarCache.directory(dataDir: data)))
        XCTAssertNil(LeaderboardState.load(dataDir: data))
    }

    func testAvatarLoginsAndLimits() throws {
        for ok in ["octocat", "a", "synth-gh", "A1-b2", String(repeating: "x", count: 39)] {
            XCTAssertTrue(AvatarCache.isValidLogin(ok), ok)
        }
        for bad in ["", "-a", "a-", "../x", "a/b", "a b", "ä", "a.png", String(repeating: "x", count: 40)] {
            XCTAssertFalse(AvatarCache.isValidLogin(bad), bad)
            XCTAssertNil(AvatarCache.url(login: bad))
            XCTAssertNil(AvatarCache.file(dataDir: data, login: bad))
        }
        XCTAssertEqual(AvatarCache.url(login: "Octocat")?.absoluteString, "https://avatars.githubusercontent.com/Octocat?s=64")
        XCTAssertEqual(AvatarCache.file(dataDir: data, login: "Octocat"), data + "/avatars/octocat.png")

        // at most perPass per pass, and again only after maxAge
        let cache = AvatarCache(dataDir: data)
        let many = (0..<30).map { "user\($0)" }
        XCTAssertEqual(cache.due(many, now: Date()).count, AvatarCache.perPass)
        try FileManager.default.createDirectory(atPath: AvatarCache.directory(dataDir: data), withIntermediateDirectories: true)
        let f = try XCTUnwrap(AvatarCache.file(dataDir: data, login: "user0"))
        try CollectorTests.tinyPNG().write(to: URL(fileURLWithPath: f))
        XCTAssertEqual(cache.due(["user0"], now: Date()), [])
        XCTAssertEqual(cache.due(["user0"], now: Date().addingTimeInterval(AvatarCache.maxAge + 60)), ["user0"])

        // only images below the size limit are stored
        XCTAssertTrue(AvatarCache.isImage(CollectorTests.tinyPNG()))
        XCTAssertFalse(AvatarCache.isImage(Data("<html>not found</html>".utf8)))
        XCTAssertFalse(AvatarCache.isImage(Data()))
        let spy = SpyTransport()
        spy.answer("/user1", 200, ["not": "an image"])
        XCTAssertEqual(cache.refresh(["user1"], transport: spy, now: Date()), 0)
        XCTAssertNil(FileManager.default.contents(atPath: AvatarCache.file(dataDir: data, login: "user1")!))
    }

    func testBoardsParseAndLogins() throws {
        let boards = try XCTUnwrap(LeaderboardBoards.from(rows: topRows(), now: Date()))
        XCTAssertEqual(boards.logins, ["leader-gh", "synth-gh"], "each login once, invalid ones left out")
        XCTAssertNil(LeaderboardBoards.from(rows: ["not": "rows"], now: Date()))
        XCTAssertEqual(LeaderboardBoards.from(rows: [[String: Any]](), now: Date())?.boards, [])
    }
}
