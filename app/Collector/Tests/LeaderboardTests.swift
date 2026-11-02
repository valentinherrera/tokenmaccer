import Foundation
import XCTest

@testable import TokenMaccerCore

/// Records every request; answers from a queue (or 500 when empty).
final class SpyTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [HTTPRequest] = []
    private var answers: [(String, HTTPResponse)] = []

    var requests: [HTTPRequest] { lock.withLock { _requests } }
    var paths: [String] { requests.map { $0.url.path } }

    /// Next answer for a request whose path ends with `suffix`.
    func answer(_ suffix: String, _ status: Int, _ json: Any, headers: [String: String] = [:]) {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        lock.withLock { answers.append((suffix, HTTPResponse(status: status, headers: headers, body: body))) }
    }

    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        lock.withLock {
            _requests.append(request)
            if let i = answers.firstIndex(where: { request.url.path.hasSuffix($0.0) }) {
                return answers.remove(at: i).1
            }
            return HTTPResponse(status: 500, body: Data("{\"error\":\"no answer queued\"}".utf8))
        }
    }
}

/// No network: every request fails like URLSessionTransport does when offline.
final class OfflineTransport: HTTPTransport, @unchecked Sendable {
    let calls = Counter()
    func send(_ request: HTTPRequest) throws -> HTTPResponse {
        calls.add()
        throw LeaderboardError.network("The Internet connection appears to be offline.")
    }
}

final class MemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: LeaderboardSession?
    init(_ s: LeaderboardSession? = nil) { session = s }
    func load() -> LeaderboardSession? { lock.withLock { session } }
    func save(_ s: LeaderboardSession) throws { lock.withLock { session = s } }
    func delete() { lock.withLock { session = nil } }
    func session(_ s: LeaderboardSession?) { lock.withLock { session = s } }
}

extension CollectorTests {
    var endpoint: LeaderboardEndpoint { LeaderboardEndpoint(url: "https://example.supabase.co", key: "sb_publishable_test")! }

    func sync(_ spy: SpyTransport, _ sessions: SessionStore, transportBuilt: (@Sendable () -> Void)? = nil) -> LeaderboardSync {
        LeaderboardSync(dataDir: data, endpoint: endpoint, sessions: sessions) {
            transportBuilt?()
            return spy
        }
    }

    func ranksJSON(tokens1D: Int?, of: Int) -> [[String: Any]] {
        var rows: [[String: Any]] = []
        for p in ["1D", "7D", "30D", "YTD", "1Y", "ALL"] {
            for u in ["tokens", "usd"] {
                let rank: Any = (p == "1D" && u == "tokens") ? (tokens1D.map { $0 as Any } ?? NSNull()) : 2
                rows.append(["period": p, "unit": u, "rank": rank, "participants": of, "value": 1])
            }
        }
        return rows
    }

