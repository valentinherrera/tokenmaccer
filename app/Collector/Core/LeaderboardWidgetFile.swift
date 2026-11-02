import Foundation

// The leaderboard widget's copy of the boards. The widget runs in a sandbox and sees only the App Group container,
// not the data folder with leaderboard-top.json and avatars/. So after every pass, and after join, rename and
// leave, the collector writes `leaderboard-widget.json` next to widget.json: per board the first `places` rows plus
// the own row, and the cached avatars of exactly these people, embedded. Not joined: the file is removed, which is
// how the widget knows (and what Leave promises). Read by Shared/LeaderboardWidgetData.swift.

public struct LeaderboardWidgetFile: Codable, Equatable, Sendable {
    /// When the collector fetched the boards; nil while joined but nothing fetched yet.
    public var fetchedAt: Date?
    public var boards: [LeaderboardBoard]
    /// GitHub username (lower case) → PNG/JPEG/GIF bytes (base64 in the JSON).
    public var avatars: [String: Data]

    public init(fetchedAt: Date?, boards: [LeaderboardBoard], avatars: [String: Data]) {
        self.fetchedAt = fetchedAt
        self.boards = boards
        self.avatars = avatars
    }

    public static let fileName = "leaderboard-widget.json"
    /// The pass's log line when the file changed; the CLI then asks WidgetKit for a reload.
    public static let updatedLog = "leaderboard widget: updated"
    /// The large widget shows eight places.
    public static let places = 8
    /// Bigger pictures are left out (the widget draws a letter instead); the cache asks GitHub for 64 px.
    public static let maxAvatarBytes = 64 * 1024

    /// `<directory of widget.json>/leaderboard-widget.json`.
    public static func path(widgetPath: String) -> String {
        joinPath((widgetPath as NSString).deletingLastPathComponent, fileName)
    }

    /// What the widget gets for this state: nil when not joined.
    public static func make(state: LeaderboardState?, boards: LeaderboardBoards?, dataDir: String) -> LeaderboardWidgetFile? {
        guard let state, state.joined else { return nil }
        guard let boards else { return LeaderboardWidgetFile(fetchedAt: nil, boards: [], avatars: [:]) }
        let trimmed = trim(boards)
        var avatars: [String: Data] = [:]
        for login in trimmed.logins {
            guard let file = AvatarCache.file(dataDir: dataDir, login: login),
                let data = FileManager.default.contents(atPath: file), data.count <= maxAvatarBytes
            else { continue }
            avatars[login.lowercased()] = data
        }
        return LeaderboardWidgetFile(fetchedAt: boards.fetchedAt, boards: trimmed.boards, avatars: avatars)
    }

    /// Per board the first `places` rows and the own row.
    static func trim(_ boards: LeaderboardBoards) -> LeaderboardBoards {
        LeaderboardBoards(fetchedAt: boards.fetchedAt, boards: boards.boards.map { b in
            var rows = Array(b.entries.prefix(places))
            if !rows.contains(where: { $0.isMe }), let me = b.entries.first(where: { $0.isMe }) { rows.append(me) }
            return LeaderboardBoard(period: b.period, unit: b.unit, participants: b.participants, entries: rows)
        })
    }

    /// Avatar download order: the people the widget shows first (12 per pass would otherwise go to the first
    /// boards' 50 places), then the rest of the window's boards.
    public static func avatarOrder(_ boards: LeaderboardBoards) -> [String] {
        var seen = Set<String>()
        return (trim(boards).logins + boards.logins).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Brings the widget's file in line with the data folder. Returns true when it changed (worth a widget reload).
    @discardableResult
    public static func sync(dataDir: String, widgetPath: String) -> Bool {
        let target = path(widgetPath: widgetPath)
        let fm = FileManager.default
        guard let file = make(state: LeaderboardState.load(dataDir: dataDir), boards: LeaderboardBoards.load(dataDir: dataDir),
                              dataDir: dataDir)
        else {
            guard fm.fileExists(atPath: target) else { return false }
            // Leave promises this removal; a failure leaves the file and the next pass tries again
            return (try? fm.removeItem(atPath: target)) != nil
        }
        guard let data = try? encoder.encode(file) else { return false }
        if fm.contents(atPath: target) == data { return false }
        return (try? saveAtomic(target, data)) != nil
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        e.outputFormatting = [.sortedKeys]  // same content, same bytes: no rewrite every 5 minutes
        return e
    }()
}
