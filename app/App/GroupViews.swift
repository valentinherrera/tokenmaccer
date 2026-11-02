import AppKit
import SwiftUI

// The groups sheet of the leaderboard window (create, join by link or code, invite, manage) and the sheet an
// invitation link opens, as plain views over values like LeaderboardViews.swift: the app fills them from the
// collector's leaderboard-groups.json (Groups.swift), app/Preview/Leaderboard renders them from fixtures. Nothing here
// touches files, defaults or the network. Destructive actions ask first (confirmationDialog).

struct GroupMemberValue: Equatable, Identifiable {
    var id: String
    var name: String
    var login: String?
    var isOwner: Bool
    var isMe: Bool
}

struct GroupValue: Equatable, Identifiable {
    var id: String
    var name: String
    var code: String
    var isOwner: Bool
    var memberCount: Int
    var members: [GroupMemberValue]
}

struct GroupsActions {
    var create: (String) -> Void = { _ in }
    /// What was pasted: a link of either form or the bare code (GroupInvite.code(from:) reads it).
    var join: (String) -> Void = { _ in }
    var invite: (GroupValue) -> Void = { _ in }
    var copy: (GroupValue) -> Void = { _ in }
    var show: (GroupValue) -> Void = { _ in }
    var rename: (GroupValue, String) -> Void = { _, _ in }
    var renew: (GroupValue) -> Void = { _ in }
    var remove: (GroupValue, GroupMemberValue) -> Void = { _, _ in }
    var delete: (GroupValue) -> Void = { _ in }
    var leave: (GroupValue) -> Void = { _ in }
    var close: () -> Void = {}
}

/// A confirmation the sheet is waiting for.
private enum Pending: Identifiable {
    case renew(GroupValue)
    case delete(GroupValue)
    case leave(GroupValue)
    case remove(GroupValue, GroupMemberValue)

    var id: String {
        switch self {
        case .renew(let g): return "renew-\(g.id)"
        case .delete(let g): return "delete-\(g.id)"
        case .leave(let g): return "leave-\(g.id)"
        case .remove(let g, let m): return "remove-\(g.id)-\(m.id)"
        }
    }
}

struct GroupsSheet: View {
    let groups: [GroupValue]
    var busy = false
    var error: String?
    /// Shown briefly after "Copy Invitation".
    var notice: String?
    var actions = GroupsActions()

