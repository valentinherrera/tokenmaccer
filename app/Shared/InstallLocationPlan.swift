import Foundation

/// Decisions of the app edition's "Move to Applications" check at launch, kept free of side effects for the tests.
///
/// Why it exists: started from the DMG, from Downloads or from a zip (macOS then runs it from a hidden, read-only
/// App Translocation copy), the app used to register its collector and its widget from that place. Spotlight,
/// Launch Services and the widget gallery then knew a second TokenMaccer next to the one in /Applications, and the
/// background agent pointed at a copy that disappears with the DMG. The check runs before anything is registered:
/// outside the Applications folder the app asks to move itself there and starts again from the copy.
enum InstallLocationPlan {
    /// Per-machine switch in the app's own defaults, for tests: "off" disables the check
    /// (defaults write <bundle id> TMMoveCheck off). Anything else, or nothing, leaves it on.
    static let modeKey = "TMMoveCheck"

    static func isEnabled(defaultsValue: String?) -> Bool { defaultsValue != "off" }

    enum Place: Equatable {
        /// /Applications or ~/Applications (also a subfolder of either): nothing to do.
        case applications
        /// A copy macOS runs from a randomised read-only folder because the app was opened where it was downloaded.
        case translocated
        /// A mounted disk image (the DMG) or another read-only volume.
        case readOnlyVolume
        /// Any other writable place (Downloads, Desktop, a build folder).
        case elsewhere
    }

    /// Where a bundle runs from. `bundlePath` is the running bundle; `home` the real home folder (not the
    /// container); `readOnly` whether its volume is read-only.
    static func place(bundlePath: String, home: String, readOnly: Bool) -> Place {
        let path = standardized(bundlePath)
        if path.contains("/AppTranslocation/") { return .translocated }
        for dir in applicationFolders(home: home) where path.hasPrefix(dir + "/") { return .applications }
        return readOnly ? .readOnlyVolume : .elsewhere
    }

    /// The folders that count as installed: the system Applications folder and the user's own.
    static func applicationFolders(home: String) -> [String] {
        ["/Applications", standardized(home) + "/Applications"]
    }

    /// Whether the dialog is offered. Debug builds run from DerivedData and never ask.
    static func shouldOffer(place: Place, isApp: Bool, enabled: Bool, debugBuild: Bool) -> Bool {
        isApp && enabled && !debugBuild && place != .applications
    }

    /// Where the copy goes: /Applications/<name>.app, the place the DMG shows and install.sh uses.
    static func destination(bundleName: String) -> String { "/Applications/" + bundleName }

    /// Whether the bundle the app started from is removed once the copy runs. A disk image is ejected instead
    /// (its contents stay untouched); the destination itself is never removed.
    /// `originalPath` is the bundle before translocation (equal to the running path when not translocated).
    static func trashOriginal(originalPath: String, originalReadOnly: Bool, destination: String) -> Bool {
        !originalReadOnly && standardized(originalPath) != standardized(destination)
    }

    /// The mount point of the volume holding `path` when that volume is one of the mounted disk images
    /// (`imageMountPoints`, read from `hdiutil info`), otherwise nil. Only such a volume is ejected after the move.
    static func diskImageToEject(path: String, imageMountPoints: [String]) -> String? {
        let path = standardized(path)
        return imageMountPoints.map(standardized).filter { $0 != "/" && path.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count })
    }

    private static func standardized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}
