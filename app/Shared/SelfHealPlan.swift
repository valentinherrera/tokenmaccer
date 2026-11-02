import Foundation

/// Decisions of the app edition's self-heal after an update, kept free of side effects for the tests.
///
/// Why it exists: when TokenMaccer.app is replaced (Sparkle or by hand), macOS keeps the widget process of the
/// old bundle alive. chronod then rejects its timelines ("Bundle version did not match", timelineReloadFailed,
/// CHSErrorDomain 1050) and pauses the widget for an hour; clicks on the widget stop working.
enum SelfHealPlan {
    /// Build that last ran the self-heal check (App Group defaults, so the widget's note and this sit together).
    static let lastBuildKey = "lastLaunchedBuild"
    /// Build of the widget process that wrote the last read note (set by the widget, read by the app).
    static let widgetBuildKey = "widgetBuild"
    /// Per-machine switch in the app's own defaults, for tests: "off" disables the self-heal, "soft" never
    /// restarts chronod. Anything else (or nothing) is the shipped behaviour.
    static let modeKey = "TMSelfHeal"

    enum Mode: String, Sendable {
        case off, soft, full
        init(defaultsValue: String?) { self = defaultsValue.flatMap(Mode.init(rawValue:)) ?? .full }
    }

    /// A different build than the one recorded last time. The first launch ever (nothing recorded) counts too:
    /// it may follow an update from a build that did not record anything yet.
    static func buildChanged(last: String?, current: String) -> Bool { last != current }

    /// Path of a running process that is a widget extension of this app's bundle name. The old process of a
    /// replaced bundle can still report the old path (same place) or a path in a deleted or moved bundle, so
    /// only the tail is compared: …/<App>.app/Contents/PlugIns/<Widget>.appex/Contents/MacOS/<Widget>.
    static func isWidgetProcess(path: String, appName: String, widgetName: String) -> Bool {
        path.hasSuffix("/\(appName).app/Contents/PlugIns/\(widgetName).appex/Contents/MacOS/\(widgetName)")
    }

    /// Restart chronod only when the soft steps were not enough: the widget was on the desktop shortly before
    /// (it read within `WidgetHealth.freshFor`), and after the wait it still has not run from the new build.
    static func needsChronodRestart(
        mode: Mode, widgetWasActive: Bool, widgetBuildAfterWait: String?, current: String
    ) -> Bool {
        mode == .full && widgetWasActive && widgetBuildAfterWait != current
    }
}
