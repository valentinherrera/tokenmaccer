import AppKit
import SwiftUI

// The first-run onboarding and the one-button leaderboard join, as plain views over values. The app fills them
// from Setup and Leaderboard (Setup.swift, Leaderboard.swift); app/Preview/Onboarding renders them to PNGs from
// fixtures. Nothing here touches files, defaults or the network. Strings are LocalizedStringKeys, German in
// Localizable.xcstrings.

/// What the join panel shows: before, during and after the sign-in.
struct JoinStatus: Equatable {
    enum Phase: Equatable { case idle, busy, joined }
    var phase: Phase = .idle
    var error: String?
    var displayName: String?
    var githubLogin: String?
    /// Own place for `period` and `usd`; nil until the first report came back.
    var rank: Int?
    var participants: Int?
    var period = "1D"
    var usd = false
    /// A rename is on its way to the server.
    var renaming = false
}

enum PrivacyNotice {
    /// docs/privacy.md as hosted on tokenmaccer.app (German: /privacy/de), the copy README and website link to. The app does not
    /// link it: the consent opens the copy bundled with the app (bundledMarkdown), which needs no network and
    /// cannot be a dead page. scripts/check_hosted_release.sh reads this line and checks it and the German
    /// docs/privacy.de.md before a release.
    static let privacyURL = URL(string: "https://tokenmaccer.app/privacy")!

    /// docs/privacy.md, or docs/privacy.de.md when the app runs in German, from the app bundle (project.yml copies
    /// both); nil only in a build without them (the preview renderer passes the files itself).
    static var bundledMarkdown: String? {
        let german = Bundle.main.preferredLocalizations.first?.hasPrefix("de") == true
        guard let url = Bundle.main.url(forResource: german ? "privacy.de" : "privacy", withExtension: "md")
            ?? Bundle.main.url(forResource: "privacy", withExtension: "md") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The bundled privacy notice in a sheet.
struct PrivacyNoticeSheet: View {
    let markdown: String?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let markdown {
                        ForEach(Array(PrivacyText.parse(markdown).enumerated()), id: \.offset) { _, block in
                            view(block)
                        }
                    } else {
                        Text(verbatim: "docs/privacy.md is missing from this build.").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
                .textSelection(.enabled)
            }
            Divider()
            HStack {
                Spacer()
                Button(action: close) { Text("Done").primaryLabel() }
                    .buttonStyle(.borderedProminent).tint(Palette.buttonBackground).keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 580, height: 620)
    }

    @ViewBuilder
    private func view(_ block: PrivacyText.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text)
                .font(level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 0 : 8)
        case .paragraph(let text):
            inline(text).font(.callout)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "•").foregroundStyle(.secondary)
                inline(text)
            }
            .font(.callout)
        case .table(let header, let rows):
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 3) {
                        inline(row.first ?? "").font(.callout.weight(.semibold))
                        ForEach(Array(row.indices.dropFirst()), id: \.self) { i in
                            inline(i < header.count ? "**\(header[i]):** \(row[i])" : row[i])
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func inline(_ s: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(attributed).fixedSize(horizontal: false, vertical: true)
    }
}

/// Consent in two lines, the full text behind "Details", the privacy notice, then one button. After joining:
/// the own place, large, and the display name GitHub gave (editable).
struct JoinPanel: View {
    let status: JoinStatus
    var privacyMarkdown = PrivacyNotice.bundledMarkdown
    /// Start with the details open (preview renderer).
    var detailsOpen = false
    let join: () -> Void
    let rename: (String) -> Void

    var body: some View {
        if status.phase == .joined {
            JoinedView(status: status, rename: rename)
        } else {
            consent
        }
    }

    @State private var showDetails: Bool?
    @State private var showPrivacy = false

    private var consent: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("At most every 10 minutes, TokenMaccer sends your token and USD totals per period. Never prompts, projects or file names.")
                Text("Others see your display name, your GitHub username and these totals. Leave at any time, and your account and totals are deleted from the server.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: Binding(get: { showDetails ?? detailsOpen }, set: { showDetails = $0 })) {
                ConsentDetails().padding(.top, 6)
            } label: {
                Text("Details").font(.callout)
            }
            Button("Privacy Notice") { showPrivacy = true }
                .buttonStyle(.link).font(.callout)
                .sheet(isPresented: $showPrivacy) {
                    PrivacyNoticeSheet(markdown: privacyMarkdown) { showPrivacy = false }
                }
            VStack(alignment: .leading, spacing: 6) {
                Button(action: join) {
                    HStack(spacing: 8) {
                        if status.phase == .busy { ProgressView().controlSize(.small) }
                        Text(status.phase == .busy ? "Waiting for GitHub…" : "Continue with GitHub")
                    }
                    .primaryLabel()
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.buttonBackground)
                .controlSize(.large)
                // Return joins, here and in the onboarding's last step (whose footer has no default button then)
                .keyboardShortcut(.defaultAction)
                .disabled(status.phase == .busy)
                Text("Your display name will be your GitHub username; you can change it right after.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = status.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The full consent text (formerly the join sheet's list).
struct ConsentDetails: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("arrow.up.circle", "At most every 10 minutes, TokenMaccer sends your totals for today, 7 days, 30 days, year to date, 1 year and all time: input and output tokens and their value in USD at API prices.")
            row("lock", "Never projects, prompts, file names or any other content. Everything else stays on this Mac.")
            row("person.2", "Other participants see your display name, your GitHub username and these totals.")
            row("photo", "The leaderboard window shows the participants' GitHub profile pictures, downloaded from GitHub (avatars.githubusercontent.com). GitHub sees your IP address, as with any download.")
            row("person.crop.circle", "Signing in creates an account on the leaderboard server (Supabase, EU) with what GitHub passes on: your GitHub user ID, username, name, email address and avatar link. Only the server sees these, apart from the username. Its sign-in and request logs record your IP address.")
            row("trash", "Leave at any time: your account, your profile and all reported totals are deleted from the server. Only your GitHub user ID and the time of your last report stay a little longer (removed with the first report the server receives once they are an hour old), so leaving and joining again cannot get around the report limit.")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol)
        }
    }
}

