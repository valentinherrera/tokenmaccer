import Sparkle
import SwiftUI
import WidgetKit

@main
struct TokenMaccerApp: App {
    init() {
        // For removal without the window: TokenMaccer.app/Contents/MacOS/TokenMaccer --unregister [--remove-data]
        if Edition.isApp, CommandLine.arguments.contains("--unregister") {
            Setup.unregisterFromCommandLine(removeData: CommandLine.arguments.contains("--remove-data"))
        }
        SelfHeal.runAtLaunch()
        if Edition.isApp { _ = Updates.controller }
    }

    var body: some Scene {
        WindowGroup("TokenMaccer") {
            if Edition.isApp {
                SetupView()
            } else {
                Overview()
            }
        }
        .windowResizability(.contentSize)
        .commands {
            if Edition.isApp {
                CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
            }
        }
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
