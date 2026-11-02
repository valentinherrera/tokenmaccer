import AppIntents
import AppKit
import SwiftUI

/// The leaderboard widget: medium shows the first three places, large the first eight, each with the own row
/// below a gap when it comes later. Period (chip row) and unit (header) are its own (BoardSelection); the board
/// (global or one of the user's groups) is the widget's configuration ("Edit Widget"). A click anywhere else opens the
/// app's leaderboard window on the same board. Reads only leaderboard-widget.json (LeaderboardWidgetData), never the
/// network.
struct LeaderboardWidgetView: View {
    let data: LeaderboardWidgetData?
    var group: String? = nil
    let period: String
    let unit: Unit
    let size: Size

    @Environment(\.widgetRenderingMode) private var mode

    private var places: Int { size == .large ? 8 : 3 }
    private var state: BoardState {
        LeaderboardWidgetData.state(data, group: group, period: period, unit: unit, places: places)
    }

    /// tokenmaccer://leaderboard, with ?group=<id> for a group's board.
    private var url: URL {
        guard let group, var c = URLComponents(url: Place.leaderboardURL, resolvingAgainstBaseURL: false) else {
            return Place.leaderboardURL
        }
        c.queryItems = [URLQueryItem(name: "group", value: group)]
        return c.url ?? Place.leaderboardURL
    }

    var body: some View {
        Group {
            if state == .notJoined {
                notJoined
            } else {
                VStack(alignment: .leading, spacing: size == .large ? 6 : 4) {
                    header
                    content
                    Spacer(minLength: 0)
                    chips
                    if size == .large { footer }
                }
            }
        }
        .widgetURL(url)
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 6) {
            if let name = data?.group(group)?.name {
                Label { Text(verbatim: name) } icon: { Image(systemName: "person.2.fill") }
                    .font(.system(size: 13, weight: .semibold))
            } else {
                Text("Leaderboard").font(.system(size: 13, weight: .semibold))
            }
            Spacer(minLength: 4)
            Button(intent: ToggleBoardUnit()) {
                Text(Format.unitName(unit)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Unit: \(Format.unitName(unit))"))
        }
        .lineLimit(1)
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .notJoined:
            EmptyView()
        case .waiting:
            message(symbol: "hourglass", title: "The ranking is not loaded yet",
                    detail: "It appears with the next report, within 30 minutes.")
        case .board(nil):
            message(symbol: "person.3", title: "Nobody here yet",
                    detail: "No participant has a current total for this period.")
        case .groupGone:
            message(symbol: "person.2.slash", title: "You're no longer in this group",
                    detail: "You left it, were removed, or it was deleted. Choose another board with Edit Widget.")
        case .board(let b?):
            VStack(alignment: .leading, spacing: size == .large ? 3 : 1) {
                ForEach(b.top) { row($0) }
                if let own = b.own {
                    Text(verbatim: "⋯").font(.system(size: 9)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity).frame(height: size == .large ? 10 : 6)
                        .accessibilityHidden(true)
                    row(own)
                }
            }
        }
    }

    private func row(_ r: BoardRowValue) -> some View {
        let avatar: CGFloat = size == .large ? 22 : 18
        return HStack(spacing: 7) {
            Text(verbatim: "\(r.rank)")
                .font(.system(size: 12, weight: r.rank <= 3 ? .bold : .regular)).monospacedDigit()
                .foregroundStyle(r.rank <= 3 ? .primary : .secondary)
                .frame(width: 22, alignment: .trailing)
            AvatarView(image: data?.avatar(r.login).flatMap(NSImage.init(data:)), name: r.name, size: avatar)
            Text(verbatim: r.name)
                .font(.system(size: 12, weight: r.isMe ? .semibold : .regular))
                .lineLimit(1)
            if r.isMe {
                Text("You")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Capsule().fill(Palette.accent.opacity(mode == .fullColor ? 0.25 : 0.15)))
                    .widgetAccentable()
            }
            Spacer(minLength: 6)
            Text(verbatim: unit == .usd ? Format.usd(r.value) : Format.tokens(Int(r.value)))
                .font(.system(size: 12, weight: r.isMe ? .semibold : .regular)).monospacedDigit()
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, size == .large ? 3 : 2)
        .background(RoundedRectangle(cornerRadius: 6).fill(r.isMe ? Palette.accent.opacity(0.16) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(r.isMe ? Palette.accent.opacity(0.7) : .clear))
        .accessibilityElement(children: .combine)
    }

    private var chips: some View {
        HStack(spacing: 4) {
            ForEach(Selection.periods, id: \.self) { k in
                Button(intent: SelectBoardPeriod(k)) {
                    Text(k)
                        .font(.system(size: 11, weight: k == period ? .semibold : .regular))
                        .foregroundStyle(k == period ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(k == period ? Color.primary.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            if case .board(let b?) = state {
                Text("Participants: \(b.participants)")
            }
            Spacer(minLength: 0)
            if let d = data?.fetchedAt {
                Text("Updated \(d.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1)
    }

    private func message(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Spacer(minLength: 0)
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary).accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .minimumScaleFactor(0.8)
    }

    /// Not joined: what the board is and where to join (the click opens the leaderboard window with Join).
    private var notJoined: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Leaderboard").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 0)
            Image(systemName: "trophy").font(.system(size: 22)).foregroundStyle(Palette.accent)
                .widgetAccentable().accessibilityHidden(true)
            Text("Compare with others").font(.system(size: 13, weight: .semibold))
            Text("Join the leaderboard to compare your totals with other Claude Code users. Only your period totals are shared.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Click to open TokenMaccer and join.")
                .font(.caption.weight(.medium)).foregroundStyle(Palette.accent)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .minimumScaleFactor(0.8)
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
