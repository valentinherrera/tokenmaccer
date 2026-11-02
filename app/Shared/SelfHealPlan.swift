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
    /// Per-machine switch in the app's own defaults, for tests: "off" disables the self-heal
    /// (defaults write <bundle id> TMSelfHeal off). Anything else, or nothing, leaves it on.
    static let modeKey = "TMSelfHeal"

    static func isEnabled(defaultsValue: String?) -> Bool { defaultsValue != "off" }

    /// A different build than the one recorded last time. The first launch ever (nothing recorded) counts too:
    /// it may follow an update from a build that did not record anything yet.
    static func buildChanged(last: String?, current: String) -> Bool { last != current }

    /// Path of a running process that is a widget extension of this app's bundle name. The old process of a
    /// replaced bundle can still report the old path (same place) or a path in a deleted or moved bundle, so
    /// only the tail is compared: …/<App>.app/Contents/PlugIns/<Widget>.appex/Contents/MacOS/<Widget>.
    static func isWidgetProcess(path: String, appName: String, widgetName: String) -> Bool {
        path.hasSuffix("/\(appName).app/Contents/PlugIns/\(widgetName).appex/Contents/MacOS/\(widgetName)")
    }
}
