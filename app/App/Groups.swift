import AppKit
import Observation
import TokenMaccerCore

/// The window's side of leaderboard groups. Like joining, every change goes through the bundled collector
/// (`tokenmaccer-collector leaderboard group …`), which holds the sign-in, fetches leaderboard-groups.json again
/// right after the change and updates the widget's copy; the app sends nothing itself and only reads the file.
@MainActor @Observable
final class Groups {
    private(set) var busy = false
    var error: String?
    /// A short confirmation ("Invitation copied").
    var notice: String?
    /// The code of an invitation link the app was opened with, until it is joined or dismissed.
    var pendingInvite: String?

    /// Runs one group action; true when it worked. On failure `error` says why (in the collector's words, which
    /// come from the app's String Catalog).
    @discardableResult
    func run(_ verb: String, _ options: [String] = [], helper: URL?) async -> Leaderboard.HelperAnswer? {
        guard !busy else { return nil }
        guard let helper else {
            error = String(localized: "The background collector is missing from TokenMaccer.app.")
            return nil
        }
        error = nil
        notice = nil
        busy = true
        defer { busy = false }
        let answer = await Leaderboard.helper(helper, ["leaderboard", "group", verb] + options, stdin: nil)
        if !answer.ok {
            error = answer.error ?? String(localized: "unknown error")
        }
        return answer
    }

    func create(_ name: String, helper: URL?) async -> String? {
        let a = await run("create", ["--name", name], helper: helper)
        return a?.ok == true ? a?.groupId : nil
    }

    /// Joins by link or code; the group's id and name when it worked.
    func join(_ pasted: String, helper: URL?) async -> (id: String, name: String)? {
        guard let code = GroupInvite.code(from: pasted) else {
            error = GroupError.invalidCode.description
            return nil
        }
        let a = await run("join", ["--code", code], helper: helper)
        guard a?.ok == true, let id = a?.groupId else { return nil }
        if pendingInvite == code { pendingInvite = nil }
        return (id, a?.groupName ?? "")
    }

    func leave(_ group: String, helper: URL?) async { await run("leave", ["--group", group], helper: helper) }
    func rename(_ group: String, to name: String, helper: URL?) async {
        await run("rename", ["--group", group, "--name", name], helper: helper)
    }
    func renew(_ group: String, helper: URL?) async { await run("renew", ["--group", group], helper: helper) }
    func remove(_ member: String, from group: String, helper: URL?) async {
        await run("remove-member", ["--group", group, "--member", member], helper: helper)
    }
    func delete(_ group: String, helper: URL?) async { await run("delete", ["--group", group], helper: helper) }

    @ObservationIgnored private var throttle = RefreshThrottle()

    /// Fetches the groups again when the window appears, a group is picked or the Groups sheet opens: members change
    /// between the 30-minute reports, and an owner should see a new member within seconds. At most once a minute,
    /// never two at once (RefreshThrottle); the collector also updates the widget's copy. Quiet: a failure shows
    /// nothing, the window keeps what the file says. True when a refresh ran.
    @discardableResult
    func refresh(helper: URL?) async -> Bool {
        guard let helper, throttle.begin() else { return false }
        defer { throttle.end() }
        _ = await Leaderboard.helper(helper, ["leaderboard", "group", "refresh"], stdin: nil)
        return true
    }

    func copyInvitation(_ g: GroupValue) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GroupInvite.message(group: g.name, code: g.code), forType: .string)
        error = nil
        notice = String(localized: "Invitation for “\(g.name)” copied.")
    }

    /// The sheet's values from the collector's file.
    static func values(_ file: LeaderboardGroups?) -> [GroupValue] {
        (file?.groups ?? []).map { d in
            GroupValue(
                id: d.group.id, name: d.group.name, code: d.group.code, isOwner: d.group.isOwner,
                memberCount: d.group.members,
                members: d.members.map {
                    GroupMemberValue(id: $0.memberId, name: $0.displayName, login: $0.githubLogin, isOwner: $0.isOwner,
                                     isMe: $0.isMe)
                })
        }
    }
}
