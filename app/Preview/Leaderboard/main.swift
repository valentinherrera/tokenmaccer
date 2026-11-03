import AppKit
import SwiftUI

// Renders the leaderboard window, the groups sheet, the share card and the menu bar panel to PNGs (light and dark) from fixtures,
// without the app, its data or the network (the avatars are drawn here, no picture is downloaded). Build (from
// the repository root):
//   xcrun swiftc -parse-as-library app/Shared/*.swift app/App/LeaderboardViews.swift app/App/GroupViews.swift \
//     app/Preview/Leaderboard/main.swift -o /tmp/tm-leaderboard
// Usage: tm-leaderboard <output dir> [-AppleLanguages '(de)']; German needs the binary inside an .app with
// de.lproj from a built TokenMaccer.app (scripts/render_site_images.sh does this).
// TM_RENDER_CLEAR=1: transparent background, for the website, which draws the glass itself.
@main
struct LeaderboardRenderer {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: tm-leaderboard <output dir>")
            exit(2)
        }
        let out = URL(fileURLWithPath: args[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        let names = ["Mara K.", "devon", "synth-gh", "Ilka", "pjotr", "Ana Ruiz", "tokenfox", "Lee", "quill", "Sam O.",
                     "nightowl", "R. Brandt"]
        let top = names.enumerated().map { i, n in
            BoardRowValue(rank: i + 1, name: n, login: i % 4 == 3 ? nil : "synth-\(i)", value: Double(48_000_000 / (i + 1)),
                          isMe: n == "synth-gh")
        }
        let inTop = BoardValue(participants: 120, top: top, own: nil)
        var others = top
        others[2] = BoardRowValue(rank: 3, name: "kestrel", login: "synth-k", value: others[2].value, isMe: false)
        let outside = BoardValue(
            participants: 120, top: others.map { var r = $0; r.value /= 40_000; return r },
            own: BoardRowValue(rank: 57, name: "synth-gh", login: "synth-2", value: 31.4, isMe: true))
        let updated = Calendar.current.date(bySettingHour: 13, minute: 30, second: 0, of: Date()) ?? Date()
        let card = ShareCardValue(rank: 3, participants: 120, period: "7D", usd: false, value: 16_000_000)
        let friends = BoardValue(participants: 4, top: Array(top.prefix(4)).enumerated().map { i, r in
            var r = r
            r.rank = i + 1
            return r
        }, own: nil)
        let scopes = [BoardScopeValue(id: "g1", name: "Friday Hackers"), BoardScopeValue(id: "g2", name: "Studio Nord")]
        let members = [
            GroupMemberValue(id: "m1", name: "synth-gh", login: "synth-2", isOwner: true, isMe: true),
            GroupMemberValue(id: "m2", name: "Mara K.", login: "synth-0", isOwner: false, isMe: false),
            GroupMemberValue(id: "m3", name: "devon", login: "synth-1", isOwner: false, isMe: false),
        ]
        let groups = [
            GroupValue(id: "g1", name: "Friday Hackers", code: "k7m2p9qrst", isOwner: true, memberCount: 3, members: members),
            GroupValue(id: "g2", name: "Studio Nord", code: "a3b4c5d6e7", isOwner: false, memberCount: 12, members: members),
        ]
        let invite = ShareCardValue(rank: 2, participants: 4, period: "7D", usd: false, value: 24_000_000,
                                    group: GroupCardValue(name: "Friday Hackers", code: "k7m2p9qrst"))

        let scenes: [(String, AnyView)] = [
            ("leaderboard-7d-tokens", AnyView(window(.board(inTop), period: "7D", usd: false, updated: updated))),
            ("leaderboard-own-row-outside-usd", AnyView(window(.board(outside), period: "30D", usd: true, updated: updated))),
            ("leaderboard-not-joined", AnyView(window(.notJoined, period: "7D", usd: false, updated: nil))),
            ("leaderboard-waiting", AnyView(window(.waiting, period: "1D", usd: false, updated: nil))),
            ("leaderboard-empty-period", AnyView(window(.board(nil), period: "1D", usd: false, updated: updated))),
            ("leaderboard-offline-board", AnyView(window(.board(inTop), period: "7D", usd: false, updated: updated,
                                                          offline: .offline))),
            ("leaderboard-offline-waiting", AnyView(window(.waiting, period: "1D", usd: false, updated: nil,
                                                            offline: .offline))),
            ("leaderboard-unreachable-waiting", AnyView(window(.waiting, period: "1D", usd: false, updated: nil,
                                                                offline: .unreachable))),
            ("leaderboard-group-board", AnyView(window(.board(friends), period: "7D", usd: false, updated: updated,
                                                        scopes: scopes, scope: "g1"))),
            ("leaderboard-group-gone", AnyView(window(.groupGone, period: "7D", usd: false, updated: updated,
                                                       scopes: scopes, scope: "g9"))),
            ("groups-sheet", AnyView(GroupsSheet(groups: groups))),
            ("groups-sheet-empty", AnyView(GroupsSheet(groups: [], error: "This invitation link is invalid or expired. Ask for a new one."))),
            ("invite-sheet-joined-leaderboard", AnyView(InviteSheet(onLeaderboard: true))),
            ("invite-sheet-not-on-leaderboard", AnyView(InviteSheet(onLeaderboard: false))),
            ("invite-sheet-done", AnyView(InviteSheet(onLeaderboard: true, phase: .joined("Friday Hackers")))),
            ("share-sheet", AnyView(ShareSheetView(card: card))),
            ("share-sheet-invite", AnyView(ShareSheetView(card: invite))),
            ("menubar-joined", AnyView(MenuBarPanel(value: MenuBarValue(
                todayTokens: 2_350_000, todayUSD: 41.27, rank: 3, participants: 120, canShare: true)))),
            ("menubar-not-joined", AnyView(MenuBarPanel(value: MenuBarValue(todayTokens: 2_350_000, todayUSD: 41.27)))),
            ("menubar-waiting", AnyView(MenuBarPanel(value: MenuBarValue()))),
            ("menubar-no-claude-usage", AnyView(MenuBarPanel(value: MenuBarValue(todayTokens: 0, todayUSD: 0, noUsage: true)))),
            ("settings", AnyView(SettingsView(showInMenuBar: .constant(true), automaticChecks: .constant(true),
                                              automaticInstall: .constant(true)))),
        ]
        for (name, view) in scenes {
            for dark in [false, true] {
                let file = out.appendingPathComponent("\(name)-\(dark ? "dark" : "light")-\(lang).png")
                if !snapshot(view, dark: dark, to: file) { exit(1) }
            }
        }
        // the card itself, exactly as shared (ImageRenderer, 1200 x 680 px)
        for (suffix, c) in [("7d-tokens", card), ("1d-usd", ShareCardValue(rank: 1, participants: 8, period: "1D", usd: true, value: 41.27)),
                            ("group-invite", invite)] {
            guard let png = ShareCard.png(c) else { exit(1) }
            try? png.write(to: out.appendingPathComponent("share-card-\(suffix)-\(lang).png"))
        }
        print("message: \(ShareCard.message(card))")
        print("invite message: \(ShareCard.message(invite))")
        print("rendered \(scenes.count * 2 + 3) images to \(out.path)")
    }

    static var lang: String { Bundle.main.preferredLocalizations.first ?? "en" }

    @MainActor
    static func window(_ state: BoardState, period: String, usd: Bool, updated: Date?,
                       offline: LeaderboardProblem.Kind? = nil, scopes: [BoardScopeValue] = [],
                       scope: String? = nil) -> some View {
        LeaderboardWindowView(state: state, period: .constant(period), usd: .constant(usd), updated: updated,
                              offline: offline, avatar: avatar, scopes: scopes, scope: .constant(scope),
                              manageGroups: {})
    }

    /// Made-up avatars: a coloured tile with a simple pattern, one per login (no GitHub picture is used).
    @MainActor
    static func avatar(_ login: String) -> NSImage? {
        let hue = CGFloat(login.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % 360 }) / 360
        let base = NSColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1)
        return NSImage(size: NSSize(width: 56, height: 56), flipped: false) { rect in
            NSColor(white: 0.95, alpha: 1).setFill()
            rect.fill()
            base.setFill()
            let cell = rect.width / 5
            for x in 0..<3 {
                for y in 0..<5 where (login.unicodeScalars.reduce(x * 7 + y * 3) { $0 + Int($1.value) }) % 2 == 0 {
                    NSRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).fill()
                    NSRect(x: CGFloat(4 - x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).fill()
                }
            }
            return true
        }
    }

    /// Draws the view through AppKit (controls included, unlike ImageRenderer) at 2x, in a window that counts as
    /// key, like app/Preview/Onboarding.
    @MainActor
    static func snapshot(_ view: AnyView, dark: Bool, to url: URL) -> Bool {
        let clear = ProcessInfo.processInfo.environment["TM_RENDER_CLEAR"] == "1"
        let host = NSHostingView(rootView: view.background(clear ? Color.clear : Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = KeyWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try png.write(to: url)
            return true
        } catch {
            print("could not write \(url.path): \(error)")
            return false
        }
    }
}

final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