/// After joining: "#3 of 120", the board it belongs to, and the display name.
struct JoinedView: View {
    let status: JoinStatus
    let rename: (String) -> Void
    @State private var name: String?

    private var shown: String { name ?? status.displayName ?? "" }
    private var trimmed: String { shown.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { (1...32).contains(trimmed.count) && trimmed != status.displayName && !status.renaming }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RankHero(rank: status.rank, participants: status.participants, period: status.period, usd: status.usd)
            VStack(alignment: .leading, spacing: 4) {
                Text("Display name").font(.callout.weight(.medium))
                HStack {
                    TextField("Display name", text: Binding(get: { shown }, set: { name = $0 }),
                              prompt: Text("1–32 characters"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { if canSave { rename(trimmed) } }
                    if status.renaming { ProgressView().controlSize(.small) }
                    Button("Save") { rename(trimmed) }.disabled(!canSave)
                }
                if let login = status.githubLogin, !login.isEmpty {
                    Text("Shown next to your GitHub username @\(login).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = status.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The own place, large.
struct RankHero: View {
    let rank: Int?
    let participants: Int?
    let period: String
    let usd: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let rank, let participants {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(verbatim: "#\(rank)")
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("of \(participants)")
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    Text(Self.periodName(period))
                    Text(verbatim: "·")
                    Text(usd ? "USD" : "Tokens")
                }
                .font(.callout).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("You're in. Your place appears after the first report.")
                        .font(.callout)
                }
                .frame(minHeight: 56, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }

    static func periodName(_ k: String) -> LocalizedStringKey {
        switch k {
        case "1D": return "Today"
        case "7D": return "7 days"
        case "30D": return "30 days"
        case "YTD": return "Year to date"
        case "1Y": return "1 year"
        default: return "All time"
        }
    }
}

/// The status window's empty state when no Claude Code transcripts were found.
struct NoClaudeDataNote: View {
    var body: some View {
        Label {
            Text("No Claude Code data yet. Claude Code writes its transcripts to ~/.claude/projects once you use it; if yours are somewhere else, choose that folder above.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "doc.text.magnifyingglass")
        }
    }
}

// MARK: Onboarding

/// Three steps for a new install: what it does, add the widget (checks off when the widget runs), the leaderboard
/// (optional).
struct OnboardingView: View {
    @Binding var step: OnboardingPlan.Step
    let transcriptsFound: Bool
    let transcriptsPath: String
    let widgetRunning: Bool
    let join: JoinStatus
    var privacyMarkdown = PrivacyNotice.bundledMarkdown
    var detailsOpen = false
    var chooseFolder: () -> Void = {}
    var joinAction: () -> Void = {}
    var rename: (String) -> Void = { _ in }
    var finish: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepIndicator(step: step, widgetRunning: widgetRunning, joined: join.phase == .joined)
                .padding([.horizontal, .top], 24)
            Group {
                switch step {
                case .about: about
                case .widget: widget
                case .leaderboard: leaderboard
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
            Divider()
            footer.padding(16)
        }
        .frame(width: 520)
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp?.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to TokenMaccer").font(.title2.weight(.semibold))
                    Text("A Mac widget that shows your Claude Code usage in tokens and USD at API prices.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Feature(symbol: "doc.text.magnifyingglass", title: "Reads Claude Code's transcripts on this Mac",
                        detail: nil) {
                    HStack(spacing: 6) {
                        Image(systemName: transcriptsFound ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(transcriptsFound ? Palette.success : Palette.warning)
                        Text(verbatim: transcriptsPath).textSelection(.enabled)
                        if !transcriptsFound {
                            Text("not found")
                            Button("Choose Folder…", action: chooseFolder).controlSize(.small)
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Feature(symbol: "chart.line.uptrend.xyaxis", title: "Shows your tokens and their value in USD",
                        detail: "At API prices, for today, 7 and 30 days, the year and all time. Updated every 5 minutes.") {
                    EmptyView()
                }
                Feature(symbol: "lock", title: "Everything stays on this Mac",
                        detail: "Unless you join the leaderboard in step 3; that is optional.") {
                    EmptyView()
                }
            }
        }
    }

    private var widget: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add the widget").font(.title2.weight(.semibold))
            HStack(alignment: .top, spacing: 20) {
                WidgetIllustration(done: widgetRunning)
                    .frame(width: 200, height: 150)
                VStack(alignment: .leading, spacing: 10) {
                    Numbered(1, "Right-click an empty spot on the desktop and choose “Edit Widgets…”.")
                    Numbered(2, "Search for “TokenMaccer”.")
                    Numbered(3, "Drag a size you like onto the desktop.")
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if widgetRunning {
                    Label("The widget is running.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.success)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Waiting for the widget… This step checks itself off.").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.callout)
            .animation(.default, value: widgetRunning)
        }
    }

    private var leaderboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(join.phase == .joined ? "You're on the leaderboard" : "Compare with others")
                    .font(.title2.weight(.semibold))
                if join.phase != .joined {
                    Text("Optional. Join with your GitHub account, or skip and join later from the window.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            JoinPanel(status: join, privacyMarkdown: privacyMarkdown, detailsOpen: detailsOpen, join: joinAction,
                      rename: rename)
        }
    }

    private var footer: some View {
        HStack {
            if step != .about && join.phase != .joined {
                Button("Back") { step = OnboardingPlan.Step(rawValue: step.rawValue - 1) ?? .about }
            }
            Spacer()
            switch step {
            case .about, .widget:
                if step == .widget && !widgetRunning {
                    Button("Later") { step = .leaderboard }
                }
                Button { step = OnboardingPlan.Step(rawValue: step.rawValue + 1) ?? .leaderboard } label: {
                    Text("Continue").primaryLabel()
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.buttonBackground)
                .keyboardShortcut(.defaultAction)
                .disabled(step == .widget && !widgetRunning)
            case .leaderboard:
                if join.phase == .joined {
                    Button(action: finish) { Text("Done").primaryLabel() }
                        .buttonStyle(.borderedProminent).tint(Palette.buttonBackground).keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip", action: finish).disabled(join.phase == .busy)
                }
            }
        }
    }
}

/// "1 What it does · 2 Widget · 3 Leaderboard", with checkmarks for what is done.
struct StepIndicator: View {
    let step: OnboardingPlan.Step
    let widgetRunning: Bool
    let joined: Bool

    var body: some View {
        HStack(spacing: 14) {
            item(.about, "What it does", done: step.rawValue > 0)
            item(.widget, "Widget", done: widgetRunning)
            item(.leaderboard, "Leaderboard", done: joined)
            Spacer()
        }
        .font(.caption.weight(.medium))
    }

    private func item(_ s: OnboardingPlan.Step, _ title: LocalizedStringKey, done: Bool) -> some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().fill(done ? Palette.success : s == step ? Palette.accent : Color.secondary.opacity(0.25))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Palette.onAccent)
                } else {
                    Text(verbatim: "\(s.rawValue + 1)").font(.system(size: 10, weight: .bold))
                        .foregroundStyle(s == step ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: 18, height: 18)
            Text(title).foregroundStyle(s == step ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(s == step ? .isSelected : [])
    }
}

private struct Feature<Extra: View>: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.tint).frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.medium))
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary) }
                extra
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct Numbered: View {
    let n: Int
    let text: LocalizedStringKey
    init(_ n: Int, _ text: LocalizedStringKey) {
        self.n = n
        self.text = text
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
    }
}

/// A desktop with the widget gallery: a widget tile moves from the gallery onto the desktop, again and again,
/// until the real widget runs (then it stays, with a checkmark). Still with Reduce Motion.
struct WidgetIllustration: View {
    let done: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragged = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let placed = done || dragged || reduceMotion
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [.blue.opacity(0.55), .purple.opacity(0.45)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                // widget gallery at the bottom
                RoundedRectangle(cornerRadius: 8)
                    .fill(.regularMaterial)
                    .frame(width: w - 24, height: h * 0.34)
                    .offset(x: 12, y: h * 0.62)
                ForEach(0..<3) { i in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.secondary.opacity(0.25))
                        .frame(width: 34, height: 34)
                        .offset(x: 24 + CGFloat(i) * 44, y: h * 0.62 + 9)
                }
                // the TokenMaccer tile
                tile
                    .frame(width: 58, height: 58)
                    .scaleEffect(placed ? 1 : 0.6, anchor: .topLeading)
                    .offset(x: placed ? 16 : 24, y: placed ? 14 : h * 0.62 + 9)
                if !done {
                    Image(systemName: "cursorarrow")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(radius: 1)
                        .offset(x: placed ? 60 : 50, y: placed ? 54 : h * 0.62 + 30)
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(done ? Text("The widget is on the desktop.") : Text("Drag the widget from the gallery onto the desktop."))
        .onAppear {
            guard !reduceMotion, !done else { return }
            withAnimation(.easeInOut(duration: 1.6).delay(0.6).repeatForever(autoreverses: false)) { dragged = true }
        }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.background)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Capsule().fill(Color.secondary.opacity(0.5)).frame(width: 22, height: 4)
                    Capsule().fill(Color.primary.opacity(0.8)).frame(width: 34, height: 7)
                    Path { p in
                        p.move(to: CGPoint(x: 0, y: 16))
                        p.addLine(to: CGPoint(x: 10, y: 11))
                        p.addLine(to: CGPoint(x: 20, y: 13))
                        p.addLine(to: CGPoint(x: 30, y: 4))
                        p.addLine(to: CGPoint(x: 40, y: 2))
                    }
                    .stroke(Color.green, lineWidth: 1.5)
                    .frame(width: 40, height: 18)
                }
                .padding(7)
            }
            .overlay(alignment: .topTrailing) {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.onAccent, Palette.success)
                        .offset(x: 6, y: -6)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
    }
}
