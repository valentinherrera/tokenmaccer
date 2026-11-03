import AppKit
import Observation
import SwiftUI
import TokenMaccerCore
import WidgetKit

/// The objects the windows and the menu bar share (one of each per app run).
@MainActor
enum AppModels {
    static let dataDir = (WidgetData.realHome ?? NSHomeDirectory()) + "/Library/Application Support/TokenMaccer"
    static let setup = Setup()
    static let leaderboard = Leaderboard(dataDir: dataDir)
    static let groups = Groups()
}

/// What the collector fetched for the leaderboard window (leaderboard-top.json) and the avatars it cached. The app
/// reads files only; it never asks the server or GitHub itself.
@MainActor @Observable
final class BoardStore {
    private(set) var boards: LeaderboardBoards?
    /// leaderboard-groups.json: the user's groups, their members and boards.
    private(set) var groups: LeaderboardGroups?
    @ObservationIgnored private var images: [String: (NSImage?, Date?)] = [:]
    @ObservationIgnored private let dataDir: String

    init(dataDir: String) {
        self.dataDir = dataDir
        refresh()
    }

    func refresh() {
        let fresh = LeaderboardBoards.load(dataDir: dataDir)
        if fresh != boards { boards = fresh }
        let freshGroups = LeaderboardGroups.load(dataDir: dataDir)
        if freshGroups != groups { groups = freshGroups }
    }

    /// The boards the window can switch to besides the global one.
    var scopes: [BoardScopeValue] {
        (groups?.groups ?? []).map { BoardScopeValue(id: $0.group.id, name: $0.group.name) }
    }

    /// The cached picture of `login`, reloaded when the collector replaced the file.
    func avatar(_ login: String) -> NSImage? {
        guard let file = AvatarCache.file(dataDir: dataDir, login: login) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: file))?[.modificationDate] as? Date
        if let cached = images[login], cached.1 == modified { return cached.0 }
        let image = modified == nil ? nil : NSImage(contentsOfFile: file)
        images[login] = (image, modified)
        return image
    }

    /// The window's state for one board; `group` nil is the global board. A chosen group the file no longer lists
    /// is gone (left elsewhere, removed by the owner, deleted), never quietly the global board.
    func state(joined: Bool, group: String? = nil, period: String, unit: Unit) -> BoardState {
        guard joined else { return .notJoined }
        let found: LeaderboardBoard?
        if let group {
            guard let groups else { return .waiting }
            guard let g = groups.group(id: group) else { return .groupGone }
            found = g.board(period: period, unit: unit.rawValue)
        } else {
            guard let boards else { return .waiting }
            found = boards.board(period: period, unit: unit.rawValue)
        }
        guard let b = found, !b.entries.isEmpty else { return .board(nil) }
        let rows = b.entries.map {
            BoardRowValue(rank: $0.rank, name: $0.displayName, login: $0.githubLogin, value: $0.value, isMe: $0.isMe)
        }
        return .board(BoardValue(participants: b.participants, rows: rows, places: LeaderboardBoards.limit))
    }
}

/// Sheet requests, so the menu bar and the main window can open the leaderboard window with a sheet already up:
/// `pending` the share sheet, `groupsPending` the Groups sheet.
@MainActor @Observable
final class ShareRequest {
    static let shared = ShareRequest()
    var pending = false
    var groupsPending = false
}

/// The leaderboard window: board, period and unit, share, join.
struct LeaderboardWindow: View {
    @State private var leaderboard = AppModels.leaderboard
    @State private var store = BoardStore(dataDir: AppModels.dataDir)
    @State private var request = ShareRequest.shared
    @State private var period = Selection.period
    @State private var usd = Selection.unit == .usd
    @State private var sharing = false
    @State private var joining = false
    @State private var groups = AppModels.groups
    /// The chosen group's id; nil for the global board.
    @State private var scope: String?
    @State private var managing = false
    @State private var inviting = false
    @State private var inviteJoined: String?
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    private var helper: URL? { AppModels.setup.helperURL }

