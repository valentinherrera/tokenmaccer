import CryptoKit
import Foundation
import Security

// Opt-in leaderboard (app edition). Everything that touches the network lives here and runs in the
// background collector: the app only drives the GitHub sign-in (ASWebAuthenticationSession) and hands
// the authorization code to `tokenmaccer-collector leaderboard join`. Without a joined state file
// (leaderboard.json in the data folder) no request is ever built, see LeaderboardSync.apply.

// MARK: PKCE (RFC 7636, S256)

public enum PKCE {
    /// 43 characters from 32 random bytes (base64url without padding), within RFC 7636's 43...128.
    public static func verifier() -> String {
        var rng = SystemRandomNumberGenerator()
        return base64url(Data((0..<32).map { _ in UInt8.random(in: 0...255, using: &rng) }))
    }

    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: Server address

/// The Supabase project of the leaderboard: supabase/app-config.json (the hosted project), bundled with
/// the app and linked into the collector. Debug builds also accept an explicit override for a local
/// stack: the environment variables TOKENMACCER_LEADERBOARD_URL + TOKENMACCER_LEADERBOARD_KEY (tests)
/// or the App Group defaults TMLeaderboardURL + TMLeaderboardKey (manual tests with the app). Release
/// builds ignore both, so nothing on the Mac can point the sign-in or the reports at another server.
/// Plain http only for loopback.
public struct LeaderboardEndpoint: Equatable, Sendable {
    public let url: URL
    public let key: String

    public static let redirect = "tokenmaccer://auth-callback"
    public static let callbackScheme = "tokenmaccer"
    public static let urlDefaultsKey = "TMLeaderboardURL"
    public static let keyDefaultsKey = "TMLeaderboardKey"

    public init?(url: String, key: String) {
        guard !key.isEmpty, let u = URL(string: url.hasSuffix("/") ? String(url.dropLast()) : url),
            let host = u.host
        else { return nil }
        let loopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        guard u.scheme == "https" || (u.scheme == "http" && loopback) else { return nil }
        self.url = u
        self.key = key
    }

    /// app-config.json: "url" and the public key ("publishable_key", else "anon_key_legacy").
    public static func bundled(_ json: Data?) -> LeaderboardEndpoint? {
        guard let json, let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let url = obj["url"] as? String
        else { return nil }
        let key = (obj["publishable_key"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (obj["anon_key_legacy"] as? String) ?? ""
        return LeaderboardEndpoint(url: url, key: key)
    }

    /// Overrides count only in Debug builds (the DEBUG condition of the Debug configuration).
    public static let overridesAllowed: Bool = {
        #if DEBUG
            return true
        #else
            return false
        #endif
    }()

    public static func resolve(
        environment env: [String: String], defaults: UserDefaults?, bundled json: Data?,
        allowOverrides: Bool = overridesAllowed
    ) -> LeaderboardEndpoint? {
        guard allowOverrides else { return bundled(json) }
        if let u = env["TOKENMACCER_LEADERBOARD_URL"], let k = env["TOKENMACCER_LEADERBOARD_KEY"],
            !u.isEmpty, !k.isEmpty
        {
            return LeaderboardEndpoint(url: u, key: k)
        }
        if let defaults, let u = defaults.string(forKey: urlDefaultsKey), let k = defaults.string(forKey: keyDefaultsKey),
            !u.isEmpty, !k.isEmpty
        {
            return LeaderboardEndpoint(url: u, key: k)
        }
        return bundled(json)
    }

    /// supabase/app-config.json linked into the collector (`-sectcreate __TEXT __lb_config`), if any.
    public static func embeddedConfig() -> Data? {
        guard let header = _dyld_get_image_header(0) else { return nil }
        var size: UInt = 0
        let start = header.withMemoryRebound(to: mach_header_64.self, capacity: 1) {
            getsectiondata($0, "__TEXT", "__lb_config", &size)
        }
        guard let start, size > 0 else { return nil }
        return Data(bytes: start, count: Int(size))
    }

    /// GitHub sign-in through Supabase Auth, PKCE flow; Supabase redirects to tokenmaccer://auth-callback?code=…
    public func authorizeURL(challenge: String) -> URL {
        var c = URLComponents(url: url.appendingPathComponent("auth/v1/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "provider", value: "github"),
            URLQueryItem(name: "redirect_to", value: Self.redirect),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "s256"),
        ]
        return c.url!
    }

    /// The authorization code from the callback URL, or the error Supabase/GitHub put there.
    public static func code(fromCallback url: URL) -> Result<String, LeaderboardError> {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // errors come in the query or, for implicit-style redirects, in the fragment
        let fragment = URLComponents(string: "x:/?" + (url.fragment ?? ""))?.queryItems ?? []
        func value(_ name: String) -> String? { (items + fragment).first { $0.name == name }?.value }
        if let code = value("code"), !code.isEmpty { return .success(code) }
        let why = value("error_description") ?? value("error") ?? "no authorization code in the callback"
        return .failure(.server(0, why))
    }
}

// MARK: HTTP

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) throws -> HTTPResponse
}

/// Synchronous requests for the one-shot collector process (ephemeral session: no cookies, no cache).
public final class URLSessionTransport: HTTPTransport {
    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 20) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 2
        config.httpCookieStorage = nil
        config.urlCache = nil
        session = URLSession(configuration: config)
        self.timeout = timeout
    }

    private final class Box: @unchecked Sendable {
        var result: Result<HTTPResponse, Error> = .failure(LeaderboardError.network("no response"))
    }

    public func send(_ request: HTTPRequest) throws -> HTTPResponse {
        var r = URLRequest(url: request.url)
        r.httpMethod = request.method
        r.httpBody = request.body
        for (k, v) in request.headers { r.setValue(v, forHTTPHeaderField: k) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: r) { data, response, error in
            if let error {
                box.result = .failure(LeaderboardError.network(error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let k = k as? String { headers[k.lowercased()] = "\(v)" }
                }
                box.result = .success(HTTPResponse(status: http.statusCode, headers: headers, body: data ?? Data()))
            }
            done.signal()
        }.resume()
        if done.wait(timeout: .now() + timeout * 2 + 5) == .timedOut {
            throw LeaderboardError.network("timed out")
        }
        return try box.result.get()
    }
}

