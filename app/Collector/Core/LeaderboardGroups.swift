import Foundation

// Groups: compare with friends through an invitation link (server: supabase/migrations/20261102130000_groups.sql).
// A group is a filter on the leaderboard's participants, so everything here needs a joined state. The app asks the
// collector (`tokenmaccer-collector leaderboard group …`) for every change; after it, and after every report, the
// collector fetches the caller's groups, their members and their boards into `<data dir>/leaderboard-groups.json`.
// Leave removes the file with the boards (LeaderboardSync.removeBoards).
//
// Errors: a group call has its own mapping (GroupError). LeaderboardClient.check turns HTTP 403 into
// .notParticipant, which the collector reads as "left the leaderboard"; a 403 from a group function only means
// "not the owner / not a member" (SQLSTATE PT403) and must never flip the joined state.

/// One group as group_info returns it.
public struct LeaderboardGroup: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var code: String
    public var isOwner: Bool
    public var members: Int

    public init(id: String, name: String, code: String, isOwner: Bool, members: Int) {
        self.id = id
        self.name = name
        self.code = code
        self.isOwner = isOwner
        self.members = members
    }

    /// A group_info object; nil for join_group's answer to an unknown code (all fields null).
    static func from(_ any: Any?) -> LeaderboardGroup? {
        guard let o = any as? [String: Any], let id = o["id"] as? String, !id.isEmpty, let name = o["name"] as? String
        else { return nil }
        return LeaderboardGroup(id: id.lowercased(), name: name, code: (o["code"] as? String) ?? "",
                                isOwner: o["is_owner"] as? Bool == true, members: JSONNumber.int(o["members"]) ?? 0)
    }

    /// The answer the CLI prints for the app.
    public var json: [String: Any] {
        ["id": id, "name": name, "code": code, "is_owner": isOwner, "members": members]
    }
}

/// One member of one of the caller's groups (group_member_list). `memberId` is the handle for removing them.
public struct LeaderboardGroupMember: Codable, Equatable, Sendable {
    public var memberId: String
    public var displayName: String
    public var githubLogin: String?
    public var isOwner: Bool
    public var isMe: Bool

    public init(memberId: String, displayName: String, githubLogin: String?, isOwner: Bool, isMe: Bool) {
        self.memberId = memberId
        self.displayName = displayName
        self.githubLogin = githubLogin
        self.isOwner = isOwner
        self.isMe = isMe
    }
}

/// A group with its members (in joining order) and its twelve boards.
public struct LeaderboardGroupData: Codable, Equatable, Sendable {
    public var group: LeaderboardGroup
    public var members: [LeaderboardGroupMember]
    public var boards: [LeaderboardBoard]

    public init(group: LeaderboardGroup, members: [LeaderboardGroupMember], boards: [LeaderboardBoard]) {
        self.group = group
        self.members = members
        self.boards = boards
    }

    public func board(period: String, unit: String) -> LeaderboardBoard? {
        boards.first { $0.period == period && $0.unit == unit }
    }
}

/// `<data dir>/leaderboard-groups.json`: the caller's groups, oldest membership first.
public struct LeaderboardGroups: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var groups: [LeaderboardGroupData]

    public init(fetchedAt: Date, groups: [LeaderboardGroupData]) {
        self.fetchedAt = fetchedAt
        self.groups = groups
    }

    public static func path(dataDir: String) -> String { joinPath(dataDir, "leaderboard-groups.json") }

    public static func load(dataDir: String) -> LeaderboardGroups? {
        guard let data = FileManager.default.contents(atPath: path(dataDir: dataDir)) else { return nil }
        return try? LeaderboardState.decoder.decode(LeaderboardGroups.self, from: data)
    }

    public func save(dataDir: String) throws {
        try saveAtomic(Self.path(dataDir: dataDir), LeaderboardState.encoder.encode(self))
    }

    static func remove(dataDir: String) {
        try? FileManager.default.removeItem(atPath: path(dataDir: dataDir))
    }

    public func group(id: String) -> LeaderboardGroupData? { groups.first { $0.group.id == id.lowercased() } }

    /// GitHub usernames on the group boards, board order, each once.
    public var logins: [String] {
        LeaderboardBoards(fetchedAt: fetchedAt, boards: groups.flatMap(\.boards)).logins
    }

    /// my_groups + group_member_list + group_boards, put together per group.
    static func make(groups: [LeaderboardGroup], members: Any?, boards: Any?, now: Date) -> LeaderboardGroups {
        var byGroup: [String: [LeaderboardGroupMember]] = [:]
        for row in (members as? [[String: Any]]) ?? [] {
            guard let g = (row["group_id"] as? String)?.lowercased(), let id = row["member_id"] as? String,
                let name = row["display_name"] as? String
            else { continue }
            byGroup[g, default: []].append(LeaderboardGroupMember(
                memberId: id.lowercased(), displayName: name, githubLogin: row["github_login"] as? String,
                isOwner: row["is_owner"] as? Bool == true, isMe: row["is_me"] as? Bool == true))
        }
        var rowsByGroup: [String: [[String: Any]]] = [:]
        for row in (boards as? [[String: Any]]) ?? [] {
            guard let g = (row["group_id"] as? String)?.lowercased() else { continue }
            rowsByGroup[g, default: []].append(row)
        }
        let data = groups.map { g in
            LeaderboardGroupData(group: g, members: byGroup[g.id] ?? [],
                                 boards: LeaderboardBoards.from(rows: rowsByGroup[g.id] ?? [], now: now)?.boards ?? [])
        }
        return LeaderboardGroups(fetchedAt: now, groups: data)
    }
}

