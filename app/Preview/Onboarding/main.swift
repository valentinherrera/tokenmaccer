import AppKit
import SwiftUI

// Renders the onboarding steps and the join panel to PNGs (light and dark) from fixtures, without the app,
// its data or the network. Build (from the repository root):
//   xcrun swiftc -parse-as-library app/Shared/*.swift app/App/OnboardingViews.swift \
//     app/Preview/Onboarding/main.swift -o /tmp/tm-onboarding
// Usage: tm-onboarding <output dir> [-AppleLanguages '(de)'], run from the repository root (the privacy notice
// sheet reads docs/privacy.md and docs/privacy.de.md from there).
// German needs the binary inside an .app with de.lproj/Localizable.strings (see README, "Screenshots").
@main
struct OnboardingRenderer {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: tm-onboarding <output dir>")
            exit(2)
        }
        let out = URL(fileURLWithPath: args[1])
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        var joined = JoinStatus(phase: .joined, displayName: "synth-gh", githubLogin: "synth-gh", rank: 3,
                                participants: 120, period: "7D")
        let scenes: [(String, AnyView)] = [
            ("1-about", AnyView(onboarding(.about))),
            ("1-about-no-claude-data", AnyView(onboarding(.about, transcripts: false))),
            ("status-no-claude-data", AnyView(Form {
                Section { NoClaudeDataNote() }
            }.formStyle(.grouped).frame(width: 460).fixedSize(horizontal: false, vertical: true))),
            ("2-widget-waiting", AnyView(onboarding(.widget))),
            ("2-widget-running", AnyView(onboarding(.widget, widget: true))),
            ("3-leaderboard", AnyView(onboarding(.leaderboard, widget: true))),
            ("3-leaderboard-details", AnyView(onboarding(.leaderboard, widget: true, details: true))),
            ("3-leaderboard-busy", AnyView(onboarding(.leaderboard, widget: true, join: JoinStatus(phase: .busy)))),
            ("3-joined-rank", AnyView(onboarding(.leaderboard, widget: true, join: joined))),
            ("3-joined-first-report", AnyView(onboarding(.leaderboard, widget: true, join: {
                joined.rank = nil
                joined.participants = nil
                return joined
            }()))),
            ("4-privacy-notice", AnyView(PrivacyNoticeSheet(markdown: privacyMarkdown(lang)) {})),
        ]
        for (name, view) in scenes {
            for scheme in [ColorScheme.light, .dark] {
                let file = out.appendingPathComponent("onboarding-\(name)-\(scheme == .dark ? "dark" : "light")-\(lang).png")
                if !snapshot(view, dark: scheme == .dark, to: file) { exit(1) }
            }
        }
        print("rendered \(scenes.count * 2) images to \(out.path)")
    }

    @MainActor
    static func onboarding(_ step: OnboardingPlan.Step, widget: Bool = false, details: Bool = false,
                           join: JoinStatus = JoinStatus(), transcripts: Bool = true) -> some View {
        OnboardingView(step: .constant(step), transcriptsFound: transcripts, transcriptsPath: "~/.claude/projects",
                       widgetRunning: widget, join: join, privacyMarkdown: privacyMarkdown(lang), detailsOpen: details)
    }

    static var lang: String { Bundle.main.preferredLocalizations.first ?? "en" }

    static func privacyMarkdown(_ lang: String) -> String? {
        try? String(contentsOfFile: lang.hasPrefix("de") ? "docs/privacy.de.md" : "docs/privacy.md", encoding: .utf8)
    }

    /// Draws the view through AppKit (controls included, unlike ImageRenderer) at 2x, in a window that counts as
    /// key: an inactive window draws the prominent and default buttons grey, so the button hierarchy would not show.
    @MainActor
    static func snapshot(_ view: AnyView, dark: Bool, to url: URL) -> Bool {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor))
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

/// A window AppKit and SwiftUI draw as the active one, without activating the renderer.
final class KeyWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