public enum LeaderboardError: Error, Equatable, CustomStringConvertible {
    case network(String)
    case unauthorized
    case notParticipant
    case rateLimited(Int)
    case server(Int, String)
    case notSignedIn
    case noServer
    /// delete-account failed; `entryRemoved`: leave_leaderboard at least deleted profile and totals.
    case accountNotDeleted(entryRemoved: Bool, String)
    /// A sign-in for leaving belongs to another account than the one that joined.
    case otherAccount

    public var description: String {
        switch self {
        case .network(let why): return "No connection to the leaderboard server (\(why))."
        case .unauthorized:
            return "The sign-in expired. Choose Leave (you sign in with GitHub once more to delete your entry), then join again."
        case .notParticipant: return "Your leaderboard entry no longer exists. Join again to take part."
        case .rateLimited(let s): return "The server asks to wait \(s) s before the next report."
        case .server(let status, let why): return status == 0 ? why : "Server error \(status): \(why)"
        case .notSignedIn:
            return "There is no sign-in for the leaderboard server on this Mac any more. Sign in with GitHub once more to delete your entry."
        case .noServer: return "No leaderboard server configured."
        case .accountNotDeleted(let removed, let why):
            return (removed
                ? "Your profile and totals are deleted, but your account on the leaderboard server is not yet"
                : "Your account on the leaderboard server could not be deleted") + " (\(why))."
        case .otherAccount:
            return "This GitHub account is not the one that joined. Sign in with the account shown under Leaderboard."
        }
    }
}

// MARK: Sign-in (tokens)

public struct LeaderboardSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }
}

public protocol SessionStore: Sendable {
    func load() -> LeaderboardSession?
    func save(_ session: LeaderboardSession) throws
    func delete()
}

/// Access and refresh token in the login keychain, one generic password item owned by the collector.
/// The item is created by the collector binary, so its access list trusts exactly that signed program
/// (updates with the same Developer ID keep access); the app never reads it. The data protection
/// keychain with an App Group access group would need a provisioning profile for Developer ID builds
/// (errSecMissingEntitlement -34018 without one), hence the login keychain.
public struct KeychainSessionStore: SessionStore {
    public let service: String
    public static let account = "session"

