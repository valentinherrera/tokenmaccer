import XCTest

/// Decisions of the app edition's self-heal after an update (Shared/SelfHealPlan.swift).
final class SelfHealPlanTests: XCTestCase {
    func testBuildChange() {
        XCTAssertTrue(SelfHealPlan.buildChanged(last: "4", current: "5"))
        XCTAssertTrue(SelfHealPlan.buildChanged(last: nil, current: "5"), "first launch after a build without the check")
        XCTAssertFalse(SelfHealPlan.buildChanged(last: "5", current: "5"))
    }

    func testHealUntilTheWidgetConfirms() {
        // update from a build without a confirmation (build 8 and older), or a heal that did not get through
        XCTAssertTrue(SelfHealPlan.needsHeal(confirmedBuild: nil, current: "9", staleProcesses: 0))
        XCTAssertTrue(SelfHealPlan.needsHeal(confirmedBuild: "8", current: "9", staleProcesses: 0))
        // confirmed build, nothing stale: no heal (the normal launch)
        XCTAssertFalse(SelfHealPlan.needsHeal(confirmedBuild: "9", current: "9", staleProcesses: 0))
        // same build reinstalled: confirmed, but the old widget process is still running
        XCTAssertTrue(SelfHealPlan.needsHeal(confirmedBuild: "9", current: "9", staleProcesses: 1))
    }

