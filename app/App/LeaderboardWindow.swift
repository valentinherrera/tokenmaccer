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
}

/// What the collector fetched for the leaderboard window (leaderboard-top.json) and the avatars it cached. The app
/// reads files only; it never asks the server or GitHub itself.
@MainActor @Observable
final class BoardStore {
    private(set) var boards: LeaderboardBoards?
    @ObservationIgnored private var images: [String: (NSImage?, Date?)] = [:]
    @ObservationIgnored private let dataDir: String

    init(dataDir: String) {
        self.dataDir = dataDir
        refresh()
    }

    func refresh() {
        let fresh = LeaderboardBoards.load(dataDir: dataDir)
        if fresh != boards { boards = fresh }
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

    /// The window's state for one board.
    func state(joined: Bool, period: String, unit: Unit) -> BoardState {
        guard joined else { return .notJoined }
        guard let boards else { return .waiting }
        guard let b = boards.board(period: period, unit: unit.rawValue), !b.entries.isEmpty else { return .board(nil) }
        let rows = b.entries.map {
            BoardRowValue(rank: $0.rank, name: $0.displayName, login: $0.githubLogin, value: $0.value, isMe: $0.isMe)
        }
        // leaderboard_top() appends the own row after the first `limit` places when it is not among them
        if rows.count > LeaderboardBoards.limit, let last = rows.last, last.isMe {
            return .board(BoardValue(participants: b.participants, top: Array(rows.prefix(LeaderboardBoards.limit)), own: last))
        }
        return .board(BoardValue(participants: b.participants, top: rows, own: nil))
    }
}

/// The share sheet's request, so the menu bar can open the window with the sheet already up.
@MainActor @Observable
final class ShareRequest {
    static let shared = ShareRequest()
    var pending = false
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
    private let tick = Timer.publish(every: 15, on: .main, in: .common).autoconnect()

    var body: some View {
        LeaderboardWindowView(
            state: store.state(joined: leaderboard.joined, period: period, unit: usd ? .usd : .tokens),
            period: $period, usd: $usd, updated: store.boards?.fetchedAt,
            offline: leaderboard.joined
                ? leaderboard.state.flatMap { s in s.lastError.flatMap { LeaderboardProblem(kind: s.lastErrorKind, message: $0).kind } }
                : nil,
            avatar: { store.avatar($0) },
            share: { sharing = true },
            join: { joining = true })
        .onReceive(tick) { _ in refresh() }
        .onAppear { refresh() }
        .onOpenURL { _ in
            // from the widget: show the board the widget shows
            period = Selection.period
            usd = Selection.unit == .usd
            refresh()
        }
        .onChange(of: request.pending, initial: true) { _, pending in
            if pending {
                request.pending = false
                if card != nil { sharing = true }
            }
        }
        .sheet(isPresented: $sharing) {
            if let card {
                ShareSheetView(card: card, share: { Sharing.share(card, from: $0) }) { sharing = false }
            }
        }
        .sheet(isPresented: $joining) {
            JoinSheet(leaderboard: leaderboard, setup: AppModels.setup) {
                joining = false
                refresh()
            }
        }
    }

    private func refresh() {
        leaderboard.refresh()
        store.refresh()
    }

    /// The own place on the shown board, as the card shows it.
    private var card: ShareCardValue? {
        guard case .board(let b?) = store.state(joined: leaderboard.joined, period: period, unit: usd ? .usd : .tokens),
            let me = b.me
        else { return nil }
        return ShareCardValue(rank: me.rank, participants: b.participants, period: period, usd: usd, value: me.value)
    }
}

@MainActor
enum Sharing {
    /// The card as a PNG file plus the invitation text, through the system share menu.
    static func share(_ card: ShareCardValue, from view: NSView) {
        guard let png = ShareCard.png(card) else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TokenMaccer-\(card.period).png")
        do { try png.write(to: url, options: .atomic) } catch { return }
        let picker = NSSharingServicePicker(items: [url, ShareCard.message(card)])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
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
