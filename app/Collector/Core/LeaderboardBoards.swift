import Foundation
import ImageIO

// The app's leaderboard window: the twelve boards (6 periods x 2 units) and the participants' GitHub avatars.
// Both are fetched by the collector after its report, so only after the user joined (LeaderboardSync.apply), and
// written to the data folder; the app only reads the files. Leave deletes them.

/// One row of a board as leaderboard_top() returns it.
public struct LeaderboardEntry: Codable, Equatable, Sendable {
    public var rank: Int
    public var displayName: String
    public var githubLogin: String?
    public var value: Double
    public var isMe: Bool

    public init(rank: Int, displayName: String, githubLogin: String?, value: Double, isMe: Bool) {
        self.rank = rank
        self.displayName = displayName
        self.githubLogin = githubLogin
        self.value = value
        self.isMe = isMe
    }
}

/// One board: its rows (top places, then the own row if it is outside them) and how many take part.
public struct LeaderboardBoard: Codable, Equatable, Sendable {
    public var period: String
    public var unit: String
    public var participants: Int
    public var entries: [LeaderboardEntry]

    public init(period: String, unit: String, participants: Int, entries: [LeaderboardEntry]) {
        self.period = period
        self.unit = unit
        self.participants = participants
        self.entries = entries
    }
}

/// `<data dir>/leaderboard-top.json`.
public struct LeaderboardBoards: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var boards: [LeaderboardBoard]

    public init(fetchedAt: Date, boards: [LeaderboardBoard]) {
        self.fetchedAt = fetchedAt
        self.boards = boards
    }

    public static let limit = 50

    public static func path(dataDir: String) -> String { joinPath(dataDir, "leaderboard-top.json") }

    public static func load(dataDir: String) -> LeaderboardBoards? {
        guard let data = FileManager.default.contents(atPath: path(dataDir: dataDir)) else { return nil }
        return try? LeaderboardState.decoder.decode(LeaderboardBoards.self, from: data)
    }

    public func save(dataDir: String) throws {
        try saveAtomic(Self.path(dataDir: dataDir), LeaderboardState.encoder.encode(self))
    }

    public func board(period: String, unit: String) -> LeaderboardBoard? {
        boards.first { $0.period == period && $0.unit == unit }
    }

    /// GitHub usernames in board order (first boards first), each once.
    public var logins: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for b in boards {
            for e in b.entries {
                if let l = e.githubLogin, AvatarCache.isValidLogin(l), seen.insert(l.lowercased()).inserted { out.append(l) }
            }
        }
        return out
    }

    /// Rows of leaderboard_top(), grouped by board in the order they came.
    static func from(rows: Any?, now: Date) -> LeaderboardBoards? {
        guard let rows = rows as? [[String: Any]] else { return nil }
        func int(_ v: Any?) -> Int? {
            if let n = v as? NSNumber { return n.intValue }
            if let s = v as? String { return Int(s) }
            return nil
        }
        func double(_ v: Any?) -> Double? {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
            return nil
        }
        var boards: [LeaderboardBoard] = []
        for row in rows {
            guard let p = row["period"] as? String, let u = row["unit"] as? String, let rank = int(row["rank"]),
                let name = row["display_name"] as? String
            else { continue }
            let entry = LeaderboardEntry(
                rank: rank, displayName: name, githubLogin: row["github_login"] as? String,
                value: double(row["value"]) ?? 0, isMe: row["is_me"] as? Bool == true)
            if let i = boards.firstIndex(where: { $0.period == p && $0.unit == u }) {
                boards[i].entries.append(entry)
            } else {
                boards.append(LeaderboardBoard(period: p, unit: u, participants: int(row["participants"]) ?? 0, entries: [entry]))
            }
        }
        return LeaderboardBoards(fetchedAt: now, boards: boards)
    }

    static func remove(dataDir: String) {
        try? FileManager.default.removeItem(atPath: path(dataDir: dataDir))
    }
}

