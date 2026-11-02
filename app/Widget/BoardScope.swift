import AppIntents
import WidgetKit

/// The board a leaderboard widget shows, chosen with "Edit Widget": the global leaderboard or one of the user's groups
/// (like the Stocks widget's watchlist). The groups come from the widget's copy of the boards
/// (leaderboard-widget.json), so the list needs no network and shows only groups the user is in.
struct BoardScopeEntity: AppEntity {
    static let globalID = "global"

    let id: String
    let name: String

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Board")
    static let defaultQuery = BoardScopeQuery()

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    static var global: BoardScopeEntity {
        BoardScopeEntity(id: globalID, name: String(localized: "Global"))
    }

    /// nil for the global board.
    var groupID: String? { id == Self.globalID ? nil : id }
}

struct BoardScopeQuery: EntityQuery {
    /// Every id gets an entity back, also a group the user is no longer in: dropping it would resolve the widget's
    /// choice to nothing, and the widget would show the global board without a word. Kept, it shows "You're no longer
    /// in this group".
    func entities(for identifiers: [BoardScopeEntity.ID]) async throws -> [BoardScopeEntity] {
        let groups = LeaderboardWidgetData.load()?.groups ?? []
        return identifiers.map { id in
            if id == BoardScopeEntity.globalID { return .global }
            if let g = groups.first(where: { $0.id.lowercased() == id.lowercased() }) {
                return BoardScopeEntity(id: g.id, name: g.name)
            }
            return BoardScopeEntity(id: id, name: String(localized: "Former group"))
        }
    }

    func suggestedEntities() async throws -> [BoardScopeEntity] {
        [.global] + (LeaderboardWidgetData.load()?.groups ?? []).map { BoardScopeEntity(id: $0.id, name: $0.name) }
    }

    func defaultResult() async -> BoardScopeEntity? { .global }
}

/// The leaderboard widget's configuration. No choice (widgets placed before groups existed) means the global board.
struct LeaderboardScopeIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Leaderboard"
    static let description = IntentDescription("Choose the global leaderboard or one of your groups.")

    @Parameter(title: "Board") var scope: BoardScopeEntity?

    init() {}
}
