import Foundation
import XCTest

@testable import TokenMaccerCore

// The leaderboard widget's file: written by the collector (LeaderboardWidgetFile), read by the widget
// (Shared/LeaderboardWidgetData, compiled into this test target).
extension CollectorTests {
    private var widgetPath: String { joinPath(tmp, "group/widget.json") }
    private var widgetFile: String { LeaderboardWidgetFile.path(widgetPath: widgetPath) }

    /// Twelve boards of `count` rows each, the own row at `meRank`.
    private func boards(count: Int, meRank: Int) -> LeaderboardBoards {
        var out: [LeaderboardBoard] = []
        for p in ["1D", "7D", "30D", "YTD", "1Y", "ALL"] {
            for u in ["tokens", "usd"] {
                let entries = (1...count).map { r in
                    LeaderboardEntry(rank: r, displayName: r == meRank ? "Me" : "User \(r)",
                                     githubLogin: r == meRank ? "me-gh" : "user-\(r)", value: Double(1000 - r), isMe: r == meRank)
                }
                out.append(LeaderboardBoard(period: p, unit: u, participants: 120, entries: entries))
            }
        }
        return LeaderboardBoards(fetchedAt: Date(timeIntervalSince1970: 1_800_000_000), boards: out)
    }

    private func readBack() throws -> LeaderboardWidgetData {
        let bytes = try XCTUnwrap(FileManager.default.contents(atPath: widgetFile))
        return try XCTUnwrap(LeaderboardWidgetData.decode(bytes))
    }

    func testWidgetFileAbsentWithoutOptIn() throws {
        try boards(count: 12, meRank: 11).save(dataDir: data)  // stale boards on disk must not leak to the widget
        XCTAssertFalse(LeaderboardWidgetFile.sync(dataDir: data, widgetPath: widgetPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: widgetFile))
        XCTAssertEqual(LeaderboardWidgetData.state(nil, period: "7D", unit: .tokens, places: 3), .notJoined)
    }

    func testWidgetFileWaitsUntilBoardsAreFetched() throws {
        try LeaderboardState(joined: true).save(dataDir: data)
        XCTAssertTrue(LeaderboardWidgetFile.sync(dataDir: data, widgetPath: widgetPath))
        XCTAssertEqual(LeaderboardWidgetData.state(try readBack(), period: "7D", unit: .tokens, places: 3), .waiting)
    }

    func testWidgetFileTrimsToEightPlusOwnRowAndReadsBack() throws {
        try LeaderboardState(joined: true).save(dataDir: data)
        try boards(count: 12, meRank: 11).save(dataDir: data)
        XCTAssertTrue(LeaderboardWidgetFile.sync(dataDir: data, widgetPath: widgetPath))
        let back = try readBack()
        XCTAssertEqual(back.boards.count, 12)
        XCTAssertEqual(back.boards.first?.entries.map(\.rank), [1, 2, 3, 4, 5, 6, 7, 8, 11])
        XCTAssertEqual(back.fetchedAt, Date(timeIntervalSince1970: 1_800_000_000))

        guard case .board(let medium?) = LeaderboardWidgetData.state(back, period: "7D", unit: .usd, places: 3) else {
            return XCTFail("no board")
        }
        XCTAssertEqual(medium.top.map(\.rank), [1, 2, 3])
        XCTAssertEqual(medium.own?.rank, 11)
        XCTAssertEqual(medium.participants, 120)
        guard case .board(let large?) = LeaderboardWidgetData.state(back, period: "7D", unit: .usd, places: 8) else {
            return XCTFail("no board")
        }
        XCTAssertEqual(large.top.count, 8)
        XCTAssertEqual(large.own?.name, "Me")
    }

    func testWidgetFileOwnRowInsideTopIsNotRepeated() throws {
        try LeaderboardState(joined: true).save(dataDir: data)
        try boards(count: 12, meRank: 2).save(dataDir: data)
        LeaderboardWidgetFile.sync(dataDir: data, widgetPath: widgetPath)
        let back = try readBack()
        XCTAssertEqual(back.boards.first?.entries.count, 8)
        guard case .board(let b?) = LeaderboardWidgetData.state(back, period: "1D", unit: .tokens, places: 3) else {
            return XCTFail("no board")
        }
        XCTAssertNil(b.own)
        XCTAssertEqual(b.me?.rank, 2)
        // medium shows three places: the own row at 5 comes below the gap
        try boards(count: 12, meRank: 5).save(dataDir: data)
        LeaderboardWidgetFile.sync(dataDir: data, widgetPath: widgetPath)
        guard case .board(let m?) = LeaderboardWidgetData.state(try readBack(), period: "1D", unit: .tokens, places: 3) else {
            return XCTFail("no board")
        }
        XCTAssertEqual(m.own?.rank, 5)
    }

