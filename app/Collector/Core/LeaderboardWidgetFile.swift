import Foundation

// The leaderboard widget's copy of the boards. The widget runs in a sandbox and sees only the App Group container,
// not the data folder with leaderboard-top.json and avatars/. So after every pass, and after join, rename and
// leave, the collector writes `leaderboard-widget.json` next to widget.json: per board the first `places` rows plus
// the own row, the same for every group the user is in (`groups`, absent until the collector fetched them), and the
// cached avatars of exactly these people, embedded. Not joined: the file is removed, which is how the widget knows
// (and what Leave promises). Read by Shared/LeaderboardWidgetData.swift; a widget of an older build ignores `groups`.

/// One group in the widget's copy: id and name (the widget's "Edit Widget" list) and its trimmed boards.
public struct LeaderboardWidgetGroup: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var boards: [LeaderboardBoard]

    public init(id: String, name: String, boards: [LeaderboardBoard]) {
        self.id = id
        self.name = name
        self.boards = boards
    }
}

public struct LeaderboardWidgetFile: Codable, Equatable, Sendable {
    /// When the collector fetched the boards; nil while joined but nothing fetched yet.
    public var fetchedAt: Date?
    public var boards: [LeaderboardBoard]
    /// The user's groups; nil while the collector has not fetched them (the widget then waits instead of saying
    /// "you left this group").
    public var groups: [LeaderboardWidgetGroup]?
    /// GitHub username (lower case) → PNG/JPEG/GIF bytes (base64 in the JSON).
    public var avatars: [String: Data]

    public init(fetchedAt: Date?, boards: [LeaderboardBoard], groups: [LeaderboardWidgetGroup]? = nil,
                avatars: [String: Data]) {
        self.fetchedAt = fetchedAt
        self.boards = boards
        self.groups = groups
        self.avatars = avatars
    }

    public static let fileName = "leaderboard-widget.json"
    /// The pass's log line when the file changed; the CLI then asks WidgetKit for a reload.
    public static let updatedLog = "leaderboard widget: updated"
    /// The large widget shows eight places.
    public static let places = 8
    /// Bigger pictures are left out (the widget draws a letter instead); the cache asks GitHub for 64 px.
    public static let maxAvatarBytes = 64 * 1024
    /// At most this many pictures in the file (global boards first, then the groups'); the rest get a letter.
    public static let maxAvatars = 80

    /// `<directory of widget.json>/leaderboard-widget.json`.
    public static func path(widgetPath: String) -> String {
        joinPath((widgetPath as NSString).deletingLastPathComponent, fileName)
    }

    /// What the widget gets for this state: nil when not joined.
    public static func make(state: LeaderboardState?, boards: LeaderboardBoards?, groups: LeaderboardGroups? = nil,
                            dataDir: String) -> LeaderboardWidgetFile? {
        guard let state, state.joined else { return nil }
        // the global boards may not be fetched yet while the groups are (a group action right after joining): the
        // groups go in all the same, so Edit Widget lists them and a group widget does not wait for the global boards
        let trimmed = boards.map(trim) ?? LeaderboardBoards(fetchedAt: .distantPast, boards: [])
        let widgetGroups = groups.map { g in
            g.groups.map { d in
                LeaderboardWidgetGroup(id: d.group.id, name: d.group.name,
                                       boards: trim(LeaderboardBoards(fetchedAt: g.fetchedAt, boards: d.boards)).boards)
            }
        }
        let groupBoards = LeaderboardBoards(fetchedAt: trimmed.fetchedAt, boards: (widgetGroups ?? []).flatMap(\.boards))
        var seen = Set<String>()
        var avatars: [String: Data] = [:]
        for login in (trimmed.logins + groupBoards.logins) where seen.insert(login.lowercased()).inserted {
            guard avatars.count < maxAvatars, let file = AvatarCache.file(dataDir: dataDir, login: login),
                let data = FileManager.default.contents(atPath: file), data.count <= maxAvatarBytes
            else { continue }
            avatars[login.lowercased()] = data
        }
        return LeaderboardWidgetFile(fetchedAt: boards?.fetchedAt, boards: trimmed.boards, groups: widgetGroups,
                                     avatars: avatars)
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
    public static func avatarOrder(_ boards: LeaderboardBoards, groups: LeaderboardGroups? = nil) -> [String] {
        var seen = Set<String>()
        let groupBoards = LeaderboardBoards(fetchedAt: boards.fetchedAt, boards: groups?.groups.flatMap(\.boards) ?? [])
        return (trim(boards).logins + trim(groupBoards).logins + boards.logins + groupBoards.logins)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    /// Brings the widget's file in line with the data folder. Returns true when it changed (worth a widget reload).
    @discardableResult
    public static func sync(dataDir: String, widgetPath: String) -> Bool {
        let target = path(widgetPath: widgetPath)
        let fm = FileManager.default
        guard let file = make(state: LeaderboardState.load(dataDir: dataDir), boards: LeaderboardBoards.load(dataDir: dataDir),
                              groups: LeaderboardGroups.load(dataDir: dataDir), dataDir: dataDir)
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
