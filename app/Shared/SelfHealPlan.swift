import Foundation

/// Decisions of the app edition's self-heal after an update, kept free of side effects for the tests.
///
/// Why it exists: when TokenMaccer.app is replaced (Sparkle or by hand), macOS keeps the widget process of the
/// old bundle alive. chronod then rejects its timelines ("Bundle version did not match", timelineReloadFailed,
/// CHSErrorDomain 1050) and pauses the widget for an hour; clicks on the widget stop working.
///
/// When it heals: at every launch where the widget has not yet confirmed the running build, or where a widget
/// process of this app does not run the installed executable (a stale process). The second condition does not
/// depend on the build number, so a reinstall of the same build heals too. The confirmation is only recorded
/// once the widget reported this build after the heal started; a failed heal is retried at the next launch.
enum SelfHealPlan {
    /// Build seen at the previous launch (App Group defaults), only for the log line "build changed".
    static let lastBuildKey = "lastLaunchedBuild"
    /// Build the widget confirmed after a heal. Missing or different: the next launch heals again.
    static let confirmedBuildKey = "selfHealConfirmedBuild"
    /// Build of the widget process that wrote the last read note (set by the widget, read by the app).
    static let widgetBuildKey = "widgetBuild"
    /// Per-machine switch in the app's own defaults, for tests: "off" disables the self-heal
    /// (defaults write <bundle id> TMSelfHeal off). Anything else, or nothing, leaves it on.
    static let modeKey = "TMSelfHeal"
    /// Seconds after the start of a heal at which, while the widget has not confirmed, stale widget processes
    /// are ended again and the reload is asked for again (an outside reload request lifts chronod's one-hour
    /// pause, measured 02.11.2026). The heal waits up to `confirmWindow` seconds in total.
    static let retryAt: Set<Int> = [16, 34]
    static let confirmWindow = 60

    static func isEnabled(defaultsValue: String?) -> Bool { defaultsValue != "off" }

    /// A different build than the one seen at the previous launch (first launch ever counts too).
    static func buildChanged(last: String?, current: String) -> Bool { last != current }

    /// Heal at this launch: the widget has not confirmed this build yet, or a stale widget process runs.
    static func needsHeal(confirmedBuild: String?, current: String, staleProcesses: Int) -> Bool {
        confirmedBuild != current || staleProcesses > 0
    }

    /// The widget confirms the heal: it reported the current build at or after the start of the heal.
    /// (A note from before the heal may come from the old process of a reinstalled same build.)
    static func widgetConfirms(widgetBuild: String?, reportedAt: Date?, current: String, healStarted: Date) -> Bool {
        guard widgetBuild == current, let reportedAt else { return false }
        return reportedAt >= healStarted
    }

    /// Path of a running process that is a widget extension of this app's bundle name. The old process of a
    /// replaced bundle can still report the old path (same place) or a path in a deleted or moved bundle, so
    /// only the tail is compared: …/<App>.app/Contents/PlugIns/<Widget>.appex/Contents/MacOS/<Widget>.
    static func isWidgetProcess(path: String, appName: String, widgetName: String) -> Bool {
        path.hasSuffix("/\(appName).app/Contents/PlugIns/\(widgetName).appex/Contents/MacOS/\(widgetName)")
    }

    /// The code signature of a running process, as far as it could be read.
    struct Signature: Equatable {
        var identifier: String?
        var team: String?
    }

    /// A running process is this app's widget extension. Decided by the code signature when it can be read:
    /// the identifier must be the widget's bundle identifier (`<app bundle id>.widget`) and, when this app is
    /// signed by a team, the team must be the same. That keeps a renamed copy of this app in, and a foreign
    /// bundle with the same names (another fork, a development build with another bundle prefix) out, whatever
    /// its path. Only when the signature cannot be read (executable deleted or moved away) the path tail
    /// decides, as before.
    static func isOwnWidget(signature: Signature?, paths: [String], widgetIdentifier: String, team: String?,
                            appName: String, widgetName: String) -> Bool {
        if let signature, let identifier = signature.identifier {
            guard identifier == widgetIdentifier else { return false }
            if let team { return signature.team == team }
            return true
        }
        return paths.contains { isWidgetProcess(path: $0, appName: appName, widgetName: widgetName) }
    }

    /// A widget process that does not run the installed widget executable: its executable path is gone or
    /// elsewhere (bundle moved away by Sparkle, deleted, trashed), it was started from elsewhere, or it started
    /// before the installed executable was written (bundle replaced in place, also with the same build number).
    /// `installedChangedAt` is the status-change time (ctime) of the installed executable; copying tools keep
    /// the modification time, but every newly written file gets a new ctime.
    static func isStale(currentPath: String?, launchPath: String?, installed: String,
                        startedAt: Date, installedChangedAt: Date?) -> Bool {
        guard let currentPath, currentPath == installed else { return true }
        if let launchPath, launchPath != installed { return true }
        if let installedChangedAt, startedAt < installedChangedAt { return true }
        return false
    }
}