    public init(service: String) { self.service = service }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func load() -> LeaderboardSession? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? Self.decoder.decode(LeaderboardSession.self, from: data)
    }

    public func save(_ session: LeaderboardSession) throws {
        let data = try Self.encoder.encode(session)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "TokenMaccer leaderboard sign-in"
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw LeaderboardError.server(0, "keychain error \(s)") }
        } else if status != errSecSuccess {
            throw LeaderboardError.server(0, "keychain error \(status)")
        }
    }

    public func delete() { SecItemDelete(query as CFDictionary) }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

// MARK: Local state

/// One place as my_ranks() returns it (rank is nil while the user has no fresh total for that period).
public struct LeaderboardPlace: Codable, Equatable, Sendable {
    public var period: String
    public var unit: String
    public var rank: Int?
    public var participants: Int

    public init(period: String, unit: String, rank: Int?, participants: Int) {
        self.period = period
        self.unit = unit
        self.rank = rank
        self.participants = participants
    }
}

/// `<data dir>/leaderboard.json`: the opt-in switch and what the app shows. Without this file, or with
/// `joined` false, the collector does not touch the network.
public struct LeaderboardState: Codable, Equatable, Sendable {
    public var joined: Bool
    public var displayName: String?
    public var githubLogin: String?
    public var joinedAt: Date?
    /// Last report attempt (successful or not): the next one waits at least `LeaderboardSchedule.interval`.
    public var lastAttemptAt: Date?
    public var lastReportAt: Date?
    /// Set from the server's Retry-After.
    public var retryAfter: Date?
    public var ranks: [LeaderboardPlace]
    public var ranksAt: Date?
    public var lastError: String?
    /// Leave failed on the server: no more reports, the app offers Leave again.
    public var leavePending: Bool
    /// With `leavePending`: the collector has no usable sign-in (keychain item gone, refresh token dead),
    /// so leaving needs a fresh GitHub sign-in first. Nil means false.
    public var signInRequired: Bool?
    /// The auth account (JWT `sub`) that joined; a sign-in for leaving must match it.
    public var userId: String?

    public init(joined: Bool, displayName: String? = nil, githubLogin: String? = nil, joinedAt: Date? = nil) {
        self.joined = joined
        self.displayName = displayName
        self.githubLogin = githubLogin
        self.joinedAt = joinedAt
        ranks = []
        leavePending = false
    }

    public static func path(dataDir: String) -> String { joinPath(dataDir, "leaderboard.json") }

    public static func load(dataDir: String) -> LeaderboardState? {
        guard let data = FileManager.default.contents(atPath: path(dataDir: dataDir)) else { return nil }
        return try? decoder.decode(LeaderboardState.self, from: data)
    }

    public func save(dataDir: String) throws {
        try saveAtomic(Self.path(dataDir: dataDir), Self.encoder.encode(self))
    }

    public static func remove(dataDir: String) {
        try? FileManager.default.removeItem(atPath: path(dataDir: dataDir))
    }

    public var needsSignIn: Bool { leavePending && signInRequired == true }

    public func place(period: String, unit: String) -> LeaderboardPlace? {
        ranks.first { $0.period == period && $0.unit == unit && $0.rank != nil }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

public enum LeaderboardSchedule {
    /// At most one report per 30 minutes (the server refuses more than one per 25).
    public static let interval: TimeInterval = 30 * 60
    /// Places older than this are not shown in the widget any more.
    public static let maxRankAge: TimeInterval = 3 * 60 * 60

    public static func isDue(_ s: LeaderboardState, now: Date) -> Bool {
        guard s.joined, !s.leavePending else { return false }
        if let r = s.retryAfter, now < r { return false }
        guard let last = s.lastAttemptAt else { return true }
        // a clock set back by more than an hour must not block reports forever
        return now.timeIntervalSince(last) >= interval || last.timeIntervalSince(now) > 3600
    }
}

// MARK: Server calls

public struct LeaderboardClient: Sendable {
    public let endpoint: LeaderboardEndpoint
    public let transport: HTTPTransport

    public init(endpoint: LeaderboardEndpoint, transport: HTTPTransport) {
        self.endpoint = endpoint
        self.transport = transport
    }

    private func call(_ method: String, _ path: String, token: String?, json: Any?) throws -> HTTPResponse {
        var headers = ["apikey": endpoint.key, "Content-Type": "application/json", "Accept": "application/json"]
        headers["Authorization"] = "Bearer " + (token ?? endpoint.key)
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        let r = try transport.send(
            HTTPRequest(method: method, url: endpoint.url.appendingPathComponent(path), headers: headers, body: body))
        return r
    }

    private static func message(_ r: HTTPResponse) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] {
            for k in ["error_description", "msg", "message", "error"] {
                if let m = obj[k] as? String, !m.isEmpty { return m }
            }
        }
        return String(decoding: r.body.prefix(200), as: UTF8.self)
    }