    func testWidgetFileEmbedsOnlyAvatarsOfShownPeople() throws {
        try LeaderboardState(joined: true).save(dataDir: data)
        try boards(count: 12, meRank: 11).save(dataDir: data)
        let png = Self.tinyPNG()
        try FileManager.default.createDirectory(atPath: AvatarCache.directory(dataDir: data), withIntermediateDirectories: true)
        for login in ["user-1", "me-gh", "user-10"] {  // user-10 is cached but not among the shown rows
            try png.write(to: URL(fileURLWithPath: try XCTUnwrap(AvatarCache.file(dataDir: data, login: login))))
        }
        // too big for the widget: left out, the widget draws the letter
        let big = Data(count: LeaderboardWidgetFile.maxAvatarBytes + 1)
        try big.write(to: URL(fileURLWithPath: try XCTUnwrap(AvatarCache.file(dataDir: data, login: "user-2"))))
        LeaderboardWidgetFile.sync(dataDir: data, widgetPath: widgetPath)
        let back = try readBack()
        XCTAssertEqual(Set(back.avatars.keys), ["user-1", "me-gh"])
        XCTAssertEqual(back.avatar("ME-GH"), png)
        XCTAssertNil(back.avatar("user-2"))
    }

    func testWidgetFileUnchangedIsNotRewrittenAndLeaveRemovesIt() throws {
        try LeaderboardState(joined: true).save(dataDir: data)
        try boards(count: 12, meRank: 11).save(dataDir: data)
        XCTAssertTrue(LeaderboardWidgetFile.sync(dataDir: data, widgetPath: widgetPath))
        XCTAssertFalse(LeaderboardWidgetFile.sync(dataDir: data, widgetPath: widgetPath))  // same bytes: no write, no reload
        // what leave() leaves behind: no state, no boards
        LeaderboardState.remove(dataDir: data)
        LeaderboardSync.removeBoards(dataDir: data)
        XCTAssertTrue(LeaderboardWidgetFile.sync(dataDir: data, widgetPath: widgetPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: widgetFile))
    }

    /// A pass with the leaderboard step writes the file next to widget.json and logs it (the CLI's reload trigger).
    func testCollectorPassWritesWidgetFile() throws {
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0)])
        try LeaderboardState(joined: true).save(dataDir: data)
        try boards(count: 3, meRank: 3).save(dataDir: data)
        var cfg = try config()
        cfg.widgetPath = widgetPath
        // a joined state that is not due: no request, the copy is written all the same
        var state = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        state.lastAttemptAt = Date()
        try state.save(dataDir: data)
        let spy = SpyTransport()
        let r = Collector.run(cfg, leaderboard: sync(spy, MemorySessionStore()))
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertTrue(r.stdout.contains(LeaderboardWidgetFile.updatedLog), r.stdout)
        XCTAssertEqual(try readBack().boards.first?.entries.count, 3)
        XCTAssertTrue(spy.requests.isEmpty)
    }

    func testAvatarOrderPutsWidgetPeopleFirst() throws {
        let b = boards(count: 30, meRank: 25)
        let order = LeaderboardWidgetFile.avatarOrder(b)
        XCTAssertEqual(Array(order.prefix(9)), (1...8).map { "user-\($0)" } + ["me-gh"])
        XCTAssertEqual(order.count, 30)  // nobody lost, nobody twice
    }

    func testUnreadableWidgetFileCountsAsWaitingNotNotJoined() throws {
        try FileManager.default.createDirectory(atPath: (widgetFile as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: URL(fileURLWithPath: widgetFile))
        let read = LeaderboardWidgetData.load(from: URL(fileURLWithPath: widgetFile))
        XCTAssertEqual(LeaderboardWidgetData.state(read, period: "7D", unit: .tokens, places: 3), .waiting)
        XCTAssertNil(LeaderboardWidgetData.load(from: URL(fileURLWithPath: widgetFile + ".missing")))
    }
}