    func widgetJSON() throws -> [String: Any] {
        let raw = try Data(contentsOf: URL(fileURLWithPath: data + "/widget.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: raw) as? [String: Any])
    }

    func joinedState(lastAttempt: Date? = nil) throws {
        var s = LeaderboardState(joined: true, displayName: "synth", githubLogin: "synth-gh", joinedAt: Date())
        s.lastAttemptAt = lastAttempt
        try s.save(dataDir: data)
    }

    var validSession: LeaderboardSession {
        LeaderboardSession(accessToken: "access-1", refreshToken: "refresh-1", expiresAt: Date().addingTimeInterval(3600))
    }

    // MARK: Opt-in gate

    /// Without opt-in the collector never builds a client or sends a request, and widget.json has no ranks;
    /// also not with tokens left in the keychain or with a state file that says "not joined".
    func testNoNetworkWithoutOptIn() throws {
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0)])
        let spy = SpyTransport()
        let built = Counter()
        let lb = sync(spy, MemorySessionStore(validSession)) { built.add() }
        XCTAssertEqual(Collector.run(try config(), leaderboard: lb).exitCode, 0)
        XCTAssertNil(try widgetJSON()["ranks"])
        var off = LeaderboardState(joined: false, displayName: "x")
        off.leavePending = true
        try off.save(dataDir: data)
        let r = Collector.run(try config(), leaderboard: lb)
        XCTAssertEqual(r.exitCode, 0)
        XCTAssertFalse(r.stdout.contains("leaderboard"))
        XCTAssertEqual(spy.requests.count, 0, "no request without opt-in")
        XCTAssertEqual(built.value, 0, "no network client is even created without opt-in")
        XCTAssertNil(try widgetJSON()["ranks"])
        // the last line stays the one the app parses
        XCTAssertTrue(r.stdout.split(separator: "\n").last?.contains("new turns") == true)
    }

    /// Positive control for the gate: the same setup with opt-in does send the report.
    func testOptInReportsAndWritesRanksIntoWidgetJSON() throws {
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0), turn("m2", ts(3), inp: 20, cread: 5)])
        try joinedState()
        let spy = SpyTransport()
        spy.answer("/functions/v1/report", 200, ["stored": 6, "ranks": ranksJSON(tokens1D: 3, of: 12)])
        let r = Collector.run(try config(), leaderboard: sync(spy, MemorySessionStore(validSession)))
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(spy.paths, ["/functions/v1/report"])
        let req = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(req.headers["Authorization"], "Bearer access-1")
        XCTAssertEqual(req.headers["apikey"], "sb_publishable_test")

        // report body: exactly the six period totals, nothing else
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: req.body ?? Data()) as? [String: Any])
        XCTAssertEqual(Array(body.keys), ["periods"])
        let periods = try XCTUnwrap(body["periods"] as? [String: [String: Any]])
        XCTAssertEqual(Set(periods.keys), ["1D", "7D", "30D", "YTD", "1Y", "ALL"])
        for (_, p) in periods { XCTAssertEqual(Set(p.keys), ["input", "output", "usd", "start"]) }
        XCTAssertEqual(periods["1D"]?["input"] as? Int, 10)
        XCTAssertEqual(periods["7D"]?["input"] as? Int, 35)
        XCTAssertEqual(periods["1D"]?["start"] as? String, now.date.iso)

        // rank mapping: present places only ("#3 of 12" for 1D tokens), the Shared model reads them
        let ranks = try XCTUnwrap(try widgetJSON()["ranks"] as? [String: [String: [String: Int]]])
        XCTAssertEqual(ranks["1D"]?["tokens"], ["rank": 3, "of": 12])
        XCTAssertEqual(ranks["ALL"]?["usd"], ["rank": 2, "of": 12])
        let decoded = try JSONDecoder().decode(
            WidgetData.self, from: Data(contentsOf: URL(fileURLWithPath: data + "/widget.json")))
        XCTAssertEqual(decoded.place(period: "1D", unit: .tokens), Place(rank: 3, of: 12))
        // the widget names the board the place belongs to
        XCTAssertEqual(Place(rank: 3, of: 12).label(period: "7D", unit: .tokens), "#3 · 7D · Tokens")
        XCTAssertEqual(Place(rank: 1, of: 2).label(period: "ALL", unit: .usd), "#1 · ALL · USD")
        XCTAssertEqual(Place(rank: 3, of: 12).accessibilityLabel(period: "7D", unit: .tokens),
                       "Leaderboard place 3 of 12, 7 days, tokens")
        XCTAssertEqual(decoded.place(period: "YTD", unit: .usd), Place(rank: 2, of: 12))
        let state = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        XCTAssertNotNil(state.lastReportAt)
        XCTAssertNil(state.lastError)
    }

    /// A period without a place (rank null) is left out; widget.json without ranks still decodes.
    func testRankMappingSkipsMissingPlaces() throws {
        let places = CollectorTests.placesFrom(ranksJSON(tokens1D: nil, of: 4))
        let mapped = try XCTUnwrap(LeaderboardSync.widgetRanks(places))
        XCTAssertNil(mapped["1D"]?["tokens"])
        XCTAssertNotNil(mapped["1D"]?["usd"])
        XCTAssertNil(LeaderboardSync.widgetRanks([LeaderboardPlace(period: "1D", unit: "usd", rank: nil, participants: 0)]))
        let plain = Data(#"{"updated":"x","periods":{},"order":[]}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(WidgetData.self, from: plain).ranks)
    }

    static func placesFrom(_ rows: [[String: Any]]) -> [LeaderboardPlace] { LeaderboardClient.places(rows) }

    // MARK: Report cadence

    /// At most one report attempt per 30 minutes, also after a failure; a 429 is respected.
    func testReportCadence() throws {
        let t0 = Date()
        var s = LeaderboardState(joined: true)
        XCTAssertTrue(LeaderboardSchedule.isDue(s, now: t0), "first report right after joining")
        s.lastAttemptAt = t0
        XCTAssertFalse(LeaderboardSchedule.isDue(s, now: t0.addingTimeInterval(5 * 60)))
        XCTAssertFalse(LeaderboardSchedule.isDue(s, now: t0.addingTimeInterval(29 * 60 + 59)))
        XCTAssertTrue(LeaderboardSchedule.isDue(s, now: t0.addingTimeInterval(30 * 60)))
        s.retryAfter = t0.addingTimeInterval(45 * 60)
        XCTAssertFalse(LeaderboardSchedule.isDue(s, now: t0.addingTimeInterval(31 * 60)))
        XCTAssertTrue(LeaderboardSchedule.isDue(s, now: t0.addingTimeInterval(46 * 60)))
        s.retryAfter = nil
        XCTAssertTrue(LeaderboardSchedule.isDue(s, now: t0.addingTimeInterval(-2 * 3600)), "clock set back")
        s.joined = false
        XCTAssertFalse(LeaderboardSchedule.isDue(s, now: t0.addingTimeInterval(3600)))

        // through the collector: three passes 5 minutes apart send one report; a failed one also waits
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0)])
        try joinedState(lastAttempt: nil)
        let spy = SpyTransport()
        let lb = sync(spy, MemorySessionStore(validSession))
        spy.answer("/functions/v1/report", 500, ["error": "down"])
        for _ in 0..<3 { _ = Collector.run(try config(), leaderboard: lb) }
        XCTAssertEqual(spy.requests.count, 1)
        let failed = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        XCTAssertNotNil(failed.lastError)
        XCTAssertNil(failed.lastReportAt)

        // 31 minutes later it is due again; a 429 falls back to my_ranks and sets retryAfter
        var later = failed
        later.lastAttemptAt = Date().addingTimeInterval(-31 * 60)
        try later.save(dataDir: data)
        spy.answer("/functions/v1/report", 429, ["error": "rate limited"], headers: ["retry-after": "600"])
        spy.answer("/rest/v1/rpc/my_ranks", 200, ranksJSON(tokens1D: 1, of: 2))
        _ = Collector.run(try config(), leaderboard: lb)
        XCTAssertEqual(spy.paths.suffix(2), ["/functions/v1/report", "/rest/v1/rpc/my_ranks"])
        let limited = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        XCTAssertNotNil(limited.retryAfter)
        XCTAssertEqual(limited.place(period: "1D", unit: "tokens")?.rank, 1)
        XCTAssertNotNil(try widgetJSON()["ranks"])
    }

    /// Old places are not shown; an expired access token is refreshed (and the new tokens kept) first.
    func testStalePlacesHiddenAndTokenRefreshed() throws {
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0)])
        var s = LeaderboardState(joined: true)
        s.lastAttemptAt = Date()
        s.ranks = CollectorTests.placesFrom(ranksJSON(tokens1D: 1, of: 2))
        s.ranksAt = Date().addingTimeInterval(-4 * 3600)
        try s.save(dataDir: data)
        let spy = SpyTransport()
        _ = Collector.run(try config(), leaderboard: sync(spy, MemorySessionStore(validSession)))
        XCTAssertEqual(spy.requests.count, 0)
        XCTAssertNil(try widgetJSON()["ranks"], "places older than 3 hours are hidden")

        s.lastAttemptAt = nil
        try s.save(dataDir: data)
        let expired = LeaderboardSession(accessToken: "old", refreshToken: "r-old", expiresAt: Date().addingTimeInterval(-10))
        let store = MemorySessionStore(expired)
        spy.answer("/auth/v1/token", 200, ["access_token": "new", "refresh_token": "r-new", "expires_in": 3600])
        spy.answer("/functions/v1/report", 200, ["ranks": ranksJSON(tokens1D: 1, of: 2)])
        _ = Collector.run(try config(), leaderboard: sync(spy, store))
        XCTAssertEqual(spy.paths, ["/auth/v1/token", "/functions/v1/report"])
        XCTAssertEqual(spy.requests.first?.url.query, "grant_type=refresh_token")
        XCTAssertEqual(spy.requests.last?.headers["Authorization"], "Bearer new")
        XCTAssertEqual(store.load()?.refreshToken, "r-new", "rotated refresh token is kept")

        // the server forgot the participant (403): reports stop, places go
        var again = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        again.lastAttemptAt = nil
        try again.save(dataDir: data)
        spy.answer("/functions/v1/report", 403, ["error": "not a participant"])
        _ = Collector.run(try config(), leaderboard: sync(spy, store))
        XCTAssertEqual(LeaderboardState.load(dataDir: data)?.joined, false)
        XCTAssertNil(try widgetJSON()["ranks"])
    }

    // MARK: Failures of the report

    /// Reports that fail never break the collector pass: widget.json is written, the participant stays joined
    /// (except after a 403, see above), the error is kept for the app, and the next attempt waits 30 minutes.
    func testReportFailures() throws {
        _ = write("a.jsonl", [turn("m1", ts(0), inp: 10, cread: 0)])
        func due() throws {
            var s = try XCTUnwrap(LeaderboardState.load(dataDir: data))
            s.lastAttemptAt = nil
            s.retryAfter = nil
            try s.save(dataDir: data)
        }
        func state() throws -> LeaderboardState { try XCTUnwrap(LeaderboardState.load(dataDir: data)) }
        try joinedState()

        // no network: the transport throws
        let offline = OfflineTransport()
        let r = Collector.run(try config(), leaderboard: LeaderboardSync(
            dataDir: data, endpoint: endpoint, sessions: MemorySessionStore(validSession)) { offline })
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertEqual(offline.calls.value, 1)
        XCTAssertNotNil(try widgetJSON()["periods"], "widget.json is written without the server")
        XCTAssertNil(try widgetJSON()["ranks"])
        XCTAssertTrue(try state().joined)
        let offlineError = try XCTUnwrap(try state().lastError)
        XCTAssertTrue(offlineError.contains("No connection"), offlineError)
        XCTAssertNotNil(try state().lastAttemptAt, "the next attempt waits for the interval")
        _ = Collector.run(try config(), leaderboard: LeaderboardSync(
            dataDir: data, endpoint: endpoint, sessions: MemorySessionStore(validSession)) { offline })
        XCTAssertEqual(offline.calls.value, 1, "no retry within 30 minutes")

        // 401 twice: one refresh, one more try, then the error is kept; the participant stays joined
        try due()
        let spy = SpyTransport()
        let store = MemorySessionStore(validSession)
        spy.answer("/functions/v1/report", 401, ["error": "invalid token"])
        spy.answer("/auth/v1/token", 200, ["access_token": "access-2", "refresh_token": "refresh-2", "expires_in": 3600])
        spy.answer("/functions/v1/report", 401, ["error": "invalid token"])
        XCTAssertEqual(Collector.run(try config(), leaderboard: sync(spy, store)).exitCode, 0)
        XCTAssertEqual(spy.paths, ["/functions/v1/report", "/auth/v1/token", "/functions/v1/report"])
        XCTAssertEqual(spy.requests.last?.headers["Authorization"], "Bearer access-2")
        XCTAssertTrue(try state().joined)
        XCTAssertEqual(try state().lastError, LeaderboardError.unauthorized.description)

        // 401 and a dead refresh token (GoTrue answers 400): no second report, error kept
        try due()
        spy.answer("/functions/v1/report", 401, ["error": "invalid token"])
        spy.answer("/auth/v1/token", 400, ["error": "invalid_grant"])
        _ = Collector.run(try config(), leaderboard: sync(spy, store))
        XCTAssertEqual(Array(spy.paths.suffix(2)), ["/functions/v1/report", "/auth/v1/token"])
        XCTAssertEqual(try state().lastError, LeaderboardError.unauthorized.description)

        // 422 (the server found the report implausible): kept as a server error, no retryAfter, still joined
        try due()
        store.session(validSession)
        spy.answer("/functions/v1/report", 422, ["error": "inconsistent periods: 1D exceeds 7D"])
        _ = Collector.run(try config(), leaderboard: sync(spy, store))
        XCTAssertEqual(spy.paths.last, "/functions/v1/report")
        XCTAssertTrue(try state().joined)
        XCTAssertNil(try state().retryAfter)
        XCTAssertEqual(try state().lastError, LeaderboardError.server(422, "inconsistent periods: 1D exceeds 7D").description)

        // 429 without Retry-After: waits 300 s; when my_ranks fails too, the error is kept and nothing breaks
        try due()
        spy.answer("/functions/v1/report", 429, ["error": "rate limited"])
        spy.answer("/rest/v1/rpc/my_ranks", 503, ["error": "down"])
        let before = Date()
        XCTAssertEqual(Collector.run(try config(), leaderboard: sync(spy, store)).exitCode, 0)
        XCTAssertEqual(Array(spy.paths.suffix(2)), ["/functions/v1/report", "/rest/v1/rpc/my_ranks"])
        let wait = try XCTUnwrap(try state().retryAfter).timeIntervalSince(before)
        XCTAssertTrue((295...310).contains(wait), "\(wait)")
        XCTAssertTrue(try state().joined)
        XCTAssertNotNil(try state().lastError)
        XCTAssertNil(try widgetJSON()["ranks"])
    }

    // MARK: Join and leave

    func testJoinExchangesCodeAndLeaveDeletesEverything() throws {
        let spy = SpyTransport()
        let store = MemorySessionStore()
        let lb = sync(spy, store)
        XCTAssertThrowsError(try lb.join(code: "c", verifier: "v", displayName: "   "))
        XCTAssertEqual(spy.requests.count, 0)

        spy.answer("/auth/v1/token", 200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600])
        spy.answer("/rest/v1/rpc/join_leaderboard", 200, ["github_login": "synth-gh", "display_name": "Synth"])
        let state = try lb.join(code: "the-code", verifier: "the-verifier", displayName: " Synth ")
        XCTAssertEqual(spy.requests[0].url.query, "grant_type=pkce")
        let exchange = try XCTUnwrap(JSONSerialization.jsonObject(with: spy.requests[0].body ?? Data()) as? [String: String])
        XCTAssertEqual(exchange, ["auth_code": "the-code", "code_verifier": "the-verifier"])
        let joinBody = try XCTUnwrap(JSONSerialization.jsonObject(with: spy.requests[1].body ?? Data()) as? [String: String])
        XCTAssertEqual(joinBody, ["p_display_name": "Synth"])
        XCTAssertEqual(state.githubLogin, "synth-gh")
        XCTAssertEqual(LeaderboardState.load(dataDir: data)?.joined, true)
        XCTAssertEqual(store.load()?.accessToken, "a")

        // leave: server down -> reports stop, tokens kept for "Leave Again"
        spy.answer("/functions/v1/delete-account", 503, ["error": "down"])
        spy.answer("/rest/v1/rpc/leave_leaderboard", 503, ["error": "down"])
        XCTAssertThrowsError(try lb.leave())
        let pending = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        XCTAssertFalse(pending.joined)
        XCTAssertTrue(pending.leavePending)
        XCTAssertNotNil(store.load())

        spy.answer("/functions/v1/delete-account", 200, ["deleted": true])
        try lb.leave()
        XCTAssertNil(store.load(), "tokens deleted")
        XCTAssertNil(LeaderboardState.load(dataDir: data), "state deleted")
        XCTAssertEqual(spy.paths.last, "/functions/v1/delete-account")
    }

    /// A JWT-shaped access token with the given `sub` (signature irrelevant for the client).
    func jwt(sub: String) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["sub": sub, "role": "authenticated"])
        return "eyJhbGciOiJIUzI1NiJ9." + PKCE.base64url(payload) + ".sig"
    }

    func testUserIdFromAccessToken() {
        XCTAssertEqual(LeaderboardClient.userId(fromAccessToken: jwt(sub: "11111111-2222-3333-4444-555555555555")),
                       "11111111-2222-3333-4444-555555555555")
        XCTAssertNil(LeaderboardClient.userId(fromAccessToken: "a"))
        XCTAssertNil(LeaderboardClient.userId(fromAccessToken: "x.%%%.y"))
    }

    /// delete-account failing while leave_leaderboard works is NOT a finished leave: the auth account stays.
    func testLeaveFallbackToLeaveRPCIsNotSuccess() throws {
        try joinedState()
        let spy = SpyTransport()
        let store = MemorySessionStore(validSession)
        let lb = sync(spy, store)
        spy.answer("/functions/v1/delete-account", 503, ["error": "down"])
        spy.answer("/rest/v1/rpc/leave_leaderboard", 200, ["result": true])
        XCTAssertThrowsError(try lb.leave()) { e in
            guard case LeaderboardError.accountNotDeleted(entryRemoved: true, _) = e else {
                return XCTFail("expected accountNotDeleted(entryRemoved: true), got \(e)")
            }
        }
        XCTAssertEqual(spy.paths, ["/functions/v1/delete-account", "/rest/v1/rpc/leave_leaderboard"])
        let pending = try XCTUnwrap(LeaderboardState.load(dataDir: data), "state kept")
        XCTAssertTrue(pending.leavePending)
        XCTAssertFalse(pending.needsSignIn, "the sign-in still works: Leave Again")
        XCTAssertNotNil(store.load(), "tokens kept for Leave Again")

        spy.answer("/functions/v1/delete-account", 404, ["error": "no such function"])
        spy.answer("/rest/v1/rpc/leave_leaderboard", 200, ["result": true])
        XCTAssertThrowsError(try lb.leave())
        XCTAssertNotNil(LeaderboardState.load(dataDir: data), "404 is not success either")

        spy.answer("/functions/v1/delete-account", 200, ["deleted": true])
        try lb.leave()
        XCTAssertNil(store.load())
        XCTAssertNil(LeaderboardState.load(dataDir: data))
    }

    /// No keychain item: leave does not pretend; it asks for a sign-in, which then deletes the account.
    func testLeaveWithoutSessionAsksForSignInThenDeletes() throws {
        let uid = "aaaaaaaa-0000-0000-0000-000000000001"
        var s = LeaderboardState(joined: true, displayName: "synth", githubLogin: "synth-gh", joinedAt: Date())
        s.userId = uid
        try s.save(dataDir: data)
        let spy = SpyTransport()
        let store = MemorySessionStore()
        let lb = sync(spy, store)
        XCTAssertThrowsError(try lb.leave()) { XCTAssertEqual($0 as? LeaderboardError, .notSignedIn) }
        XCTAssertEqual(spy.requests.count, 0)
        let pending = try XCTUnwrap(LeaderboardState.load(dataDir: data), "state kept, not silently removed")
        XCTAssertTrue(pending.needsSignIn)
        XCTAssertFalse(pending.joined)

        // a second try without a sign-in stays honest
        XCTAssertThrowsError(try lb.leave())
        XCTAssertTrue(try XCTUnwrap(LeaderboardState.load(dataDir: data)).needsSignIn)

        // sign-in with another GitHub account that does not take part: refused; the account that sign-in left
        // on the server is deleted again with its own token, the joined account is not touched, no tokens kept
        let other = jwt(sub: "bbbbbbbb-0000-0000-0000-000000000002")
        spy.answer("/auth/v1/token", 200, ["access_token": other, "refresh_token": "r2", "expires_in": 3600])
        spy.answer("/rest/v1/profiles", 200, [Any]())
        spy.answer("/functions/v1/delete-account", 200, ["deleted": true])
        XCTAssertThrowsError(try lb.leave(signIn: ("code-x", "ver-x"))) {
            XCTAssertEqual($0 as? LeaderboardError, .otherAccount)
        }
        XCTAssertEqual(spy.paths, ["/auth/v1/token", "/rest/v1/profiles", "/functions/v1/delete-account"])
        XCTAssertEqual(spy.requests[1].method, "GET")
        XCTAssertEqual(spy.requests[1].url.query, "select=id&id=eq.bbbbbbbb-0000-0000-0000-000000000002")
        XCTAssertEqual(spy.requests[2].headers["Authorization"], "Bearer " + other, "deletes the other account only")
        XCTAssertNil(store.load())
        XCTAssertTrue(try XCTUnwrap(LeaderboardState.load(dataDir: data)).needsSignIn)

        // another GitHub account that takes part itself (an entry from another Mac): refused, nothing deleted
        spy.answer("/auth/v1/token", 200, ["access_token": other, "refresh_token": "r3", "expires_in": 3600])
        spy.answer("/rest/v1/profiles", 200, [["id": "bbbbbbbb-0000-0000-0000-000000000002"]])
        XCTAssertThrowsError(try lb.leave(signIn: ("code-y", "ver-y")))
        XCTAssertEqual(Array(spy.paths.suffix(2)), ["/auth/v1/token", "/rest/v1/profiles"])
        // the lookup fails: nothing deleted either
        spy.answer("/auth/v1/token", 200, ["access_token": other, "refresh_token": "r4", "expires_in": 3600])
        spy.answer("/rest/v1/profiles", 503, ["error": "down"])
        XCTAssertThrowsError(try lb.leave(signIn: ("code-z", "ver-z")))
        XCTAssertEqual(Array(spy.paths.suffix(2)), ["/auth/v1/token", "/rest/v1/profiles"])
        XCTAssertEqual(spy.paths.filter { $0 == "/functions/v1/delete-account" }.count, 1)
        XCTAssertNil(store.load())
        let before = spy.requests.count

        // sign-in with the right account: exchange, delete-account, everything gone
        let right = jwt(sub: uid)
        spy.answer("/auth/v1/token", 200, ["access_token": right, "refresh_token": "r1", "expires_in": 3600])
        spy.answer("/functions/v1/delete-account", 200, ["deleted": true])
        try lb.leave(signIn: ("code-1", "ver-1"))
        XCTAssertEqual(spy.requests[before].url.query, "grant_type=pkce")
        XCTAssertEqual(spy.paths.suffix(2), ["/auth/v1/token", "/functions/v1/delete-account"])
        XCTAssertEqual(spy.requests.last?.headers["Authorization"], "Bearer " + right)
        XCTAssertNil(store.load())
        XCTAssertNil(LeaderboardState.load(dataDir: data))
    }

    /// Dead refresh token: Leave Again would fail forever; instead the dead sign-in goes and a new one is asked for.
    func testLeaveWithDeadRefreshTokenAsksForSignIn() throws {
        try joinedState()
        let spy = SpyTransport()
        let store = MemorySessionStore(
            LeaderboardSession(accessToken: "old", refreshToken: "dead", expiresAt: Date().addingTimeInterval(-10)))
        let lb = sync(spy, store)
        spy.answer("/auth/v1/token", 400, ["error": "invalid_grant", "error_description": "Invalid Refresh Token"])
        XCTAssertThrowsError(try lb.leave()) { XCTAssertEqual($0 as? LeaderboardError, .unauthorized) }
        XCTAssertEqual(spy.paths, ["/auth/v1/token"])
        XCTAssertNil(store.load(), "the dead sign-in is removed")
        let pending = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        XCTAssertTrue(pending.needsSignIn)

        // also a 401 from delete-account twice (refresh in between works, token still refused)
        try joinedState()
        store.session(validSession)
        spy.answer("/functions/v1/delete-account", 401, ["error": "invalid token"])
        spy.answer("/auth/v1/token", 200, ["access_token": "a2", "refresh_token": "r2", "expires_in": 3600])
        spy.answer("/functions/v1/delete-account", 401, ["error": "invalid token"])
        XCTAssertThrowsError(try lb.leave())
        XCTAssertTrue(try XCTUnwrap(LeaderboardState.load(dataDir: data)).needsSignIn)
    }

    /// Never joined, nothing in the keychain: nothing to do, no request.
    func testLeaveWhenNeverJoinedIsANoOp() throws {
        let spy = SpyTransport()
        try sync(spy, MemorySessionStore()).leave()
        XCTAssertEqual(spy.requests.count, 0)
        XCTAssertNil(LeaderboardState.load(dataDir: data))
    }

    /// Join failing after the code exchange deletes the account the sign-in created.
    func testJoinFailureDeletesTheNewAccount() throws {
        let spy = SpyTransport()
        let store = MemorySessionStore()
        let lb = sync(spy, store)
        spy.answer("/auth/v1/token", 200, ["access_token": "a", "refresh_token": "r", "expires_in": 3600])
        spy.answer("/rest/v1/rpc/join_leaderboard", 400, ["message": "display name longer than 32 characters"])
        spy.answer("/functions/v1/delete-account", 200, ["deleted": true])
        XCTAssertThrowsError(try lb.join(code: "c", verifier: "v", displayName: "Synth"))
        XCTAssertEqual(spy.paths, ["/auth/v1/token", "/rest/v1/rpc/join_leaderboard", "/functions/v1/delete-account"])
        XCTAssertEqual(spy.requests.last?.headers["Authorization"], "Bearer a")
        XCTAssertNil(store.load())
        XCTAssertNil(LeaderboardState.load(dataDir: data))

        // the clean-up fails too: the account is not forgotten, the app offers Leave Again
        spy.answer("/auth/v1/token", 200, ["access_token": "b", "refresh_token": "r", "expires_in": 3600])
        spy.answer("/rest/v1/rpc/join_leaderboard", 503, ["message": "down"])
        spy.answer("/functions/v1/delete-account", 503, ["error": "down"])
        XCTAssertThrowsError(try lb.join(code: "c", verifier: "v", displayName: "Synth"))
        let pending = try XCTUnwrap(LeaderboardState.load(dataDir: data))
        XCTAssertTrue(pending.leavePending)
        XCTAssertFalse(pending.joined)
        XCTAssertFalse(pending.needsSignIn)
        XCTAssertEqual(store.load()?.accessToken, "b", "tokens kept for Leave Again")
    }

    // MARK: PKCE and endpoint

    func testPKCEVerifierAndChallenge() {
        // RFC 7636 appendix B
        XCTAssertEqual(
            PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let v = PKCE.verifier()
        XCTAssertEqual(v.count, 43)
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        XCTAssertTrue(v.unicodeScalars.allSatisfy { allowed.contains($0) })
        XCTAssertNotEqual(v, PKCE.verifier())
        XCTAssertEqual(PKCE.challenge(for: v).count, 43)
    }

    func testEndpointResolutionAndCallback() throws {
        let config = Data(#"{"url":"https://qcjb.supabase.co","publishable_key":"sb_publishable_x","anon_key_legacy":"ey"}"#.utf8)
        XCTAssertEqual(LeaderboardEndpoint.resolve(environment: [:], defaults: nil, bundled: config)?.url.absoluteString,
                       "https://qcjb.supabase.co")
        let local = LeaderboardEndpoint.resolve(
            environment: ["TOKENMACCER_LEADERBOARD_URL": "http://127.0.0.1:54321", "TOKENMACCER_LEADERBOARD_KEY": "k"],
            defaults: nil, bundled: config)
        XCTAssertEqual(local?.url.absoluteString, "http://127.0.0.1:54321")
        XCTAssertNil(LeaderboardEndpoint(url: "http://evil.example.com", key: "k"), "plain http only for loopback")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "tokenmaccer-test-\(UUID().uuidString)"))
        defaults.set("http://localhost:54321", forKey: LeaderboardEndpoint.urlDefaultsKey)
        defaults.set("k2", forKey: LeaderboardEndpoint.keyDefaultsKey)
        XCTAssertEqual(LeaderboardEndpoint.resolve(environment: [:], defaults: defaults, bundled: config)?.key, "k2")
        XCTAssertTrue(LeaderboardEndpoint.overridesAllowed, "the tests run the Debug configuration")

        // Release builds: neither App Group defaults nor environment variables move the server
        let release = LeaderboardEndpoint.resolve(
            environment: ["TOKENMACCER_LEADERBOARD_URL": "http://127.0.0.1:54321", "TOKENMACCER_LEADERBOARD_KEY": "k"],
            defaults: defaults, bundled: config, allowOverrides: false)
        XCTAssertEqual(release?.url.absoluteString, "https://qcjb.supabase.co")
        XCTAssertEqual(release?.key, "sb_publishable_x")
        XCTAssertNil(LeaderboardEndpoint.resolve(environment: [:], defaults: defaults, bundled: nil, allowOverrides: false),
                     "without the bundled config a release build has no server, it does not fall back to an override")

        let url = try XCTUnwrap(LeaderboardEndpoint.bundled(config)).authorizeURL(challenge: "abc")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.path, "/auth/v1/authorize")
        XCTAssertEqual(items, ["provider": "github", "redirect_to": "tokenmaccer://auth-callback",
                               "code_challenge": "abc", "code_challenge_method": "s256"])
        XCTAssertEqual(try LeaderboardEndpoint.code(fromCallback: URL(string: "tokenmaccer://auth-callback?code=xyz")!).get(), "xyz")
        if case .success = LeaderboardEndpoint.code(
            fromCallback: URL(string: "tokenmaccer://auth-callback?error=access_denied&error_description=denied")!)
        {
            XCTFail("an error callback has no code")
        }
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    func add() { lock.withLock { n += 1 } }
}
