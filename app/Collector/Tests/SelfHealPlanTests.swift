import XCTest

/// Decisions of the app edition's self-heal after an update (Shared/SelfHealPlan.swift).
final class SelfHealPlanTests: XCTestCase {
    func testBuildChange() {
        XCTAssertTrue(SelfHealPlan.buildChanged(last: "4", current: "5"))
        XCTAssertTrue(SelfHealPlan.buildChanged(last: nil, current: "5"), "first launch after a build without the check")
        XCTAssertFalse(SelfHealPlan.buildChanged(last: "5", current: "5"))
    }

    func testModeFromDefaults() {
        XCTAssertEqual(SelfHealPlan.Mode(defaultsValue: nil), .full)
        XCTAssertEqual(SelfHealPlan.Mode(defaultsValue: "off"), .off)
        XCTAssertEqual(SelfHealPlan.Mode(defaultsValue: "soft"), .soft)
        XCTAssertEqual(SelfHealPlan.Mode(defaultsValue: "nonsense"), .full)
    }

    func testWidgetProcessMatchesOnlyOwnExtension() {
        let own = "/Applications/TokenMaccer.app/Contents/PlugIns/TokenMaccerWidget.appex/Contents/MacOS/TokenMaccerWidget"
        XCTAssertTrue(SelfHealPlan.isWidgetProcess(path: own, appName: "TokenMaccer", widgetName: "TokenMaccerWidget"))
        // the old bundle moved to the Trash by the update still counts
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

    func testChronodRestartOnlyAsFallback() {
        func restart(_ mode: SelfHealPlan.Mode, active: Bool, seen: String?) -> Bool {
            SelfHealPlan.needsChronodRestart(mode: mode, widgetWasActive: active, widgetBuildAfterWait: seen, current: "5")
        }
        XCTAssertTrue(restart(.full, active: true, seen: "4"))
        XCTAssertTrue(restart(.full, active: true, seen: nil))
        XCTAssertFalse(restart(.full, active: true, seen: "5"), "soft steps worked")
        XCTAssertFalse(restart(.full, active: false, seen: nil), "widget not on the desktop: nothing to heal")
        XCTAssertFalse(restart(.soft, active: true, seen: "4"))
        XCTAssertFalse(restart(.off, active: true, seen: "4"))
    }
}