    private static func check(_ r: HTTPResponse) throws {
        switch r.status {
        case 200..<300: return
        case 401: throw LeaderboardError.unauthorized
        case 403: throw LeaderboardError.notParticipant
        case 429:
            let wait = Int(r.headers["retry-after"] ?? "") ?? 300
            throw LeaderboardError.rateLimited(max(1, wait))
        default: throw LeaderboardError.server(r.status, message(r))
        }
    }

    private func session(from r: HTTPResponse, now: Date) throws -> LeaderboardSession {
        guard let obj = try JSONSerialization.jsonObject(with: r.body) as? [String: Any],
            let access = obj["access_token"] as? String, let refresh = obj["refresh_token"] as? String
        else { throw LeaderboardError.server(r.status, "no tokens in the sign-in response") }
        let expires = (obj["expires_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            ?? now.addingTimeInterval((obj["expires_in"] as? Double) ?? 3600)
        return LeaderboardSession(accessToken: access, refreshToken: refresh, expiresAt: expires)
    }

    /// The `sub` claim of a Supabase access token (the auth user id); nil if it is not a readable JWT.
    public static func userId(fromAccessToken token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (obj["sub"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// PKCE code exchange after the GitHub sign-in.
    public func exchange(code: String, verifier: String, now: Date) throws -> LeaderboardSession {
        let r = try call("POST", "auth/v1/token", token: nil, json: ["auth_code": code, "code_verifier": verifier],
                         query: "grant_type=pkce")
        if r.status == 400 || r.status == 401 || r.status == 404 { throw LeaderboardError.server(r.status, Self.message(r)) }
        try Self.check(r)
        return try session(from: r, now: now)
    }

    public func refresh(_ s: LeaderboardSession, now: Date) throws -> LeaderboardSession {
        let r = try call("POST", "auth/v1/token", token: nil, json: ["refresh_token": s.refreshToken],
                         query: "grant_type=refresh_token")
        // an unknown or reused refresh token is a 400 from GoTrue: the sign-in is gone
        if r.status == 400 || r.status == 401 { throw LeaderboardError.unauthorized }
        try Self.check(r)
        return try session(from: r, now: now)
    }

    private func call(_ method: String, _ path: String, token: String?, json: Any?, query: String) throws
        -> HTTPResponse
    {
        var headers = ["apikey": endpoint.key, "Content-Type": "application/json", "Accept": "application/json"]
        headers["Authorization"] = "Bearer " + (token ?? endpoint.key)
        var c = URLComponents(url: endpoint.url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        c.percentEncodedQuery = query
        let body = try json.map { try JSONSerialization.data(withJSONObject: $0) }
        return try transport.send(HTTPRequest(method: method, url: c.url!, headers: headers, body: body))
    }

    /// join_leaderboard: returns (github login, display name) as the server stored them.
    public func join(displayName: String, token: String) throws -> (login: String?, name: String) {
        let r = try call("POST", "rest/v1/rpc/join_leaderboard", token: token, json: ["p_display_name": displayName])
        try Self.check(r)
        let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        return (obj?["github_login"] as? String, (obj?["display_name"] as? String) ?? displayName)
    }

    /// Whether `userId` has a leaderboard profile (RLS shows the caller its own row, joined or paused).
    public func hasProfile(userId: String, token: String) throws -> Bool {
        let r = try call("GET", "rest/v1/profiles", token: token, json: nil,
                         query: "select=id&id=eq." + (userId.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(["-"])) ?? ""))
        try Self.check(r)
        guard let rows = try? JSONSerialization.jsonObject(with: r.body) as? [Any] else {
            throw LeaderboardError.server(r.status, "unexpected answer to the profile lookup")
        }
        return !rows.isEmpty
    }

    public func leave(token: String) throws {
        try Self.check(try call("POST", "rest/v1/rpc/leave_leaderboard", token: token, json: [String: String]()))
    }

    public func deleteAccount(token: String) throws {
        try Self.check(try call("POST", "functions/v1/delete-account", token: token, json: [String: String]()))
    }

    /// POST /functions/v1/report: stores the totals and returns the caller's places.
    public func report(_ body: [String: Any], token: String) throws -> [LeaderboardPlace] {
        let r = try call("POST", "functions/v1/report", token: token, json: body)
        try Self.check(r)
        let obj = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any]
        return Self.places(obj?["ranks"])
    }

    public func myRanks(token: String) throws -> [LeaderboardPlace] {
        let r = try call("POST", "rest/v1/rpc/my_ranks", token: token, json: [String: String]())
        try Self.check(r)
        return Self.places(try? JSONSerialization.jsonObject(with: r.body))
    }

    static func places(_ any: Any?) -> [LeaderboardPlace] {
        guard let rows = any as? [[String: Any]] else { return [] }
        func int(_ v: Any?) -> Int? {
            if let n = v as? NSNumber { return n.intValue }
            if let s = v as? String { return Int(s) }
            return nil
        }
        return rows.compactMap { row in
            guard let p = row["period"] as? String, let u = row["unit"] as? String else { return nil }
            return LeaderboardPlace(period: p, unit: u, rank: int(row["rank"]), participants: int(row["participants"]) ?? 0)
        }
    }
}

// MARK: The collector's part

/// Join, leave and the periodic report. `transport` is called only when the user has joined.
public struct LeaderboardSync: Sendable {
    public let dataDir: String
    public let endpoint: LeaderboardEndpoint?
    public let sessions: SessionStore
    public let transport: @Sendable () -> HTTPTransport

    public init(
        dataDir: String, endpoint: LeaderboardEndpoint?, sessions: SessionStore,
        transport: @escaping @Sendable () -> HTTPTransport
    ) {
        self.dataDir = dataDir
        self.endpoint = endpoint
        self.sessions = sessions
        self.transport = transport
    }

    private func client() throws -> LeaderboardClient {
        guard let endpoint else { throw LeaderboardError.noServer }
        return LeaderboardClient(endpoint: endpoint, transport: transport())
    }

    /// A session whose access token is valid for at least another minute (refreshed and saved if needed).
    private func validSession(_ c: LeaderboardClient, now: Date, forceRefresh: Bool = false) throws -> LeaderboardSession {
        guard let s = sessions.load() else { throw LeaderboardError.notSignedIn }
        if !forceRefresh, s.expiresAt.timeIntervalSince(now) > 60 { return s }
        let fresh = try c.refresh(s, now: now)
        try sessions.save(fresh)
        return fresh
    }

    /// Runs `body` with a valid access token; after a 401 it refreshes once and tries again.
    private func authorized<T>(_ c: LeaderboardClient, now: Date, _ body: (String) throws -> T) throws -> T {
        // a failing refresh is final (no second refresh); only a 401 from `body` earns one more try
        let session = try validSession(c, now: now)
        do {
            return try body(session.accessToken)
        } catch LeaderboardError.unauthorized {
            return try body(try validSession(c, now: now, forceRefresh: true).accessToken)
        }
    }

    public static func cleanDisplayName(_ name: String) -> String? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...32).contains(t.count) ? t : nil
    }

    /// After the GitHub sign-in: exchange the code, keep the tokens, join. The first report follows with
    /// the next collector pass (no waiting: lastAttemptAt is empty). The sign-in itself creates an account on
    /// the server; when joining fails after it, that account is deleted again (or, if the server cannot be
    /// reached, kept as a pending leave so the app offers Leave Again instead of forgetting it).
    /// Without a display name the server takes the GitHub username (join_leaderboard with ''); the app offers
    /// to change it afterwards (`rename`).
    public func join(code: String, verifier: String, displayName: String?, now: Date = Date()) throws -> LeaderboardState {
        var name = ""
        if let displayName {
            guard let cleaned = Self.cleanDisplayName(displayName) else { throw Self.badName }
            name = cleaned
        }
        let c = try client()
        let session = try c.exchange(code: code, verifier: verifier, now: now)
        let userId = LeaderboardClient.userId(fromAccessToken: session.accessToken)
        do {
            try sessions.save(session)
            let joined = try c.join(displayName: name, token: session.accessToken)
            var state = LeaderboardState(joined: true, displayName: joined.name, githubLogin: joined.login, joinedAt: now)
            state.userId = userId
            state.lastError = nil
            try state.save(dataDir: dataDir)
            return state
        } catch {
            do {
                try c.deleteAccount(token: session.accessToken)
                sessions.delete()
            } catch let cleanup {
                var state = LeaderboardState(joined: false, joinedAt: now)
                state.userId = userId
                state.leavePending = true
                state.signInRequired = sessions.load() == nil
                state.lastError = "Joining failed, and the account the sign-in created on the leaderboard server could not be deleted yet: \(cleanup)"
                try? state.save(dataDir: dataDir)
            }
            throw error
        }
    }

    static let badName = LeaderboardError.server(0, "The display name needs 1 to 32 characters.")

    /// Changes the display name of a joined account (join_leaderboard again: the server updates the name and
    /// keeps the opt-in). Sends nothing unless this Mac has joined.
    public func rename(displayName: String) throws -> LeaderboardState {
        guard let name = Self.cleanDisplayName(displayName) else { throw Self.badName }
        guard var state = LeaderboardState.load(dataDir: dataDir), state.joined, !state.leavePending else {
            throw LeaderboardError.notParticipant
        }
        let c = try client()
        let joined = try authorized(c, now: Date()) { try c.join(displayName: name, token: $0) }
        state.displayName = joined.name
        if let login = joined.login { state.githubLogin = login }
        try state.save(dataDir: dataDir)
        return state
    }

    /// Deletes the account on the server (profile and totals go with it), then the local tokens and state.
    /// Succeeds only when delete-account confirmed it, or when this Mac never joined. Otherwise the reports
    /// stop, the state says leavePending, and the app offers Leave Again; without a usable sign-in
    /// (keychain item gone, refresh token dead) it asks for a fresh GitHub sign-in, whose code and verifier
    /// come in as `signIn`.
    public func leave(signIn: (code: String, verifier: String)? = nil, now: Date = Date()) throws {
        let state = LeaderboardState.load(dataDir: dataDir)
        do {
            if let signIn {
                let c = try client()
                let fresh = try c.exchange(code: signIn.code, verifier: signIn.verifier, now: now)
                if let expected = state?.userId, let got = LeaderboardClient.userId(fromAccessToken: fresh.accessToken),
                    expected != got
                {
                    // The sign-in created (or reused) the server account of another GitHub user. Delete it again
                    // unless that account takes part in the leaderboard itself (then it is someone's entry, maybe
                    // from another Mac, and stays). When the lookup fails, nothing is deleted.
                    if (try? c.hasProfile(userId: got, token: fresh.accessToken)) == false {
                        try? c.deleteAccount(token: fresh.accessToken)
                    }
                    throw LeaderboardError.otherAccount
                }
                try sessions.save(fresh)
            }
            guard sessions.load() != nil else {
                // nothing to authenticate with: done only if this Mac never joined
                guard let state, state.joined || state.leavePending else {
                    LeaderboardState.remove(dataDir: dataDir)
                    return
                }
                throw LeaderboardError.notSignedIn
            }
            let c = try client()
            try authorized(c, now: now) { token in
                do {
                    try c.deleteAccount(token: token)
                } catch LeaderboardError.server(let status, let why) where status == 404 || status >= 500 {
                    // the function is missing or failing: delete profile and totals at least, but the account
                    // stays, so this is not a finished leave
                    let removed = (try? c.leave(token: token)) != nil
                    throw LeaderboardError.accountNotDeleted(entryRemoved: removed, "\(status) \(why)")
                }
            }
        } catch {
            var pending = state ?? LeaderboardState(joined: false)
            pending.joined = false
            pending.leavePending = true
            pending.ranks = []
            pending.ranksAt = nil
            switch error {
            case LeaderboardError.unauthorized, LeaderboardError.notSignedIn:
                sessions.delete()  // a dead sign-in: the next try starts with a fresh one
                pending.signInRequired = true
            case LeaderboardError.otherAccount:
                pending.signInRequired = true
            default:
                pending.signInRequired = sessions.load() == nil
            }
            pending.lastError = "Could not delete your entry on the server: \(error)"
            try? pending.save(dataDir: dataDir)
            throw error
        }
        sessions.delete()
        LeaderboardState.remove(dataDir: dataDir)
    }

    /// Six period totals as /functions/v1/report expects them, from the widget data.
    static func reportBody(_ widget: JSONValue) -> [String: Any]? {
        guard let periods = widget["periods"] else { return nil }
        var out: [String: Any] = [:]
        for key in periodOrder {
            guard let p = periods[key], let start = p["from"]?.string else { return nil }
            let usd: Double
            switch p["usd"] {
            case .double(let d)?: usd = d
            case .int(let i)?: usd = Double(i)
            default: usd = 0
            }
            out[key] = ["input": p["input"]?.intValue ?? 0, "output": p["output"]?.intValue ?? 0, "usd": usd, "start": start]
        }
        return ["periods": out]
    }

    /// widget.json "ranks": {"1D": {"tokens": {"rank": 3, "of": 12}, "usd": …}, …}; only places that exist.
    static func widgetRanks(_ places: [LeaderboardPlace]) -> JSONValue? {
        var periods = OrderedDict<JSONValue>()
        for key in periodOrder {
            var units = OrderedDict<JSONValue>()
            for unit in ["tokens", "usd"] {
                guard let p = places.first(where: { $0.period == key && $0.unit == unit }), let rank = p.rank,
                    rank > 0, p.participants >= rank
                else { continue }
                var o = OrderedDict<JSONValue>()
                o["rank"] = .int(rank)
                o["of"] = .int(p.participants)
                units[unit] = .object(o)
            }
            if !units.isEmpty { periods[key] = .object(units) }
        }
        return periods.isEmpty ? nil : .object(periods)
    }

    /// The collector's step: without a joined state nothing happens (no request, widget unchanged). With one,
    /// report when due (at most every 30 minutes), keep the places, and add fresh places to the widget data.
    func apply(widget: JSONValue, now: Date) -> (widget: JSONValue, log: String?) {
        guard var state = LeaderboardState.load(dataDir: dataDir), state.joined else { return (widget, nil) }
        var log: String?
        if LeaderboardSchedule.isDue(state, now: now) {
            state.lastAttemptAt = now
            do {
                guard let body = Self.reportBody(widget) else { throw LeaderboardError.server(0, "no totals to report") }
                let c = try client()
                var places: [LeaderboardPlace]
                do {
                    places = try authorized(c, now: now) { try c.report(body, token: $0) }
                    state.lastReportAt = now
                } catch LeaderboardError.rateLimited(let wait) {
                    state.retryAfter = now.addingTimeInterval(TimeInterval(wait))
                    places = try authorized(c, now: now) { try c.myRanks(token: $0) }
                }
                state.ranks = places
                state.ranksAt = now
                state.lastError = nil
                log = "leaderboard: reported, \(places.filter { $0.rank != nil }.count) places"
            } catch LeaderboardError.notParticipant {
                state.joined = false
                state.ranks = []
                state.ranksAt = nil
                state.lastError = LeaderboardError.notParticipant.description
                log = "leaderboard: no longer a participant"
            } catch {
                state.lastError = "\(error)"
                log = "leaderboard: report failed: \(error)"
            }
            try? state.save(dataDir: dataDir)
        }
        guard state.joined, let at = state.ranksAt, now.timeIntervalSince(at) < LeaderboardSchedule.maxRankAge,
            at.timeIntervalSince(now) < 3600, let ranks = Self.widgetRanks(state.ranks), case .object(var o) = widget
        else { return (widget, log) }
        o["ranks"] = ranks
        return (.object(o), log)
    }
}
