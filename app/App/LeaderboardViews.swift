import AppKit
import SwiftUI

// The leaderboard window, the share card and the menu bar panel, as plain views over values. The app fills them
// from the collector's files (LeaderboardWindow.swift, MenuBar.swift); app/Preview/Leaderboard renders them to PNGs
// from fixtures. Nothing here touches files, defaults or the network. Strings are LocalizedStringKeys, German in
// Localizable.xcstrings.

/// The colours of the app icon: a graphite body with an amber number display.
enum Brand {
    static let amber = Color(red: 0.98, green: 0.64, blue: 0.0)
    static let graphite = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let graphiteDeep = Color(red: 0.09, green: 0.09, blue: 0.10)
    /// Where a shared card invites people to: the public repository, whose README leads to the download (answers
    /// HTTP 200 today, checked 02.11.2026). Switch to the download page only once it is published (W4, GitHub
    /// Pages); a link on a shared card must never end on a 404.
    static let inviteURL = URL(string: "https://github.com/valentinherrera/tokenmaccer")!

    static var inviteHost: String {
        inviteURL.absoluteString.replacingOccurrences(of: "https://", with: "").trimmingCharacters(in: ["/"])
    }
}

/// How a period reads in a sentence: "#3 of 120 this week".
enum PeriodPhrase {
    static func text(_ period: String) -> String {
        switch period {
        case "1D": return String(localized: "today")
        case "7D": return String(localized: "this week")
        case "30D": return String(localized: "in the last 30 days")
        case "YTD": return String(localized: "this year")
        case "1Y": return String(localized: "in the last 12 months")
        default: return String(localized: "all time")
        }
    }
}

/// A leaderboard error as the app words it: offline and unreachable get their own text, in the app's language
/// (the collector may have written its message in another one); anything else shows the collector's message.
struct LeaderboardProblem: Equatable {
    enum Kind: String { case offline, unreachable }  // LeaderboardErrorKind in the collector
    var kind: Kind?
    var message: String

    init(kind: String?, message: String) {
        self.kind = kind.flatMap(Kind.init(rawValue:))
        self.message = message
    }

    var text: String {
        switch kind {
        case .offline: return String(localized: "You're offline. Your place updates when you're back online.")
        case .unreachable:
            return String(localized: "The leaderboard server can't be reached right now. TokenMaccer tries again on its own.")
        case nil: return message
        }
    }
}

// MARK: Leaderboard window

struct BoardRowValue: Equatable, Identifiable {
    var rank: Int
    var name: String
    var login: String?
    var value: Double
    var isMe: Bool
    var id: String { "\(rank)-\(name)-\(isMe)" }
}

struct BoardValue: Equatable {
    var participants: Int
    /// The first places, in order.
    var top: [BoardRowValue]
    /// The own row when it is not among `top` (shown below a gap).
    var own: BoardRowValue?

    var me: BoardRowValue? { own ?? top.first { $0.isMe } }
}

enum BoardState: Equatable {
    case notJoined
    /// Joined, but the collector has not fetched the boards yet.
    case waiting
    /// nil: nobody has a current total for this period and unit.
    case board(BoardValue?)
}