    @State private var newName = ""
    @State private var pasted = ""
    @State private var pending: Pending?
    @State private var renaming: GroupValue?
    @State private var renameText = ""
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Groups").font(.title3.weight(.semibold))
            Text("Compare with friends: whoever has a group's invitation link can join it. Only members see a group, who is in it and its ranking.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if groups.isEmpty {
                Text("You're not in a group yet.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(groups) { card($0) }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Form {
                LabeledContent("New group") {
                    HStack {
                        TextField("New group", text: $newName, prompt: Text("Name, 1 to 40 characters"))
                            .labelsHidden()
                            .onSubmit(create)
                        Button("Create", action: create).disabled(!canCreate)
                    }
                }
                LabeledContent("Join a group") {
                    HStack {
                        TextField("Join a group", text: $pasted, prompt: Text("Invitation link or code"))
                            .labelsHidden()
                            .onSubmit(join)
                        Button("Join", action: join).disabled(!canJoin)
                    }
                }
            }
            .disabled(busy)
            status
            HStack {
                Spacer()
                Button("Done", action: actions.close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .confirmationDialog(dialogTitle, isPresented: .init(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { p in
            switch p {
            case .renew(let g): Button("New Link") { actions.renew(g) }
            case .delete(let g): Button("Delete Group", role: .destructive) { actions.delete(g) }
            case .leave(let g): Button("Leave Group", role: .destructive) { actions.leave(g) }
            case .remove(let g, let m): Button("Remove", role: .destructive) { actions.remove(g, m) }
            }
        } message: { p in
            switch p {
            case .renew:
                Text("The current link stops working at once. Members stay in the group; share the new link with anyone who should still join.")
            case .delete:
                Text("The group and its ranking are deleted for every member. Your entry on the leaderboard stays.")
            case .leave(let g) where g.isOwner && g.memberCount > 1:
                Text("The group passes to the member who joined first. You can come back with the invitation link.")
            case .leave(let g) where g.isOwner:
                Text("You're the only member, so the group is deleted.")
            case .leave:
                Text("The group disappears from your app and widget. You can come back with the invitation link.")
            case .remove(_, let m):
                Text("\(m.name) can join again with the invitation link until you choose New Link.")
            }
        }
        .alert("Rename Group", isPresented: .init(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let g = renaming { actions.rename(g, renameText) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("1 to 40 characters. Every member sees the new name.")
        }
    }

    private var dialogTitle: Text {
        switch pending {
        case .renew(let g)?: return Text("Make a new link for “\(g.name)”?")
        case .delete(let g)?: return Text("Delete “\(g.name)”?")
        case .leave(let g)?: return Text("Leave “\(g.name)”?")
        case .remove(let g, let m)?: return Text("Remove \(m.name) from “\(g.name)”?")
        case nil: return Text(verbatim: "")
        }
    }

    private var canCreate: Bool {
        let t = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !busy && (1...40).contains(t.count)
    }

    private var canJoin: Bool { !busy && GroupInvite.code(from: pasted) != nil }

    private func create() {
        guard canCreate else { return }
        actions.create(newName)
        newName = ""
    }

    private func join() {
        guard canJoin else { return }
        actions.join(pasted)
        pasted = ""
    }

    @ViewBuilder private var status: some View {
        if busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Waiting for the leaderboard server…").font(.callout).foregroundStyle(.secondary)
            }
        } else if let error {
            Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if !pasted.isEmpty, GroupInvite.code(from: pasted) == nil {
            Text("That is not an invitation link or code.").font(.callout).foregroundStyle(.secondary)
        } else if let notice {
            Label { Text(verbatim: notice) } icon: { Image(systemName: "checkmark.circle") }
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private func card(_ g: GroupValue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(verbatim: g.name).font(.headline).lineLimit(1)
                if g.isOwner {
                    Text("Owner")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Palette.accent.opacity(0.25)))
                }
                Spacer()
                Text("Members: \(g.memberCount)").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Menu {
                    Button("Show Ranking") { actions.show(g) }
                    if g.isOwner {
                        Divider()
                        Button("Rename…") {
                            renameText = g.name
                            renaming = g
                        }
                        Button("New Link…") { pending = .renew(g) }
                        Button("Delete Group…", role: .destructive) { pending = .delete(g) }
                    }
                    Divider()
                    Button("Leave Group…", role: .destructive) { pending = .leave(g) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel(Text("More for “\(g.name)”"))
            }
            HStack(spacing: 8) {
                Button("Invite…", systemImage: "square.and.arrow.up") { actions.invite(g) }
                Button("Copy Invitation", systemImage: "doc.on.doc") { actions.copy(g) }
                Spacer()
            }
            .controlSize(.small)
            DisclosureGroup(isExpanded: .init(get: { expanded.contains(g.id) },
                                              set: { if $0 { expanded.insert(g.id) } else { expanded.remove(g.id) } })) {
                VStack(spacing: 2) {
                    ForEach(g.members) { m in member(m, in: g) }
                }
                .padding(.top, 4)
            } label: {
                Text("Members").font(.callout)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
        .disabled(busy)
    }

    private func member(_ m: GroupMemberValue, in g: GroupValue) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: m.name).fontWeight(m.isMe ? .semibold : .regular).lineLimit(1)
            if let login = m.login, !login.isEmpty, login != m.name {
                Text(verbatim: "@\(login)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if m.isOwner { Text("Owner").font(.caption).foregroundStyle(.secondary) }
            if m.isMe { Text("You").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if g.isOwner, !m.isOwner, !m.isMe {
                Button("Remove…") { pending = .remove(g, m) }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

/// What an invitation link opens: one click to join, or the GitHub sign-in first when not on the leaderboard yet
/// (the group join follows on its own).
struct InviteSheet: View {
    enum Phase: Equatable { case ready, busy, joined(String) }

    /// On the leaderboard already: joining is one request. Otherwise the GitHub sign-in comes first.
    let onLeaderboard: Bool
    var phase: Phase = .ready
    var error: String?
    var join: () -> Void = {}
    var close: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label {
                if case .joined(let name) = phase {
                    Text("You're in “\(name)”").font(.title3.weight(.semibold))
                } else {
                    Text("Join a Group").font(.title3.weight(.semibold))
                }
            } icon: {
                Image(systemName: "person.2.fill").foregroundStyle(Palette.accent)
            }
            Group {
                if case .joined = phase {
                    Text("The group's ranking is now in the Leaderboard window and in the leaderboard widget (Edit Widget › Board).")
                } else if onLeaderboard {
                    Text("You were invited to a group on the TokenMaccer leaderboard. Its members see your display name, your GitHub username and your totals on the group's ranking, as on the global leaderboard. You can leave the group at any time.")
                } else {
                    Text("Groups are part of the TokenMaccer leaderboard. Sign in with GitHub to join the leaderboard; joining the group follows right after. Only your period totals are shared, never prompts or projects.")
                }
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            if phase == .busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Group {
                        if onLeaderboard {
                            Text("Joining the group…")
                        } else {
                            Text("Waiting for GitHub and the leaderboard server…")
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error {
                Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if case .joined = phase {
                    Button(action: close) { Text("Show Ranking").primaryLabel() }
                        .buttonStyle(.borderedProminent).tint(Palette.buttonBackground).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel, action: close)
                        .keyboardShortcut(.cancelAction)
                        .disabled(phase == .busy)
                    Button(action: join) {
                        Group {
                            if onLeaderboard {
                                Text("Join Group")
                            } else {
                                Text("Join with GitHub")
                            }
                        }
                        .primaryLabel()
                    }
                    .buttonStyle(.borderedProminent).tint(Palette.buttonBackground).keyboardShortcut(.defaultAction)
                    .disabled(phase == .busy)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
