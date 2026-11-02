import Foundation

// Board values shared by the app's leaderboard window and the leaderboard widget, and the widget's file
// (leaderboard-widget.json in the App Group container, written by the collector: Collector/Core/LeaderboardWidgetFile).
// Plain values, no SwiftUI: the unit tests compile this file.

struct BoardRowValue: Equatable, Identifiable {
    var rank: Int
    var name: String
    var login: String?
    var value: Double
    var isMe: Bool
    var id: String { "\(rank)-\(login ?? name)-\(isMe)" }
}

struct BoardValue: Equatable {
    var participants: Int
    /// The first places, in order.
    var top: [BoardRowValue]
    /// The own row when it is not among `top` (shown below a gap).
    var own: BoardRowValue?

    var me: BoardRowValue? { own ?? top.first { $0.isMe } }

    /// The first `places` rows; the own row separately when it comes later. leaderboard_top() lists the first places,
    /// then the own row if it is not among them.
    init(participants: Int, rows: [BoardRowValue], places: Int) {
        self.participants = participants
        top = Array(rows.prefix(places))
        own = top.contains { $0.isMe } ? nil : rows.dropFirst(places).first { $0.isMe }
    }

    init(participants: Int, top: [BoardRowValue], own: BoardRowValue?) {
        self.participants = participants
        self.top = top
        self.own = own
    }
}

enum BoardState: Equatable {
    case notJoined
    /// Joined, but the collector has not fetched the boards yet.
    case waiting
    /// nil: nobody has a current total for this period and unit.
    case board(BoardValue?)
    /// A group was chosen that the user is no longer in (left, removed, or the group was deleted).
    case groupGone
}

/// leaderboard-widget.json. A missing file means: not joined (Leave removes it).
struct LeaderboardWidgetData: Decodable {
    struct Entry: Decodable {
        let rank: Int
        let displayName: String
        let githubLogin: String?
        let value: Double
        let isMe: Bool
    }

    struct Board: Decodable {
        let period: String
        let unit: String
        let participants: Int
        let entries: [Entry]
    }

    /// A group the user is in, with its boards (trimmed like the global ones).
    struct Group: Decodable {
        let id: String
        let name: String
        let boards: [Board]
    }

    let fetchedAt: Date?
    let boards: [Board]
    /// lower-case GitHub username → image bytes
    let avatars: [String: Data]
    /// nil: not fetched yet, or written by an older collector (both read as "waiting" for a group widget).
    var groups: [Group]? = nil

    static let fileName = "leaderboard-widget.json"

    static var defaultURL: URL? {
        WidgetData.defaultURL?.deletingLastPathComponent().appendingPathComponent(fileName)
    }

    static func decode(_ bytes: Data) -> LeaderboardWidgetData? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return try? d.decode(LeaderboardWidgetData.self, from: bytes)
    }

    /// nil only when there is no file (not joined). A file that exists but cannot be read counts as joined and
    /// waiting, so a joined user is never asked to join again.
    static func load(from url: URL? = defaultURL) -> LeaderboardWidgetData? {
        guard let url, let bytes = try? Data(contentsOf: url) else { return nil }
        return decode(bytes) ?? LeaderboardWidgetData(fetchedAt: nil, boards: [], avatars: [:])
    }

    /// The widget gallery's board: made-up names, no pictures.
    static let sample: LeaderboardWidgetData = {
        let names = ["Mara", "octo-dev", "Jonas", "Priya", "Theo", "Ana", "kenji", "Lena"]
        let entries = names.enumerated().map { i, n in
            Entry(rank: i + 1, displayName: n, githubLogin: nil, value: 800_000_000 / Double(i + 1), isMe: i == 4)
        }
        let boards = Selection.periods.flatMap { p in
            ["tokens", "usd"].map { Board(period: p, unit: $0, participants: 120, entries: entries) }
        }
        return LeaderboardWidgetData(fetchedAt: Date(), boards: boards, avatars: [:])
    }()

    func avatar(_ login: String?) -> Data? { login.flatMap { avatars[$0.lowercased()] } }

    func group(_ id: String?) -> Group? {
        guard let id else { return nil }
        return groups?.first { $0.id.lowercased() == id.lowercased() }
    }

    /// The widget's state for one board; `data` nil = not joined. `group`: a group's id, nil for the global board. A
    /// group missing from a fetched list is gone, never silently replaced by the global board.
    static func state(_ data: LeaderboardWidgetData?, group: String? = nil, period: String, unit: Unit, places: Int)
        -> BoardState
    {
        guard let data else { return .notJoined }
        var boards = data.boards
        if let group {
            // a group's board needs only the group list, not the global boards
            guard let list = data.groups else { return .waiting }
            guard let g = list.first(where: { $0.id.lowercased() == group.lowercased() }) else { return .groupGone }
            boards = g.boards
        } else if data.fetchedAt == nil {
            return .waiting
        }
        guard let b = boards.first(where: { $0.period == period && $0.unit == unit.rawValue }), !b.entries.isEmpty
        else { return .board(nil) }
        let rows = b.entries.map {
            BoardRowValue(rank: $0.rank, name: $0.displayName, login: $0.githubLogin, value: $0.value, isMe: $0.isMe)
        }
        return .board(BoardValue(participants: b.participants, rows: rows, places: places))
    }
}

/// Period and unit of the leaderboard widget, its own pair beside the usage widget's (Selection).
enum BoardSelection {
    static var period: String {
        get { Selection.defaults.string(forKey: "boardPeriod") ?? "1D" }
        set { Selection.defaults.set(newValue, forKey: "boardPeriod") }
    }
    static var unit: Unit {
        get { Unit(rawValue: Selection.defaults.string(forKey: "boardUnit") ?? "tokens") ?? .tokens }
        set { Selection.defaults.set(newValue.rawValue, forKey: "boardUnit") }
    }

    // MARK: Board switched with a click on the widget's title

    /// Stored value for the global board (nil cannot be stored as "chosen").
    static let globalKey = "global"

    /// A widget has no id of its own, so the clicked board is kept per board chosen with "Edit Widget": widgets with the
    /// same choice switch together, and choosing another board with Edit Widget starts from that board.
    private static func overrideKey(_ configured: String?) -> String {
        "boardClicked." + (configured?.lowercased() ?? globalKey)
    }

    /// The board a widget shows: the clicked one, else its Edit Widget choice. nil = global, else a group's id. A
    /// clicked group the user is no longer in falls back to the choice (the choice itself still shows "no longer in
    /// this group").
    static func board(configured: String?, defaults: UserDefaults = Selection.defaults,
                      groups: [String]?) -> String?
    {
        guard let stored = defaults.string(forKey: overrideKey(configured)) else { return configured }
        if stored == globalKey { return nil }
        if let groups, !groups.contains(where: { $0.lowercased() == stored.lowercased() }) { return configured }
        return stored
    }

    /// The board after `current` in the order global → the user's groups → global. A current board that is no longer in
    /// the list goes back to global.
    static func next(after current: String?, groups: [String]) -> String? {
        guard let current else { return groups.first }
        guard let i = groups.firstIndex(where: { $0.lowercased() == current.lowercased() }), i + 1 < groups.count
        else { return nil }
        return groups[i + 1]
    }

    static func setBoard(_ board: String?, configured: String?, defaults: UserDefaults = Selection.defaults) {
        defaults.set(board ?? globalKey, forKey: overrideKey(configured))
    }
}