/// Numbers as PostgREST sends them (JSON numbers, bigint and numeric sometimes as strings).
enum JSONNumber {
    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }
}

/// What a group call can answer besides success. `kind` is what the CLI hands the app.
public enum GroupError: Error, Equatable, CustomStringConvertible {
    /// join_group: no group has this code (wrong, or renewed by the owner).
    case invalidCode
    /// PT403: not the owner, or not a member (any more).
    case notAllowed(String)
    /// PT409: a limit is reached (10 owned, 20 memberships, 100 members); the server's message says which.
    case limit(String)
    /// PT429: too many join attempts this hour; seconds until the next hour.
    case tooManyAttempts(Int)
    /// 22023: bad name (1 to 40 characters) or the owner removing themselves.
    case badInput(String)
    /// 42501: the server has no leaderboard profile for this account.
    case notParticipant
    /// PT404 (HTTP 404): the member is not in the group (any more).
    case noSuchMember

    public var kind: String {
        switch self {
        case .invalidCode: return "invalid_code"
        case .notAllowed: return "not_allowed"
        case .limit: return "limit"
        case .tooManyAttempts: return "too_many_attempts"
        case .badInput: return "bad_input"
        case .notParticipant: return "not_participant"
        case .noSuchMember: return "no_such_member"
        }
    }

    public var description: String {
        switch self {
        case .invalidCode: return String(localized: "This invitation link is invalid or expired. Ask for a new one.")
        case .notAllowed: return String(localized: "Only the group's owner can do that, or you're no longer in this group.")
        case .limit(let why):
            if why.contains("own at most") { return String(localized: "You can own at most 10 groups.") }
            if why.contains("be in at most") { return String(localized: "You can be in at most 20 groups.") }
            if why.contains("full") { return String(localized: "This group is full (100 members).") }
            return why
        case .tooManyAttempts(let s):
            return String(localized: "Too many join attempts. Try again in \(max(1, (s + 59) / 60)) min.")
        case .badInput(let why):
            return why.contains("1 to 40") ? String(localized: "The group name needs 1 to 40 characters.") : why
        case .notParticipant: return String(localized: "Join the leaderboard first.")
        case .noSuchMember: return String(localized: "This member is no longer in the group.")
        }
    }
}

extension LeaderboardClient {
    /// A group function's answer: 401 stays LeaderboardError.unauthorized (the caller refreshes the sign-in once),
    /// SQLSTATEs become GroupError, everything else LeaderboardError.server. Never .notParticipant.
    static func checkGroup(_ r: HTTPResponse) throws {
        if (200..<300).contains(r.status) { return }
        let obj = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
        let message = (obj["message"] as? String) ?? ""
        switch obj["code"] as? String {
        case "PT403": throw GroupError.notAllowed(message)
        case "PT409": throw GroupError.limit(message)
        case "PT429": throw GroupError.tooManyAttempts(JSONNumber.int(obj["details"]) ?? 3600)
        case "22023": throw GroupError.badInput(message)
        case "42501": throw GroupError.notParticipant
        case "PT404": throw GroupError.noSuchMember
        default: break
        }
        switch r.status {
        case 401: throw LeaderboardError.unauthorized
        case 429: throw GroupError.tooManyAttempts(Int(r.headers["retry-after"] ?? "") ?? 3600)
        default:
            throw LeaderboardError.server(r.status, message.isEmpty ? String(decoding: r.body.prefix(200), as: UTF8.self) : message)
        }
    }

    private func groupRPC(_ fn: String, _ body: [String: Any], token: String) throws -> Any? {
        let r = try call("POST", "rest/v1/rpc/" + fn, token: token, json: body)
        try Self.checkGroup(r)
        return try? JSONSerialization.jsonObject(with: r.body, options: [.fragmentsAllowed])
    }

    private func groupInfo(_ fn: String, _ body: [String: Any], token: String) throws -> LeaderboardGroup {
        guard let g = LeaderboardGroup.from(try groupRPC(fn, body, token: token)) else {
            throw LeaderboardError.server(200, "unexpected answer to \(fn)")
        }
        return g
    }

    public func createGroup(name: String, token: String) throws -> LeaderboardGroup {
        try groupInfo("create_group", ["p_name": name], token: token)
    }

    /// join_group: nil when no group has this code.
    public func joinGroup(code: String, token: String) throws -> LeaderboardGroup? {
        LeaderboardGroup.from(try groupRPC("join_group", ["p_code": code], token: token))
    }