extension LeaderboardClient {
    /// rpc/leaderboard_top: all twelve boards, top `limit` places plus the caller's own row.
    public func top(limit: Int = LeaderboardBoards.limit, token: String, now: Date) throws -> LeaderboardBoards {
        let r = try call("POST", "rest/v1/rpc/leaderboard_top", token: token, json: ["p_limit": limit])
        try Self.check(r)
        guard let boards = LeaderboardBoards.from(rows: try? JSONSerialization.jsonObject(with: r.body), now: now) else {
            throw LeaderboardError.server(r.status, "unexpected answer to leaderboard_top")
        }
        return boards
    }
}

/// GitHub avatars of the listed participants, `<data dir>/avatars/<login>.png`. Downloaded from
/// avatars.githubusercontent.com by username, without any header of ours (no key, no token, no cookie), at most
/// `perPass` per collector pass and again after `maxAge`. The app shows a placeholder until the file exists.
public struct AvatarCache: Sendable {
    public let dataDir: String
    public static let host = "avatars.githubusercontent.com"
    public static let perPass = 12
    public static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    public static let maxBytes = 256 * 1024
    /// 2x the size the window draws (28 pt).
    public static let pixels = 64

    public init(dataDir: String) { self.dataDir = dataDir }

    public static func directory(dataDir: String) -> String { joinPath(dataDir, "avatars") }

    /// GitHub usernames: letters, digits and single hyphens, at most 39 characters (nothing that can leave the folder).
    public static func isValidLogin(_ login: String) -> Bool {
        guard (1...39).contains(login.count), !login.hasPrefix("-"), !login.hasSuffix("-") else { return false }
        return login.unicodeScalars.allSatisfy { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" }
    }

    public static func file(dataDir: String, login: String) -> String? {
        guard isValidLogin(login) else { return nil }
        return joinPath(directory(dataDir: dataDir), login.lowercased() + ".png")
    }

    public static func url(login: String) -> URL? {
        guard isValidLogin(login) else { return nil }
        return URL(string: "https://\(host)/\(login)?s=\(pixels)")
    }

    /// Logins whose picture is missing or older than `maxAge`, at most `perPass`.
    func due(_ logins: [String], now: Date) -> [String] {
        let fm = FileManager.default
        return Array(logins.filter { login in
            guard let f = Self.file(dataDir: dataDir, login: login) else { return false }
            guard let attrs = try? fm.attributesOfItem(atPath: f), let m = attrs[.modificationDate] as? Date else { return true }
            return now.timeIntervalSince(m) > Self.maxAge || m.timeIntervalSince(now) > 3600
        }.prefix(Self.perPass))
    }

    /// Downloads what is due; returns how many pictures were stored. Failures only skip that picture.
    @discardableResult
    func refresh(_ logins: [String], transport: HTTPTransport, now: Date) -> Int {
        let due = due(logins, now: now)
        guard !due.isEmpty else { return 0 }
        try? FileManager.default.createDirectory(atPath: Self.directory(dataDir: dataDir), withIntermediateDirectories: true)
        var stored = 0
        for login in due {
            guard let url = Self.url(login: login), let file = Self.file(dataDir: dataDir, login: login),
                let r = try? transport.send(HTTPRequest(method: "GET", url: url, headers: [:], body: nil)),
                r.status == 200, Self.isImage(r.body)
            else { continue }
            if (try? saveAtomic(file, r.body)) != nil { stored += 1 }
        }
        return stored
    }

    /// A PNG/JPEG/GIF ImageIO can read, below `maxBytes`.
    static func isImage(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maxBytes,
            let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0,
            let type = CGImageSourceGetType(src) as String?
        else { return false }
        return ["public.png", "public.jpeg", "com.compuserve.gif"].contains(type)
    }

    static func remove(dataDir: String) {
        try? FileManager.default.removeItem(atPath: directory(dataDir: dataDir))
    }
}
