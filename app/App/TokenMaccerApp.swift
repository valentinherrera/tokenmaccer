import AppKit
import Sparkle
import SwiftUI
import TokenMaccerCore
import WidgetKit

@main
struct TokenMaccerApp: App {
    @AppStorage(MenuBarSetting.key) private var showInMenuBar = MenuBarSetting.defaultValue

    init() {
        // For removal without the window: TokenMaccer.app/Contents/MacOS/TokenMaccer --unregister [--remove-data]
        if Edition.isApp, CommandLine.arguments.contains("--unregister") {
            Setup.unregisterFromCommandLine(removeData: CommandLine.arguments.contains("--remove-data"))
        }
        SelfHeal.runAtLaunch()
        if Edition.isApp { _ = Updates.controller }
    }

    // One status window (single instance, so the menu bar and the Dock bring back the same one), the leaderboard
    // window, Settings (⌘,) and the menu bar item. The status window stays the main window: it shows state and
    // actions (collector, widget, leaderboard membership), which is not what Settings is for; Settings holds the
    // one real preference.
    var body: some Scene {
        Window("TokenMaccer", id: "main") {
            if Edition.isApp {
                SetupView()
            } else {
                Overview()
            }
        }
        .windowResizability(.contentSize)
        // tokenmaccer://leaderboard goes to the leaderboard window, nothing else opens a window from a link
        .handlesExternalEvents(matching: [])
        .commands {
            if Edition.isApp {
                CommandGroup(after: .appInfo) {
                    WelcomeButton()
                    CheckForUpdatesButton()
                }
                CommandGroup(before: .windowList) {
                    LeaderboardMenuButton()
                    Divider()
                }
            }
        }

        Window("Leaderboard", id: "leaderboard") {
            LeaderboardWindow()
        }
        .windowResizability(.contentSize)
        .handlesExternalEvents(matching: ["leaderboard"])

        Settings {
            SettingsScene()
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarContent()
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Window › Leaderboard (⌘L).
struct LeaderboardMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Leaderboard") {
            openWindow(id: "leaderboard")
            NSApp.activate()
        }
        .keyboardShortcut("l", modifiers: .command)
    }
}

/// Sparkle, app edition only (started in `init`). Sparkle asks the user once (second launch)
/// whether to check automatically; "Check for Updates…" always works.
@MainActor
enum Updates {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
}

/// "Check for Updates…" for the app menu and the window; disabled while Sparkle is busy.
struct CheckForUpdatesButton: View {
    @State private var canCheck = Updates.controller.updater.canCheckForUpdates
    private let changes = Updates.controller.updater.publisher(for: \.canCheckForUpdates)

    var body: some View {
        Button("Check for Updates…") { Updates.controller.checkForUpdates(nil) }
            .disabled(!canCheck)
            .onReceive(changes) { canCheck = $0 }
    }
}

/// App edition: whether the window shows the first-run onboarding (OnboardingPlan says who gets it).
@MainActor @Observable
final class Welcome {
    static let shared = Welcome()
    private(set) var visible: Bool
    /// Debug builds with -TMForceOnboarding: shown at every launch, the "done" flag is never written.
    private let forced: Bool

    private init() {
        #if DEBUG
        forced = CommandLine.arguments.contains(OnboardingPlan.forceArgument)
        #else
        forced = false
        #endif
        guard Edition.isApp else {
            visible = false
            return
        }
        let home = WidgetData.realHome ?? NSHomeDirectory()
        let existing = OnboardingPlan.existingInstall(
            dataDir: home + "/Library/Application Support/TokenMaccer",
            legacyDir: LegacyMigration.legacyDataDir(home: home),
            fileExists: { FileManager.default.fileExists(atPath: $0) })
        visible = OnboardingPlan.shouldShow(
            done: UserDefaults.standard.bool(forKey: OnboardingPlan.doneKey), existingInstall: existing, forced: forced)
    }

    func show() { visible = true }

    func finish() {
        visible = false
        if !forced { UserDefaults.standard.set(true, forKey: OnboardingPlan.doneKey) }
    }
}

/// "Welcome…" in the app menu: the onboarding again, in the open window or a new one.
struct WelcomeButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Welcome…") {
            Welcome.shared.show()
            openWindow(id: "main")  // a single window: brings it back or opens it
            NSApp.activate()
        }
    }
}

/// Host app window: the same view as the large widget, plus how to add the widget.
struct Overview: View {
    @AppStorage("period", store: appGroup.flatMap { UserDefaults(suiteName: $0) }) private var period = "1D"
    @AppStorage("unit", store: appGroup.flatMap { UserDefaults(suiteName: $0) }) private var unit = "tokens"
    @State private var data = WidgetData.load()
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TickerView(data: data, period: period, unit: Unit(rawValue: unit) ?? .tokens, size: .large)
                .frame(width: 340, height: 340)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 20).fill(.quaternary))
            Text("Add the widget: right-click the desktop, choose “Edit Widgets…”, search for “TokenMaccer”.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 372, alignment: .leading)
        }
        .padding(20)
        .onReceive(tick) { _ in
            data = WidgetData.load()
        }
        .onChange(of: period) { WidgetCenter.shared.reloadAllTimelines() }
        .onChange(of: unit) { WidgetCenter.shared.reloadAllTimelines() }
    }
}