    var body: some View {
        LeaderboardWindowView(
            state: boardState,
            period: $period, usd: $usd, updated: scope == nil ? store.boards?.fetchedAt : store.groups?.fetchedAt,
            offline: leaderboard.joined
                ? leaderboard.state.flatMap { s in s.lastError.flatMap { LeaderboardProblem(kind: s.lastErrorKind, message: $0).kind } }
                : nil,
            avatar: { store.avatar($0) },
            share: { sharing = true },
            join: { joining = true },
            scopes: store.scopes,
            scope: $scope,
            manageGroups: { managing = true })
        .onReceive(tick) { _ in refresh() }
        .onAppear {
            refresh()
            refreshGroups()
        }
        // picking a group fetches it again (throttled), so a member who just joined shows up within seconds
        .onChange(of: scope) { _, picked in if picked != nil { refreshGroups() } }
        .onOpenURL { url in
            if let code = GroupInvite.code(from: url) {
                // an invitation link: one click to join (after the GitHub sign-in when not on the leaderboard yet)
                groups.pendingInvite = code
                groups.error = nil
                inviteJoined = nil
                leaderboard.refresh()
                let otherSheet = sharing || joining || managing
                sharing = false
                joining = false
                managing = false
                guard otherSheet else {
                    inviting = true
                    return
                }
                // one sheet at a time: the open one goes first, then the invitation comes up
                Task {
                    try? await Task.sleep(for: .milliseconds(400))
                    inviting = true
                }
                return
            }
            // from a widget: show the board the widget shows
            period = Selection.period
            usd = Selection.unit == .usd
            scope = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "group" }?.value?.lowercased()
            refresh()
        }
        .onChange(of: request.pending, initial: true) { _, pending in
            if pending {
                request.pending = false
                // "Share Your Place" (menu bar) shares the place on the global board, not a group's invitation
                if card(for: nil) != nil {
                    scope = nil
                    sharing = true
                }
            }
        }
        .onChange(of: request.groupsPending, initial: true) { _, pending in
            if pending {
                request.groupsPending = false
                // "Groups…" in the main window: one sheet at a time
                sharing = false
                joining = false
                inviting = false
                managing = true
            }
        }
        .sheet(isPresented: $sharing) {
            if let card {
                ShareSheetView(card: card, share: { Sharing.share(card, from: $0) },
                               copyPicture: { Sharing.copyPicture(card) }) { sharing = false }
            }
        }
        .sheet(isPresented: $joining) {
            JoinSheet(leaderboard: leaderboard, setup: AppModels.setup) {
                joining = false
                refresh()
            }
        }
        .sheet(isPresented: $managing) {
            GroupsSheet(groups: Groups.values(store.groups), busy: groups.busy, error: groups.error, notice: groups.notice,
                        actions: groupsActions)
                .task {
                    groups.error = nil
                    groups.notice = nil
                    if await groups.refresh(helper: helper) { store.refresh() }
                }
        }
        .sheet(isPresented: $inviting) {
            InviteSheet(onLeaderboard: leaderboard.joined,
                        phase: inviteJoined.map { .joined($0) } ?? (groups.busy || leaderboard.busy ? .busy : .ready),
                        error: groups.error ?? leaderboard.error,
                        join: acceptInvite,
                        close: {
                            inviting = false
                            if inviteJoined == nil { groups.pendingInvite = nil }
                        })
        }
    }

    private var boardState: BoardState {
        store.state(joined: leaderboard.joined, group: scope, period: period, unit: usd ? .usd : .tokens)
    }

    private func refresh() {
        leaderboard.refresh()
        store.refresh()
    }

    /// Joins the group of the invitation link; not on the leaderboard yet: the GitHub sign-in and the first report
    /// first, then the group. Afterwards the window shows the group's ranking.
    private func acceptInvite() {
        guard let code = groups.pendingInvite else { return }
        Task {
            if !leaderboard.joined {
                await leaderboard.join(helper: helper) { await AppModels.setup.updateNow() }
                guard leaderboard.joined else { return refresh() }
                await waitForFirstReport()
            }
            finishInvite(await groups.join(code, helper: helper))
        }
    }

    /// After joining from an invitation: the first report must be in before the group join, so the new member is on
    /// the group's board at once. updateNow returns without a pass when one is already running (the app's own, or the
    /// background agent's), so wait for it and try again; at most about half a minute, then join all the same.
    private func waitForFirstReport() async {
        for _ in 0..<15 {
            leaderboard.refresh()
            if leaderboard.state?.lastAttemptAt != nil { return }
            if AppModels.setup.running {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            await AppModels.setup.updateNow()
            leaderboard.refresh()
            if leaderboard.state?.lastAttemptAt != nil { return }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    /// The groups again from the server (throttled in Groups.refresh), then the files.
    private func refreshGroups() {
        guard leaderboard.joined else { return }
        Task { if await groups.refresh(helper: helper) { store.refresh() } }
    }

    private func finishInvite(_ joined: (id: String, name: String)?) {
        refresh()
        guard let joined else { return }
        scope = joined.id
        inviteJoined = joined.name
    }

    private var groupsActions: GroupsActions {
        GroupsActions(
            create: { name in
                Task {
                    if let id = await groups.create(name, helper: helper) { scope = id }
                    store.refresh()
                }
            },
            join: { pasted in
                Task {
                    if let g = await groups.join(pasted, helper: helper) { scope = g.id }
                    store.refresh()
                }
            },
            invite: { g in
                scope = g.id
                managing = false
                // the share sheet can open once the groups sheet is gone
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    sharing = true
                }
            },
            copy: { groups.copyInvitation($0) },
            show: { g in
                scope = g.id
                managing = false
            },
            rename: { g, name in groupTask { await groups.rename(g.id, to: name, helper: helper) } },
            renew: { g in groupTask { await groups.renew(g.id, helper: helper) } },
            remove: { g, m in groupTask { await groups.remove(m.id, from: g.id, helper: helper) } },
            delete: { g in groupTask(leaving: g.id) { await groups.delete(g.id, helper: helper) } },
            leave: { g in groupTask(leaving: g.id) { await groups.leave(g.id, helper: helper) } },
            close: { managing = false })
    }

    /// Runs a group action, then reads the files again; a group that is gone afterwards is no longer shown.
    private func groupTask(leaving group: String? = nil, _ body: @escaping @MainActor () async -> Void) {
        Task {
            await body()
            store.refresh()
            if let group, scope == group, store.groups?.group(id: group) == nil { scope = nil }
        }
    }

    /// The card for the shown board: on the global board the own place; on a group's board its invitation (with the
    /// own place in the group when there is one).
    private var card: ShareCardValue? { card(for: scope) }

    private func card(for scope: String?) -> ShareCardValue? {
        let state = store.state(joined: leaderboard.joined, group: scope, period: period, unit: usd ? .usd : .tokens)
        if let scope {
            guard let g = store.groups?.group(id: scope)?.group else { return nil }
            var value = ShareCardValue(rank: 0, participants: 0, period: period, usd: usd, value: 0,
                                       group: GroupCardValue(name: g.name, code: g.code))
            if case .board(let b?) = state, let me = b.me {
                value.rank = me.rank
                value.participants = b.participants
                value.value = me.value
            }
            return value
        }
        guard case .board(let b?) = state, let me = b.me else { return nil }
        return ShareCardValue(rank: me.rank, participants: b.participants, period: period, usd: usd, value: me.value)
    }
}

@MainActor
enum Sharing {
    /// The message with the link, through the system share menu. Text only: WhatsApp for Mac takes the picture as soon
    /// as one is offered and drops the text with the link (Valentin, 03.11.2026, builds 34 and 35). It is not a share
    /// service the picker hands to the app, so it cannot be given text alone; the link preview of tokenmaccer.app
    /// (og-invite.jpg on /join/ links, og.jpg otherwise) shows a picture. The card itself goes through copyPicture.
    static func share(_ card: ShareCardValue, from view: NSView) {
        let picker = NSSharingServicePicker(items: [ShareCard.message(card)])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    /// The card on the clipboard as PNG (and TIFF for apps that only read that), to paste with Command-V.
    @discardableResult
    static func copyPicture(_ card: ShareCardValue) -> Bool {
        guard let png = ShareCard.png(card) else { return false }
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.png, .tiff], owner: nil)
        board.setData(png, forType: .png)
        if let tiff = NSImage(data: png)?.tiffRepresentation { board.setData(tiff, forType: .tiff) }
        return true
    }
}

