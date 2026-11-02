import Foundation
import XCTest

@testable import TokenMaccerCore

// Groups: the collector's group actions (LeaderboardSync.group), their error mapping, leaderboard-groups.json, the
// widget's copy of the group boards and the invitation links (Shared/GroupInvite.swift, compiled into this target).
extension CollectorTests {
    private var groupWidgetPath: String { joinPath(tmp, "group/widget.json") }

    private static let gid = "11111111-2222-3333-4444-555555555555"

    private func info(name: String = "Friday Hackers", owner: Bool = true, members: Int = 2) -> [String: Any] {
        ["id": Self.gid.uppercased(), "name": name, "code": "k7m2p9qrst", "is_owner": owner, "members": members]
    }

    private func memberRows() -> [[String: Any]] {
        [
            ["group_id": Self.gid, "member_id": "aaaa", "display_name": "Synth", "github_login": "synth-gh",
             "is_owner": true, "is_me": true, "joined_at": "2026-11-02T10:00:00+00:00"],
            ["group_id": Self.gid, "member_id": "bbbb", "display_name": "Friend", "github_login": "friend-gh",
             "is_owner": false, "is_me": false, "joined_at": "2026-11-02T11:00:00+00:00"],
        ]
    }

    /// group_boards rows: twelve boards, `count` members each, the own row at `meRank`.
    private func groupBoardRows(count: Int = 2, meRank: Int = 2) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for p in ["1D", "7D", "30D", "YTD", "1Y", "ALL"] {
            for u in ["tokens", "usd"] {
                for r in 1...count {
                    let me = r == meRank
                    rows.append(["group_id": Self.gid, "period": p, "unit": u, "rank": r, "participants": count,
                                 "display_name": me ? "Synth" : (r == 1 ? "Friend" : "Member \(r)"),
                                 "github_login": me ? "synth-gh" : (r == 1 ? "friend-gh" : "member-\(r)"),
                                 "value": 1000 - r, "is_me": me])
                }
            }
        }
        return rows
    }

    private func answerRefresh(_ spy: SpyTransport, count: Int = 2, meRank: Int = 2) {
        spy.answer("/rest/v1/rpc/my_groups", 200, [info(members: count)])
        spy.answer("/rest/v1/rpc/group_member_list", 200, memberRows())
        spy.answer("/rest/v1/rpc/group_boards", 200, groupBoardRows(count: count, meRank: meRank))
    }

    private func groupError(_ status: Int, _ body: [String: Any], headers: [String: String] = [:]) -> Error? {
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        do {
            try LeaderboardClient.checkGroup(HTTPResponse(status: status, headers: headers, body: data))
            return nil
        } catch {
            return error
        }
    }

    // MARK: Error mapping

    /// The statuses PostgREST sends (checked against the local stack, 02.11.2026; "no such member" since then PT404): a 403 from a group function
    /// is about the group, never "left the leaderboard".
    func testGroupErrorsHaveTheirOwnMapping() {
        XCTAssertEqual(groupError(403, ["code": "PT403", "message": "only the owner can do that"]) as? GroupError,
                       .notAllowed("only the owner can do that"))
        XCTAssertEqual(groupError(403, ["code": "42501", "message": "join the leaderboard first"]) as? GroupError,
                       .notParticipant)
        XCTAssertEqual(groupError(404, ["code": "PT404", "message": "no such member"]) as? GroupError, .noSuchMember)
        XCTAssertEqual(groupError(409, ["code": "PT409", "message": "you can own at most 10 groups"]) as? GroupError,
                       .limit("you can own at most 10 groups"))
        XCTAssertEqual(groupError(429, ["code": "PT429", "details": "2429", "message": "too many join attempts"]) as? GroupError,
                       .tooManyAttempts(2429))
        XCTAssertEqual(groupError(400, ["code": "22023", "message": "group name needs 1 to 40 characters"]) as? GroupError,
                       .badInput("group name needs 1 to 40 characters"))
        XCTAssertEqual(groupError(401, ["message": "JWT expired"]) as? LeaderboardError, .unauthorized)
        XCTAssertEqual(groupError(403, ["message": "something else"]) as? LeaderboardError, .server(403, "something else"))
        XCTAssertNil(groupError(200, [:]))
        for e in [groupError(403, ["code": "PT403"]), groupError(403, ["code": "42501"]), groupError(403, [:])] {
            XCTAssertNotEqual(e as? LeaderboardError, .notParticipant)
        }
        XCTAssertEqual(GroupError.limit("this group is full (100 members)").description, "This group is full (100 members).")
        XCTAssertEqual(GroupError.tooManyAttempts(2429).description, "Too many join attempts. Try again in 41 min.")
    }

    /// Not the owner (403 PT403): the action fails, the joined state and its places stay, no error lands in
    /// leaderboard.json, and the groups are fetched again.
    func testForbiddenGroupActionKeepsTheLeaderboardJoined() throws {
        try joinedState()
        var before = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        before.ranks = [LeaderboardPlace(period: "1D", unit: "tokens", rank: 3, participants: 12)]
        try before.save(dataDir: data)
        let spy = SpyTransport()
        spy.answer("/rest/v1/rpc/rename_group", 403, ["code": "PT403", "message": "only the owner can do that"])
        answerRefresh(spy)
        XCTAssertThrowsError(try sync(spy, MemorySessionStore(validSession)).group(.rename(group: Self.gid, name: "x"))) {
            XCTAssertEqual($0 as? GroupError, .notAllowed("only the owner can do that"))
        }
        XCTAssertEqual(LeaderboardState.load(dataDir: data), before)
        XCTAssertEqual(Array(spy.paths.prefix(4)), ["/rest/v1/rpc/rename_group", "/rest/v1/rpc/my_groups",
                                                    "/rest/v1/rpc/group_member_list", "/rest/v1/rpc/group_boards"])
        XCTAssertNotNil(LeaderboardGroups.load(dataDir: data))
    }

    /// Not joined (or leaving): no request at all.
    func testNoGroupRequestWithoutOptIn() throws {
        let spy = SpyTransport()
        let built = Counter()
        let lb = sync(spy, MemorySessionStore(validSession)) { built.add() }
        XCTAssertThrowsError(try lb.group(.join(code: "k7m2p9qrst"))) { XCTAssertEqual($0 as? GroupError, .notParticipant) }
        var leaving = LeaderboardState(joined: false)
        leaving.leavePending = true
        try leaving.save(dataDir: data)
        XCTAssertThrowsError(try lb.group(.refresh))
        XCTAssertEqual(spy.requests.count, 0)
        XCTAssertEqual(built.value, 0)
    }

    /// join_group answers an unknown code with an object of nulls (HTTP 200): an invalid link, nothing else.
    func testUnknownCodeIsAnInvalidLink() throws {
        try joinedState()
        let spy = SpyTransport()
        spy.answer("/rest/v1/rpc/join_group", 200, ["id": NSNull(), "name": NSNull(), "code": NSNull(),
                                                    "is_owner": NSNull(), "members": NSNull()])
        spy.answer("/rest/v1/rpc/my_groups", 200, [Any]())
        XCTAssertThrowsError(try sync(spy, MemorySessionStore(validSession)).group(.join(code: "zzzzzzzzzz"))) {
            XCTAssertEqual($0 as? GroupError, .invalidCode)
        }
        XCTAssertEqual(spy.paths, ["/rest/v1/rpc/join_group", "/rest/v1/rpc/my_groups"], "no member list without groups")
        XCTAssertEqual(LeaderboardGroups.load(dataDir: data)?.groups, [])
        XCTAssertEqual(LeaderboardState.load(dataDir: data)?.joined, true)
    }

    /// Create: the name as the server stores it, the user's token; then the groups file and the widget's copy.
    func testCreateWritesGroupsFileAndWidgetCopy() throws {
        try joinedState()
        try XCTUnwrap(LeaderboardBoards.from(rows: topRows(), now: Date())).save(dataDir: data)
        let spy = SpyTransport()
        spy.answer("/rest/v1/rpc/create_group", 200, info(members: 1))
        answerRefresh(spy, count: 10, meRank: 10)
        let g = try XCTUnwrap(try sync(spy, MemorySessionStore(validSession)).group(.create(name: "  Friday \n Hackers ")))
        XCTAssertEqual(g, LeaderboardGroup(id: Self.gid, name: "Friday Hackers", code: "k7m2p9qrst", isOwner: true, members: 1))
        let create = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: create.body ?? Data()) as? [String: String],
                       ["p_name": "Friday Hackers"])
        XCTAssertEqual(create.headers["Authorization"], "Bearer access-1")
        let limit = try XCTUnwrap(spy.requests.first { $0.url.path.hasSuffix("group_boards") })
        XCTAssertEqual(try JSONSerialization.jsonObject(with: limit.body ?? Data()) as? [String: Int], ["p_limit": 50])

        let file = try XCTUnwrap(LeaderboardGroups.load(dataDir: data))
        let d = try XCTUnwrap(file.group(id: Self.gid.uppercased()))
        XCTAssertEqual(d.members.map(\.displayName), ["Synth", "Friend"])
        XCTAssertEqual(d.members.first?.isOwner, true)
        XCTAssertEqual(d.boards.count, 12)
        XCTAssertEqual(d.board(period: "7D", unit: "usd")?.entries.count, 10)

        // the widget: per group board the first eight and the own row, plus the group's id and name
        try LeaderboardState(joined: true).save(dataDir: data)
        XCTAssertTrue(LeaderboardWidgetFile.sync(dataDir: data, widgetPath: groupWidgetPath))
        let bytes = try XCTUnwrap(FileManager.default.contents(atPath: LeaderboardWidgetFile.path(widgetPath: groupWidgetPath)))
        let widget = try XCTUnwrap(LeaderboardWidgetData.decode(bytes))
        XCTAssertEqual(widget.groups?.map(\.name), ["Friday Hackers"])
        XCTAssertEqual(widget.groups?.first?.boards.first?.entries.count, 9)
        guard case .board(let b?) = LeaderboardWidgetData.state(widget, group: Self.gid, period: "7D", unit: .tokens,
                                                                 places: 8)
        else { return XCTFail("no group board") }
        XCTAssertEqual(b.top.count, 8)
        XCTAssertEqual(b.own?.rank, 10)
        XCTAssertEqual(b.participants, 10)
        // global board unchanged by the groups
        guard case .board(let global?) = LeaderboardWidgetData.state(widget, period: "7D", unit: .tokens, places: 8)
        else { return XCTFail("no global board") }
        XCTAssertEqual(global.participants, 120)
        // a chosen group that is not in the list is gone, not the global board
        XCTAssertEqual(LeaderboardWidgetData.state(widget, group: "99999999-0000-0000-0000-000000000000", period: "7D",
                                                   unit: .tokens, places: 8), .groupGone)
    }

    /// A widget file without "groups" (older collector, or groups not fetched yet): decodes, a group widget waits.
    func testWidgetFileWithoutGroupsDecodesAndWaits() throws {
        let old = #"{"fetchedAt": 1800000000, "boards": [], "avatars": {}}"#
        let data = try XCTUnwrap(LeaderboardWidgetData.decode(Data(old.utf8)))
        XCTAssertNil(data.groups)
        XCTAssertEqual(LeaderboardWidgetData.state(data, group: Self.gid, period: "1D", unit: .tokens, places: 3), .waiting)
        XCTAssertEqual(LeaderboardWidgetData.state(data, period: "1D", unit: .tokens, places: 3), .board(nil))
    }

    /// The collector pass fetches the groups after the boards; Leave removes the file with the boards.
    func testPassFetchesGroupsAndLeaveRemovesThem() throws {
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0)])
        try joinedState()
        let spy = SpyTransport()
        spy.answer("/functions/v1/report", 200, ["stored": 6, "ranks": ranksJSON(tokens1D: 3, of: 12)])
        spy.answer("/rest/v1/rpc/leaderboard_top", 200, topRows())
        answerRefresh(spy)
        XCTAssertEqual(Collector.run(try config(), leaderboard: sync(spy, MemorySessionStore(validSession))).exitCode, 0)
        XCTAssertEqual(Array(spy.paths.prefix(5)), ["/functions/v1/report", "/rest/v1/rpc/leaderboard_top",
                                                    "/rest/v1/rpc/my_groups", "/rest/v1/rpc/group_member_list",
                                                    "/rest/v1/rpc/group_boards"])
        XCTAssertTrue(spy.paths.contains("/friend-gh"), "avatars of the group boards are fetched too: \(spy.paths)")
        XCTAssertEqual(LeaderboardGroups.load(dataDir: data)?.groups.count, 1)
        spy.answer("/functions/v1/delete-account", 200, ["deleted": true])
        try sync(spy, MemorySessionStore(validSession)).leave()
        XCTAssertNil(LeaderboardGroups.load(dataDir: data))
    }

    /// A failing group fetch in the pass is quiet: report and places stay, no error.
    func testGroupFetchFailureIsQuiet() throws {
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0)])
        try joinedState()
        let spy = SpyTransport()
        spy.answer("/functions/v1/report", 200, ["stored": 6, "ranks": ranksJSON(tokens1D: 3, of: 12)])
        spy.answer("/rest/v1/rpc/leaderboard_top", 200, topRows())
        spy.answer("/rest/v1/rpc/my_groups", 403, ["code": "PT403", "message": "no"])
        XCTAssertEqual(Collector.run(try config(), leaderboard: sync(spy, MemorySessionStore(validSession))).exitCode, 0)
        let state = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        XCTAssertTrue(state.joined)
        XCTAssertNil(state.lastError)
        XCTAssertNil(LeaderboardGroups.load(dataDir: data))
    }

    func testGroupNamesAreCleanedLikeTheServer() {
        XCTAssertEqual(LeaderboardSync.cleanGroupName("  a \t  b  "), "a b")
        XCTAssertNil(LeaderboardSync.cleanGroupName("   "))
        XCTAssertEqual(LeaderboardSync.cleanGroupName(String(repeating: "x", count: 40))?.count, 40)
        XCTAssertNil(LeaderboardSync.cleanGroupName(String(repeating: "x", count: 41)))
    }

    /// Groups fetched before the global boards (a group action right after joining): the widget gets them all the same,
    /// so Edit Widget lists them and a group widget shows its board while the global one still waits.
    func testWidgetFileCarriesGroupsBeforeTheGlobalBoards() throws {
        try joinedState()
        let spy = SpyTransport()
        answerRefresh(spy)
        XCTAssertNil(try sync(spy, MemorySessionStore(validSession)).group(.refresh))
        XCTAssertNil(LeaderboardBoards.load(dataDir: data))
        XCTAssertTrue(LeaderboardWidgetFile.sync(dataDir: data, widgetPath: groupWidgetPath))
        let bytes = try XCTUnwrap(FileManager.default.contents(atPath: LeaderboardWidgetFile.path(widgetPath: groupWidgetPath)))
        let widget = try XCTUnwrap(LeaderboardWidgetData.decode(bytes))
        XCTAssertNil(widget.fetchedAt)
        XCTAssertEqual(widget.groups?.map(\.name), ["Friday Hackers"])
        XCTAssertEqual(LeaderboardWidgetData.state(widget, period: "7D", unit: .tokens, places: 8), .waiting)
        guard case .board(let b?) = LeaderboardWidgetData.state(widget, group: Self.gid, period: "7D", unit: .tokens,
                                                                 places: 8)
        else { return XCTFail("the group board waits for the global boards") }
        XCTAssertEqual(b.participants, 2)
    }

    /// The window's group refresh: at most once a minute, never two at once; a clock set back does not block it.
    func testGroupRefreshThrottle() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var t = RefreshThrottle()
        XCTAssertTrue(t.begin(now: t0))
        XCTAssertFalse(t.begin(now: t0.addingTimeInterval(120)), "never two at once")
        t.end()
        XCTAssertFalse(t.begin(now: t0.addingTimeInterval(59)), "not again within a minute")
        XCTAssertTrue(t.begin(now: t0.addingTimeInterval(60)))
        t.end()
        XCTAssertTrue(t.begin(now: t0.addingTimeInterval(-3600)), "clock set back")
        t.end()
        XCTAssertFalse(t.begin(now: t0.addingTimeInterval(-3590)))
    }

    // MARK: Invitation links

    func testInvitationCodeFromEveryForm() {
        for text in ["k7m2p9qrst", "  K7M2P9QRST \n", "https://tokenmaccer.app/join/k7m2p9qrst",
                     "https://tokenmaccer.app/join/K7M2P9QRST/", "tokenmaccer://join/k7m2p9qrst",
                     "https://www.tokenmaccer.app/join/k7m2p9qrst?ref=x", "tokenmaccer.app/join/k7m2p9qrst#top"] {
            XCTAssertEqual(GroupInvite.code(from: text), "k7m2p9qrst", text)
        }
        for text in ["", "k7m2p9qrs", "k7m2p9qrstu", "k7m2p9qrs0", "k7m2p9qrsl", "https://evil.example/join/k7m2p9qrst",
                     "tokenmaccer://leaderboard", "tokenmaccer://auth-callback?code=k7m2p9qrst"] {
            XCTAssertNil(GroupInvite.code(from: text), text)
        }
        XCTAssertEqual(GroupInvite.code(from: URL(string: "tokenmaccer://join/k7m2p9qrst")!), "k7m2p9qrst")
        XCTAssertNil(GroupInvite.code(from: URL(string: "tokenmaccer://leaderboard?group=k7m2p9qrst")!))
        XCTAssertEqual(GroupInvite.webLink("k7m2p9qrst"), "https://tokenmaccer.app/join/k7m2p9qrst")
        XCTAssertEqual(GroupInvite.appLink("k7m2p9qrst"), "tokenmaccer://join/k7m2p9qrst")
    }

    /// While the website is not live, the shared text carries the link that opens the app as well.
    func testInvitationMessageCarriesBothLinksWhileTheSiteIsNotLive() {
        let m = GroupInvite.message(group: "Friday Hackers", code: "k7m2p9qrst")
        XCTAssertTrue(m.contains("https://tokenmaccer.app/join/k7m2p9qrst"), m)
        XCTAssertTrue(m.contains("“Friday Hackers”"), m)
        XCTAssertEqual(m.contains("tokenmaccer://join/k7m2p9qrst"), !GroupInvite.siteLive, m)
    }
}
