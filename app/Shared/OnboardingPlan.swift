import Foundation

/// Decisions of the app edition's first-run onboarding, kept free of side effects for the tests.
///
/// Who sees it: a new install only. An existing install (a store or a leaderboard state in the data folder, or a
/// history an install.sh setup left that the collector takes over) never gets it on its own; the menu item
/// "Welcome…" opens it any time. Debug builds also open it with the launch argument `-TMForceOnboarding`
/// (screenshots, tests), which never writes the "done" flag.
///
/// Step 2 ("Add the widget") checks itself off from the note the widget leaves in the App Group defaults after
/// every timeline read on the desktop (WidgetHealth), the same signal the self-heal waits for. Reads for the
/// widget gallery's preview do not leave that note, so opening the gallery alone does not check the step off.
enum OnboardingPlan {
    /// The user finished or skipped the onboarding (the app's own defaults).
    static let doneKey = "onboardingDone"
    /// Debug builds only: show the onboarding at every launch.
    static let forceArgument = "-TMForceOnboarding"

    enum Step: Int, CaseIterable, Sendable {
        case about, widget, leaderboard
    }

    /// Files whose presence marks an existing install (paths relative to the data folder or the legacy folder).
    static func existingInstall(dataDir: String, legacyDir: String?, fileExists: (String) -> Bool) -> Bool {
        var paths = [dataDir + "/store.json", dataDir + "/leaderboard.json"]
        if let legacyDir { paths.append(legacyDir + "/store.json") }
        return paths.contains(where: fileExists)
    }

    static func shouldShow(done: Bool, existingInstall: Bool, forced: Bool) -> Bool {
        forced || (!done && !existingInstall)
    }

    /// The widget is on the desktop: it read (successfully or not) within the last `WidgetHealth.freshFor`.
    /// A failed read counts: the widget runs, it only has no numbers yet.
    static func widgetRunning(in defaults: UserDefaults, now: Date = .now) -> Bool {
        guard defaults.object(forKey: WidgetHealth.lastAttemptKey) != nil else { return false }
        let attempt = Date(timeIntervalSince1970: defaults.double(forKey: WidgetHealth.lastAttemptKey))
        return now.timeIntervalSince(attempt) <= WidgetHealth.freshFor
    }
}