// MARK: Menu bar

/// Today's number and place for the menu bar, from widget.json and leaderboard.json (once a minute).
@MainActor @Observable
final class MenuBarModel {
    static let shared = MenuBarModel()
    private(set) var value = MenuBarValue()
    @ObservationIgnored private var timer: Timer?

    private init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBarModel.shared.refresh() }
        }
    }

    func refresh() {
        var v = MenuBarValue()
        let data = WidgetData.load()
        v.todayTokens = data?.periods["1D"]?.input
        v.todayUSD = data?.periods["1D"]?.usd
        v.noUsage = TickerView.neverUsed(data)
        v.leaderboardAvailable = Edition.isApp
        if Edition.isApp, let state = LeaderboardState.load(dataDir: AppModels.dataDir), state.joined {
            // the same freshness rule as the widget: a place older than three hours is not shown
            if let at = state.ranksAt, Date().timeIntervalSince(at) < LeaderboardSchedule.maxRankAge,
                let place = state.place(period: "1D", unit: "tokens")
            {
                v.rank = place.rank
                v.participants = place.participants
            }
            v.canShare = LeaderboardBoards.load(dataDir: AppModels.dataDir)?.boards.contains { b in
                b.entries.contains(where: \.isMe)
            } == true
        }
        if value != v { value = v }
    }
}

