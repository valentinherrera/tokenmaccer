import Foundation

/// Decisions of the app edition's clean-up of other registered copies, kept free of side effects for the tests.
///
/// Why it exists: Launch Services keeps every TokenMaccer.app it has seen registered under the same bundle
/// identifier: copies in the Trash, the DMG, App Translocation, build folders. macOS then resolves the widget's
/// App Intents against one of those copies. Measured 02.11.2026 on macOS 26 with 21 such copies (most of them in
/// the Trash, older builds): a click on the leaderboard widget's title failed with "There is no metadata for
/// NextBoard" and every timeline reload failed ("Returned view collection was either nil or empty"), so a new group
/// member never appeared. Unregistering the other copies (lsregister -u) and registering the installed one again
/// made the next reload succeed. NSWorkspace.urlsForApplications and LSCopyApplicationURLsForBundleIdentifier do
/// not list such copies (measured with a registered copy in /private/tmp), so the copies are read from
/// `lsregister -dump`.
///
/// Only Launch Services' registration changes; no file is moved or deleted. A copy that is opened again registers
/// itself again.
enum StaleCopiesPlan {
    /// Per-machine switch in the app's own defaults, for tests: "off" disables the clean-up
    /// (defaults write <bundle id> TMStaleCopies off). Anything else, or nothing, leaves it on.
    static let modeKey = "TMStaleCopies"

    static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    static func isEnabled(defaultsValue: String?) -> Bool { defaultsValue != "off" }

    /// Paths of the registered bundles with exactly this identifier, in the order of the dump. A record of the
    /// dump runs from one line of dashes to the next; its `path:` line ends in " (0x…)", its `identifier:` line
    /// carries the bundle identifier (the widget extension has its own, "<id>.widget", and does not match).
    static func registeredPaths(dump: String, bundleIdentifier: String) -> [String] {
        var paths: [String] = []
        var path: String?
        var identifier: String?
        func flush() {
            if let path, identifier == bundleIdentifier, !paths.contains(path) { paths.append(path) }
            path = nil
            identifier = nil
        }
        dump.enumerateLines { line, _ in
            if line.hasPrefix("--------") {
                flush()
            } else if line.hasPrefix("path:") {
                path = value(line, key: "path:").map(stripObjectID)
            } else if line.hasPrefix("identifier:") {
                identifier = value(line, key: "identifier:")
            }
        }
        flush()
        return paths
    }

    /// The copies to unregister: every registered copy except the running one. Nothing while the app does not run
    /// from an Applications folder (then the running copy is itself the stray one, and moving it is
    /// MoveToApplications' question).
    static func toUnregister(registered: [String], running: String, runningInApplications: Bool) -> [String] {
        guard runningInApplications else { return [] }
        let me = normalized(running)
        var seen: Set<String> = []
        return registered.filter { path in
            let p = normalized(path)
            return p != me && !p.isEmpty && seen.insert(p).inserted
        }
    }

    // MARK: helpers

    private static func value(_ line: String, key: String) -> String? {
        let rest = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// "/Applications/TokenMaccer.app (0x38c4)" → "/Applications/TokenMaccer.app"
    static func stripObjectID(_ s: String) -> String {
        guard s.hasSuffix(")"), let open = s.range(of: " (0x", options: .backwards) else { return s }
        return String(s[..<open.lowerBound])
    }

    /// Standardised, without a trailing slash; /private/var and /var, /private/tmp and /tmp count as the same.
    static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        for prefix in ["/private/var/", "/private/tmp/"] where p.hasPrefix(prefix) {
            p = String(p.dropFirst("/private".count))
        }
        return p
    }
}
