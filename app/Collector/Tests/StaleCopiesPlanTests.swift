import XCTest

/// Decisions of the app edition's clean-up of other registered copies (Shared/StaleCopiesPlan.swift).
final class StaleCopiesPlanTests: XCTestCase {
    private let id = "io.github.valentinherrera.tokenmaccer"

    /// Shape of `lsregister -dump` on macOS 26 (records cut down to the lines that matter, plus noise lines).
    private var dump: String {
        """
        Checking data integrity......done.
        --------------------------------------------------------------------------------
        bundle id:                  TokenMaccer (0x1f00)
        path:                       /Applications/TokenMaccer.app (0x38c4)
        name:                       TokenMaccer
        identifier:                 io.github.valentinherrera.tokenmaccer
        --------------------------------------------------------------------------------
        plugin Identifiers:         io.github.valentinherrera.tokenmaccer.widget (0x38a8)
        path:                       /Applications/TokenMaccer.app/Contents/PlugIns/TokenMaccerWidget.appex (0x38a8)
        identifier:                 io.github.valentinherrera.tokenmaccer.widget
        --------------------------------------------------------------------------------
        bundle id:                  TokenMaccer (0x1f04)
        path:                       /Users/ada/.Trash/TokenMaccer 21-40-29-182.app (0x38a0)
        identifier:                 io.github.valentinherrera.tokenmaccer
        --------------------------------------------------------------------------------
        bundle id:                  Updater (0x1f08)
        path:                       /Applications/TokenMaccer.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app (0x386c)
        identifier:                 org.sparkle-project.Sparkle.Updater
        --------------------------------------------------------------------------------
        bundle id:                  TokenMaccer (0x1f0c)
        path:                       /private/var/folders/xy/T/AppTranslocation/3F2A/d/TokenMaccer.app (0x3964)
        identifier:                 io.github.valentinherrera.tokenmaccer
        --------------------------------------------------------------------------------
        bundle id:                  Other (0x1f10)
        path:                       /Applications/Other.app (0x3970)
        identifier:                 io.github.valentinherrera.tokenmaccer.fork
        --------------------------------------------------------------------------------
        bundle id:                  TokenMaccer (0x1f14)
        identifier:                 io.github.valentinherrera.tokenmaccer
        path:                       /Volumes/TokenMaccer/TokenMaccer.app (0x3974)
        """
    }

    func testRegisteredPathsOnlyThisIdentifier() {
        XCTAssertEqual(StaleCopiesPlan.registeredPaths(dump: dump, bundleIdentifier: id), [
            "/Applications/TokenMaccer.app",
            "/Users/ada/.Trash/TokenMaccer 21-40-29-182.app",
            "/private/var/folders/xy/T/AppTranslocation/3F2A/d/TokenMaccer.app",
            "/Volumes/TokenMaccer/TokenMaccer.app",  // last record: no closing dashes, identifier before path
        ], "not the widget, not Sparkle's Updater, not a bundle whose identifier only starts the same")
    }

    func testRegisteredPathsEmptyOrForeignDump() {
        XCTAssertEqual(StaleCopiesPlan.registeredPaths(dump: "", bundleIdentifier: id), [])
        XCTAssertEqual(StaleCopiesPlan.registeredPaths(dump: dump, bundleIdentifier: "com.example.none"), [])
    }

    func testPathWithSpacesAndParenthesesKeepsItsName() {
        XCTAssertEqual(StaleCopiesPlan.stripObjectID("/Users/ada/.Trash/TokenMaccer (2).app (0x38a0)"),
                       "/Users/ada/.Trash/TokenMaccer (2).app")
        XCTAssertEqual(StaleCopiesPlan.stripObjectID("/Applications/TokenMaccer.app"), "/Applications/TokenMaccer.app")
    }

    func testUnregistersEveryOtherCopy() {
        let registered = StaleCopiesPlan.registeredPaths(dump: dump, bundleIdentifier: id)
        XCTAssertEqual(StaleCopiesPlan.toUnregister(registered: registered, running: "/Applications/TokenMaccer.app/",
                                                    runningInApplications: true), [
            "/Users/ada/.Trash/TokenMaccer 21-40-29-182.app",
            "/private/var/folders/xy/T/AppTranslocation/3F2A/d/TokenMaccer.app",
            "/Volumes/TokenMaccer/TokenMaccer.app",
        ], "the running copy stays, also written with a trailing slash")
    }

    func testNothingOutsideApplications() {
        let registered = StaleCopiesPlan.registeredPaths(dump: dump, bundleIdentifier: id)
        XCTAssertEqual(StaleCopiesPlan.toUnregister(registered: registered, running: "/Volumes/TokenMaccer/TokenMaccer.app",
                                                    runningInApplications: false), [])
    }

    func testRunningCopyMatchedThroughPrivatePrefix() {
        XCTAssertEqual(StaleCopiesPlan.toUnregister(
            registered: ["/private/tmp/x/TokenMaccer.app", "/Applications/TokenMaccer.app", "/Applications/TokenMaccer.app"],
            running: "/tmp/x/TokenMaccer.app", runningInApplications: true),
                       ["/Applications/TokenMaccer.app"], "same copy under /private, duplicates once")
    }

    func testSwitch() {
        XCTAssertTrue(StaleCopiesPlan.isEnabled(defaultsValue: nil))
        XCTAssertTrue(StaleCopiesPlan.isEnabled(defaultsValue: "on"))
        XCTAssertFalse(StaleCopiesPlan.isEnabled(defaultsValue: "off"))
    }
}