struct MenuBarLabel: View {
    @State private var model = MenuBarModel.shared

    var body: some View {
        Text("\(Image(systemName: "chart.line.uptrend.xyaxis")) \(model.value.label)")
            .monospacedDigit()
            .accessibilityLabel(Text(verbatim: "TokenMaccer \(model.value.label)"))
    }
}

struct MenuBarContent: View {
    @State private var model = MenuBarModel.shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MenuBarPanel(value: menuValue, actions: MenuBarActions(
            openWindow: { show("main") },
            leaderboard: { show("leaderboard") },
            share: {
                ShareRequest.shared.pending = true
                show("leaderboard")
            },
            checkForUpdates: {
                dismiss()
                if Edition.isApp { Updates.controller.checkForUpdates(nil) }
            },
            settings: {
                dismiss()
                NSApp.activate()
                openSettings()
            },
            quit: { NSApp.terminate(nil) }))
        .onAppear { model.refresh() }
    }

    private var menuValue: MenuBarValue {
        var v = model.value
        v.canCheckForUpdates = Edition.isApp && Updates.controller.updater.canCheckForUpdates
        return v
    }

    private func show(_ id: String) {
        dismiss()
        openWindow(id: id)
        NSApp.activate()
    }
}

/// The Settings window (⌘,): whether the menu bar item is shown, and (app edition) the update switches.
struct SettingsScene: View {
    @AppStorage(MenuBarSetting.key) private var showInMenuBar = MenuBarSetting.defaultValue
    @State private var updates: UpdateSettings? = Edition.isApp ? UpdateSettings() : nil

    var body: some View {
        if let updates {
            @Bindable var u = updates
            SettingsView(showInMenuBar: $showInMenuBar, automaticChecks: $u.automaticChecks,
                         automaticInstall: $u.automaticInstall)
        } else {
            SettingsView(showInMenuBar: $showInMenuBar)
        }
    }
}

enum MenuBarSetting {
    static let key = "showMenuBarExtra"
    /// On for new and existing installs; switched off in Settings.
    static let defaultValue = true
}