    func testConfirmationNeedsANoteAfterTheHealStarted() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(SelfHealPlan.widgetConfirms(widgetBuild: "9", reportedAt: start, current: "9", healStarted: start))
        XCTAssertTrue(SelfHealPlan.widgetConfirms(widgetBuild: "9", reportedAt: start + 3, current: "9",
                                                  healStarted: start))
        // a note of the same build from before the heal can come from the old process of a reinstall
        XCTAssertFalse(SelfHealPlan.widgetConfirms(widgetBuild: "9", reportedAt: start - 1, current: "9",
                                                   healStarted: start))
        XCTAssertFalse(SelfHealPlan.widgetConfirms(widgetBuild: "8", reportedAt: start + 3, current: "9",
                                                   healStarted: start))
        XCTAssertFalse(SelfHealPlan.widgetConfirms(widgetBuild: nil, reportedAt: start + 3, current: "9",
                                                   healStarted: start))
        XCTAssertFalse(SelfHealPlan.widgetConfirms(widgetBuild: "9", reportedAt: nil, current: "9", healStarted: start))
    }

    func testRetriesFallInsideTheWindow() {
        XCTAssertFalse(SelfHealPlan.retryAt.isEmpty)
        // the heal loop checks every 2 s, so a retry second must be even and before the end of the window
        for second in SelfHealPlan.retryAt {
            XCTAssertEqual(second % 2, 0)
            XCTAssertLessThan(second, SelfHealPlan.confirmWindow)
        }
    }

    func testStaleWidgetProcess() {
        let installed = "/Applications/TokenMaccer.app/Contents/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/"
            + "TokenMaccerWidget"
        let written = Date(timeIntervalSince1970: 1_000)
        // started after the install, from the installed executable: healthy (measured 06:01:18 vs ctime 06:00:51)
        XCTAssertFalse(SelfHealPlan.isStale(currentPath: installed, launchPath: installed, installed: installed,
                                            startedAt: written + 27, installedChangedAt: written))
        // bundle replaced in place (DMG copy, also with the same build number): started before the new file
        XCTAssertTrue(SelfHealPlan.isStale(currentPath: installed, launchPath: installed, installed: installed,
                                           startedAt: written - 60, installedChangedAt: written))
        // Sparkle moved the old bundle away: proc_pidpath fails, the launch path names the cache
        let sparkle = "/Users/x/Library/Caches/io.github.x.tokenmaccer/org.sparkle-project.Sparkle/Installation/1Ty/"
            + "63Z/TokenMaccer.app/Contents/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/TokenMaccerWidget"
        XCTAssertTrue(SelfHealPlan.isStale(currentPath: nil, launchPath: sparkle, installed: installed,
                                           startedAt: written + 5, installedChangedAt: written))
        XCTAssertTrue(SelfHealPlan.isStale(currentPath: sparkle, launchPath: sparkle, installed: installed,
                                           startedAt: written + 5, installedChangedAt: written))
        // started from elsewhere although the path now resolves to the installed one
        XCTAssertTrue(SelfHealPlan.isStale(currentPath: installed, launchPath: sparkle, installed: installed,
                                           startedAt: written + 5, installedChangedAt: written))
        // no launch path readable and no ctime: decided by the current path alone
        XCTAssertFalse(SelfHealPlan.isStale(currentPath: installed, launchPath: nil, installed: installed,
                                            startedAt: written, installedChangedAt: nil))
    }

    func testSwitchFromDefaults() {
        XCTAssertTrue(SelfHealPlan.isEnabled(defaultsValue: nil))
        XCTAssertFalse(SelfHealPlan.isEnabled(defaultsValue: "off"))
        XCTAssertTrue(SelfHealPlan.isEnabled(defaultsValue: "soft"))
    }

    func testWidgetProcessMatchesOnlyOwnExtension() {
        let own = "/Applications/TokenMaccer.app/Contents/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/TokenMaccerWidget"
        XCTAssertTrue(SelfHealPlan.isWidgetProcess(path: own, appName: "TokenMaccer", widgetName: "TokenMaccerWidget"))
        // the old bundle moved away by Sparkle (measured path) still counts
        let sparkle = "/Users/x/Library/Caches/io.github.x.tokenmaccer/org.sparkle-project.Sparkle/Installation/1Ty/63Z/"
            + "TokenMaccer.app/Contents/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/TokenMaccerWidget"
        XCTAssertTrue(SelfHealPlan.isWidgetProcess(path: sparkle, appName: "TokenMaccer", widgetName: "TokenMaccerWidget"))
        // the old bundle moved to the Trash still counts
        let trashed = "/Users/x/.Trash/TokenMaccer.app/Contents/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/TokenMaccerWidget"
        XCTAssertTrue(SelfHealPlan.isWidgetProcess(path: trashed, appName: "TokenMaccer", widgetName: "TokenMaccerWidget"))
        XCTAssertFalse(SelfHealPlan.isWidgetProcess(
            path: "/Applications/TokenMaccer.app/Contents/MacOS/TokenMaccer", appName: "TokenMaccer",
            widgetName: "TokenMaccerWidget"))
        XCTAssertFalse(SelfHealPlan.isWidgetProcess(
            path: "/Applications/OtherTokenMaccer.app/Contents/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/TokenMaccerWidget",
            appName: "TokenMaccer", widgetName: "TokenMaccerWidget"))
        XCTAssertFalse(SelfHealPlan.isWidgetProcess(
            path: "/Users/x/Applications/ClaudeUsage.app/Contents/PlugIns/ClaudeUsageWidget.appex/Contents/MacOS/ClaudeUsageWidget",
            appName: "TokenMaccer", widgetName: "TokenMaccerWidget"))
    }

    /// The code signature decides when it can be read; the path tail only when it cannot.
    func testOwnWidgetBySignature() {
        let id = "io.github.x.tokenmaccer.widget"
        let own = "/Applications/TokenMaccer.app/Contents/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/TokenMaccerWidget"
        let renamed = "/Applications/TokenMaccer 2.app/Contents/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/TokenMaccerWidget"
        func isOwn(_ sig: SelfHealPlan.Signature?, _ paths: [String], team: String? = "TEAM1") -> Bool {
            SelfHealPlan.isOwnWidget(signature: sig, paths: paths, widgetIdentifier: id, team: team,
                                     appName: "TokenMaccer", widgetName: "TokenMaccerWidget")
        }
        XCTAssertTrue(isOwn(.init(identifier: id, team: "TEAM1"), [own]))
        XCTAssertTrue(isOwn(.init(identifier: id, team: "TEAM1"), [renamed]), "a renamed copy of this app is still ours")
        XCTAssertFalse(isOwn(.init(identifier: "com.example.tokenmaccer.widget", team: nil), [own]),
                       "same bundle path, other bundle identifier (a development build): not ours")
        XCTAssertFalse(isOwn(.init(identifier: id, team: "OTHER"), [own]), "same identifier from another team: not ours")
        XCTAssertFalse(isOwn(.init(identifier: id, team: nil), [own]), "ad-hoc copy while this app is team-signed")
        XCTAssertTrue(isOwn(.init(identifier: id, team: nil), [own], team: nil), "unsigned build: identifier alone")
        // signature unreadable (executable deleted or moved): the path tail decides, as before
        XCTAssertTrue(isOwn(nil, [own]))
        XCTAssertTrue(isOwn(.init(identifier: nil, team: nil), [own]))
        XCTAssertFalse(isOwn(nil, [renamed]))
        XCTAssertFalse(isOwn(nil, []))
    }
}
