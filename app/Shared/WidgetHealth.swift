import Foundation

/// Outcome of one read of widget.json.
enum WidgetRead: String, Equatable, Sendable {
    case ok
    /// The App Group container was not granted (containerURL returned nil).
    case noContainer
    /// No widget.json at the expected place (not collected yet, or the sandbox hides it).
    case missing
    /// widget.json is there but cannot be read or decoded.
    case unreadable
}

/// What the app edition shows about the widget. The app cannot look into the sandboxed widget, so the
/// widget leaves a note in the shared App Group defaults after every read and the app reports that note,
/// instead of assuming the widget sees what the collector wrote.
enum WidgetStatus: Equatable, Sendable {
    /// The widget never read anything (not added to the desktop yet).
    case notSeen
    /// The widget read the numbers recently.
    case showing(Date)
    /// The last successful read is old (widget probably removed); no failure since.
    case idle(Date)
    /// The latest read failed.
    case failed(WidgetRead, lastSuccess: Date?)
}

enum WidgetHealth {
    static let lastReadKey = "widgetLastRead"
    static let lastAttemptKey = "widgetLastAttempt"
    static let resultKey = "widgetLastResult"
    /// A widget on the desktop reloads every 5 minutes; older than this means it is not running.
    static let freshFor: TimeInterval = 30 * 60

    /// Called by the widget after each read.
    static func record(_ result: WidgetRead, at date: Date = .now, in defaults: UserDefaults) {
        defaults.set(date.timeIntervalSince1970, forKey: lastAttemptKey)
        defaults.set(result.rawValue, forKey: resultKey)
        if result == .ok { defaults.set(date.timeIntervalSince1970, forKey: lastReadKey) }
    }

    /// Called by the app to report the widget's state.
    static func status(in defaults: UserDefaults, now: Date = .now) -> WidgetStatus {
        func date(_ key: String) -> Date? {
            defaults.object(forKey: key) == nil ? nil : Date(timeIntervalSince1970: defaults.double(forKey: key))
        }
        let lastRead = date(lastReadKey)
        guard let attempt = date(lastAttemptKey) else { return .notSeen }
        let result = defaults.string(forKey: resultKey).flatMap(WidgetRead.init(rawValue:)) ?? .unreadable
        if result != .ok { return .failed(result, lastSuccess: lastRead) }
        let seen = lastRead ?? attempt
        return now.timeIntervalSince(seen) <= freshFor ? .showing(seen) : .idle(seen)
    }
}