struct LeaderboardWindowView: View {
    let state: BoardState
    @Binding var period: String
    @Binding var usd: Bool
    var updated: Date?
    /// The last report failed for want of a connection: the board may be old (a banner) or not there yet.
    var offline: LeaderboardProblem.Kind?
    var avatar: (String) -> NSImage? = { _ in nil }
    var share: () -> Void = {}
    var join: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls.padding([.horizontal, .top], 16).padding(.bottom, 12)
            Divider()
            if let offline, case .board = state {
                banner(offline)
                Divider()
            }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            if case .board = state {
                Divider()
                footer.padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .frame(width: 440, height: 580)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Period", selection: $period) {
                ForEach(["1D", "7D", "30D", "YTD", "1Y", "ALL"], id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack {
                Picker("Unit", selection: $usd) {
                    Text("Tokens").tag(false)
                    Text("USD").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if case .board(let b) = state, let me = b?.me {
                    Text("You: #\(me.rank) of \(b?.participants ?? 0)")
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("Share…", systemImage: "square.and.arrow.up", action: share)
                    .disabled(!canShare)
            }
        }
    }

    private var canShare: Bool {
        if case .board(let b) = state { return b?.me != nil }
        return false
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .notJoined:
            EmptyBoard(symbol: "trophy", title: "See where you stand",
                       detail: "Join the leaderboard to compare your totals with other Claude Code users. Only your period totals are shared.") {
                Button("Join…", action: join).keyboardShortcut(.defaultAction)
            }
        case .waiting where offline == .offline:
            EmptyBoard(symbol: "wifi.slash", title: "You're offline",
                       detail: "The ranking loads with the first report once this Mac is back online.") { EmptyView() }
        case .waiting where offline == .unreachable:
            EmptyBoard(symbol: "icloud.slash", title: "The server can't be reached",
                       detail: "TokenMaccer tries again on its own, at most every 30 minutes. Your numbers on this Mac are not affected.") { EmptyView() }
        case .waiting:
            EmptyBoard(symbol: "hourglass", title: "The ranking is on its way",
                       detail: "It appears with the next report, within 30 minutes.") { ProgressView().controlSize(.small) }
        case .board(nil):
            EmptyBoard(symbol: "person.3", title: "Nobody here yet",
                       detail: "No participant has a current total for this period.") { EmptyView() }
        case .board(let b?):
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(b.top) { row($0) }
                    if let own = b.own {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.tertiary)
                            .frame(height: 22)
                            .accessibilityHidden(true)
                        row(own)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
        }
    }

    private func banner(_ kind: LeaderboardProblem.Kind) -> some View {
        Label {
            Text(verbatim: LeaderboardProblem(kind: kind.rawValue, message: "").text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: kind == .offline ? "wifi.slash" : "icloud.slash")
        }
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func row(_ r: BoardRowValue) -> some View {
        HStack(spacing: 10) {
            Text(verbatim: "\(r.rank)")
                .font(.callout.weight(r.rank <= 3 ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(r.rank <= 3 ? .primary : .secondary)
                .frame(width: 34, alignment: .trailing)
            AvatarView(image: r.login.flatMap(avatar), name: r.name)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(verbatim: r.name).fontWeight(r.isMe ? .semibold : .regular).lineLimit(1)
                    if r.isMe {
                        Text("You")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Brand.amber.opacity(0.25)))
                    }
                }
                if let login = r.login, !login.isEmpty, login != r.name {
                    Text(verbatim: "@\(login)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(verbatim: usd ? Format.usd(r.value) : Format.tokens(Int(r.value)))
                .monospacedDigit()
                .fontWeight(r.isMe ? .semibold : .regular)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(r.isMe ? Brand.amber.opacity(0.16) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(r.isMe ? Brand.amber.opacity(0.55) : .clear))
        .accessibilityElement(children: .combine)
    }

    private var footer: some View {
        HStack {
            if let updated {
                Text("Updated \(updated.formatted(date: .omitted, time: .shortened)) · refreshed every 30 minutes")
            } else {
                Text("Refreshed every 30 minutes")
            }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

struct AvatarView: View {
    let image: NSImage?
    let name: String
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Circle().fill(.quaternary)
                    .overlay(Text(verbatim: String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.45, weight: .semibold))
                        .foregroundStyle(.secondary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct EmptyBoard<Extra: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
                .frame(maxWidth: 300).fixedSize(horizontal: false, vertical: true)
            extra.padding(.top, 4)
        }
        .padding(24)
    }
}

// MARK: Share card

struct ShareCardValue: Equatable {
    var rank: Int
    var participants: Int
    var period: String
    var usd: Bool
    var value: Double
}

/// The image people post: their place, the board, the app and where to get it. Drawn with ImageRenderer, so only
/// plain shapes and text (no controls). Always dark, like the app icon.
struct ShareCard: View {
    let card: ShareCardValue
    static let size = CGSize(width: 600, height: 340)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(Brand.amber).frame(width: 14, height: 14)
                Text(verbatim: "TokenMaccer").font(.system(size: 17, weight: .semibold))
                Spacer()
                Text("Claude Code leaderboard").font(.system(size: 14, weight: .medium)).foregroundStyle(.white.opacity(0.6))
            }
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 18) {
                Text(verbatim: "#\(card.rank)")
                    .font(.system(size: 76, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Brand.amber)
                    .padding(.horizontal, 22).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.85)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.85), lineWidth: 5))
                VStack(alignment: .leading, spacing: 6) {
                    Text("of \(card.participants) \(PeriodPhrase.text(card.period))")
                        .font(.system(size: 30, weight: .semibold))
                        .lineLimit(2).minimumScaleFactor(0.7)
                    Text(verbatim: "\(card.period) · \(card.usd ? "USD" : String(localized: "Tokens")) · \(card.usd ? Format.usd(card.value) : Format.tokens(Int(card.value)))")
                        .font(.system(size: 17, weight: .medium)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text("Token usage of Claude Code, on your Mac.").foregroundStyle(.white.opacity(0.6))
                Spacer(minLength: 12)
                // The link must stay on one line so it can be typed off the picture; the tagline gives way.
                Text(verbatim: Brand.inviteHost).foregroundStyle(Brand.amber.opacity(0.9))
                    .fixedSize()
            }
            .font(.system(size: 14, weight: .medium))
        }
        .foregroundStyle(.white)
        .padding(28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(LinearGradient(colors: [Brand.graphite, Brand.graphiteDeep], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
    }

    /// The card as PNG at 2x (1200 x 680 pixels).
    @MainActor
    static func png(_ card: ShareCardValue) -> Data? {
        let renderer = ImageRenderer(content: ShareCard(card: card))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }

    /// The text that goes with the image (and alone where a service takes no image).
    static func message(_ card: ShareCardValue) -> String {
        String(localized: "I'm #\(card.rank) of \(card.participants) \(PeriodPhrase.text(card.period)) on the TokenMaccer leaderboard for Claude Code. Get the app: \(Brand.inviteURL.absoluteString)")
    }
}

/// The card with the share button, in a sheet of the leaderboard window.
struct ShareSheetView: View {
    let card: ShareCardValue
    var share: (NSView) -> Void = { _ in }
    var close: () -> Void = {}
    @State private var anchor = AnchorBox()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share Your Place").font(.title3.weight(.semibold))
            // the rendered image itself, so the preview is exactly what is shared
            Group {
                if let preview = ShareCard.png(card).flatMap(NSImage.init(data:)) {
                    Image(nsImage: preview).resizable()
                } else {
                    ShareCard(card: card)
                }
            }
            .frame(width: ShareCard.size.width * 0.7, height: ShareCard.size.height * 0.7)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityLabel(Text(verbatim: ShareCard.message(card)))
            Text("The image and a link to the download page. Your token count is on the card; nothing else is.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
                Button("Share…") { if let v = anchor.view { share(v) } }
                    .keyboardShortcut(.defaultAction)
                    .background(AnchorView(box: anchor))
            }
        }
        .padding(20)
        .frame(width: ShareCard.size.width * 0.7 + 40)
    }
}

/// Holds the NSView NSSharingServicePicker opens from.
@MainActor
final class AnchorBox {
    weak var view: NSView?
}

struct AnchorView: NSViewRepresentable {
    let box: AnchorBox
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        box.view = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { box.view = nsView }
}

// MARK: Menu bar

struct MenuBarValue: Equatable {
    var todayTokens: Int?
    var todayUSD: Double?
    /// Today's place on the tokens board, when joined and reported.
    var rank: Int?
    var participants: Int?
    var leaderboardAvailable = true
    /// widget.json exists but nothing was ever counted (no Claude Code transcripts found, or none with usage).
    var noUsage = false
    var canShare = false
    var canCheckForUpdates = true

    /// The text next to the symbol: "1.2M · #3".
    var label: String {
        let n = todayTokens.map(Format.tokens) ?? "–"
        return rank.map { "\(n) · #\($0)" } ?? n
    }
}

struct MenuBarActions {
    var openWindow: () -> Void = {}
    var leaderboard: () -> Void = {}
    var share: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var settings: () -> Void = {}
    var quit: () -> Void = {}
}

/// The panel under the menu bar symbol: today at a glance, then the quick actions as menu rows.
struct MenuBarPanel: View {
    let value: MenuBarValue
    var actions = MenuBarActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: value.todayTokens.map(Format.tokens) ?? "–")
                        .font(.system(size: 28, weight: .semibold)).monospacedDigit()
                    Text("tokens").foregroundStyle(.secondary)
                    Spacer()
                    if let usd = value.todayUSD {
                        Text(verbatim: Format.usd(usd)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let rank = value.rank, let of = value.participants {
                    Text("#\(rank) of \(of) today on the leaderboard")
                        .font(.callout.weight(.medium)).monospacedDigit()
                        .foregroundStyle(Brand.amber)
                }
                if value.todayTokens == nil {
                    Text("Waiting for the first numbers. TokenMaccer counts every 5 minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if value.noUsage {
                    Text("No Claude Code usage found yet. Your tokens appear after your next session.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            Divider().padding(.horizontal, 6)
            VStack(spacing: 0) {
                MenuRow("Open TokenMaccer", action: actions.openWindow)
                if value.leaderboardAvailable {
                    MenuRow("Leaderboard", action: actions.leaderboard)
                    MenuRow("Share Your Place…", action: actions.share).disabled(!value.canShare)
                }
                Divider().padding(.horizontal, 6).padding(.vertical, 4)
                MenuRow("Check for Updates…", action: actions.checkForUpdates).disabled(!value.canCheckForUpdates)
                MenuRow("Settings…", shortcut: "⌘,", action: actions.settings)
                Divider().padding(.horizontal, 6).padding(.vertical, 4)
                MenuRow("Quit TokenMaccer", shortcut: "⌘Q", action: actions.quit)
            }
            .padding(.horizontal, 5).padding(.vertical, 5)
        }
        .frame(width: 280)
    }
}

/// A button that looks and behaves like a menu item (highlight on hover).
struct MenuRow: View {
    let title: LocalizedStringKey
    var shortcut: String?
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    init(_ title: LocalizedStringKey, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let shortcut {
                    Text(verbatim: shortcut)
                        .foregroundStyle(hover && enabled ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            .foregroundStyle(hover && enabled ? AnyShapeStyle(.white) : enabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover && enabled ? Color.accentColor : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: Settings

struct SettingsView: View {
    @Binding var showInMenuBar: Bool
    /// Sparkle's switches; nil in the source edition (no updater).
    var automaticChecks: Binding<Bool>?
    var automaticInstall: Binding<Bool>?

    var body: some View {
        Form {
            Section {
                Toggle("Show TokenMaccer in the menu bar", isOn: $showInMenuBar)
                Text("Today's tokens and, after you joined the leaderboard, your place, next to the clock.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let automaticChecks, let automaticInstall {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: automaticChecks)
                    Toggle("Download and install updates automatically", isOn: automaticInstall)
                        .disabled(!automaticChecks.wrappedValue)
                    Text("Once a day. A downloaded update is installed when you quit TokenMaccer; Sparkle checks its signature first.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