    public func leaveGroup(_ group: String, token: String) throws {
        _ = try groupRPC("leave_group", ["p_group": group], token: token)
    }

    public func renameGroup(_ group: String, name: String, token: String) throws -> LeaderboardGroup {
        try groupInfo("rename_group", ["p_group": group, "p_name": name], token: token)
    }

    public func renewGroupCode(_ group: String, token: String) throws -> LeaderboardGroup {
        try groupInfo("renew_group_code", ["p_group": group], token: token)
    }

    public func removeGroupMember(_ group: String, member: String, token: String) throws {
        _ = try groupRPC("remove_group_member", ["p_group": group, "p_member": member], token: token)
    }

    public func deleteGroup(_ group: String, token: String) throws {
        _ = try groupRPC("delete_group", ["p_group": group], token: token)
    }

    /// my_groups, then (only with at least one group) group_member_list and group_boards.
    public func groups(limit: Int = LeaderboardBoards.limit, token: String, now: Date) throws -> LeaderboardGroups {
        guard let rows = try groupRPC("my_groups", [:], token: token) as? [Any] else {
            throw LeaderboardError.server(200, "unexpected answer to my_groups")
        }
        let groups = rows.compactMap(LeaderboardGroup.from)
        guard !groups.isEmpty else { return LeaderboardGroups(fetchedAt: now, groups: []) }
        let members = try groupRPC("group_member_list", [:], token: token)
        let boards = try groupRPC("group_boards", ["p_limit": limit], token: token)
        return LeaderboardGroups.make(groups: groups, members: members, boards: boards, now: now)
    }
}

/// The app's group actions, through the collector's sign-in (`tokenmaccer-collector leaderboard group …`).
public enum GroupAction: Equatable, Sendable {
    case create(name: String)
    case join(code: String)
    case leave(group: String)
    case rename(group: String, name: String)
    case renew(group: String)
    case removeMember(group: String, member: String)
    case delete(group: String)
    /// Only fetch the groups file again.
    case refresh
}

extension LeaderboardSync {
    /// Runs one group action and then fetches the groups file again (also after a failed action: a group the owner
    /// deleted or a removal shows up at once). Sends nothing unless this Mac has joined. Returns the group the action
    /// answered with (create, join, rename, renew). Never changes leaderboard.json: a 403 here is about the group.
    public func group(_ action: GroupAction, now: Date = Date()) throws -> LeaderboardGroup? {
        guard let state = LeaderboardState.load(dataDir: dataDir), state.joined, !state.leavePending else {
            throw GroupError.notParticipant
        }
        let c = try client()
        if case .refresh = action {
            let groups = try authorized(c, now: now) { try c.groups(token: $0, now: now) }
            try groups.save(dataDir: dataDir)
            AvatarCache(dataDir: dataDir).refresh(groups.logins, transport: c.transport, now: now)
            return nil
        }
        var answer: LeaderboardGroup?
        var failure: Error?
        do {
            answer = try authorized(c, now: now) { token -> LeaderboardGroup? in
                switch action {
                case .create(let name):
                    guard let name = Self.cleanGroupName(name) else { throw GroupError.badInput("1 to 40") }
                    return try c.createGroup(name: name, token: token)
                case .join(let code):
                    guard let g = try c.joinGroup(code: code, token: token) else { throw GroupError.invalidCode }
                    return g
                case .leave(let group):
                    try c.leaveGroup(group, token: token)
                    return nil
                case .rename(let group, let name):
                    guard let name = Self.cleanGroupName(name) else { throw GroupError.badInput("1 to 40") }
                    return try c.renameGroup(group, name: name, token: token)
                case .renew(let group):
                    return try c.renewGroupCode(group, token: token)
                case .removeMember(let group, let member):
                    try c.removeGroupMember(group, member: member, token: token)
                    return nil
                case .delete(let group):
                    try c.deleteGroup(group, token: token)
                    return nil
                case .refresh:
                    return nil
                }
            }
        } catch {
            failure = error
        }
        // no point asking again when the server cannot be reached or the sign-in is gone
        switch failure as? LeaderboardError {
        case .offline?, .network?, .unauthorized?, .notSignedIn?, .noServer?: break
        default: refreshGroups(c, now: now)
        }
        if let failure { throw failure }
        return answer
    }

    /// Best effort: the groups file and the avatars of who is on the group boards. A failure keeps the old file.
    func refreshGroups(_ c: LeaderboardClient, now: Date) {
        guard let groups = try? authorized(c, now: now, { try c.groups(token: $0, now: now) }) else { return }
        try? groups.save(dataDir: dataDir)
        AvatarCache(dataDir: dataDir).refresh(groups.logins, transport: c.transport, now: now)
    }

    /// The server trims and collapses spaces; refuse here what it would refuse (1 to 40 characters).
    public static func cleanGroupName(_ name: String) -> String? {
        let t = name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (1...40).contains(t.count) ? t : nil
    }
}
