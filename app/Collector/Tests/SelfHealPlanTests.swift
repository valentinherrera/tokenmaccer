import XCTest

/// Decisions of the app edition's self-heal after an update (Shared/SelfHealPlan.swift).
final class SelfHealPlanTests: XCTestCase {
    func testBuildChange() {
        XCTAssertTrue(SelfHealPlan.buildChanged(last: "4", current: "5"))
        XCTAssertTrue(SelfHealPlan.buildChanged(last: nil, current: "5"), "first launch after a build without the check")
        XCTAssertFalse(SelfHealPlan.buildChanged(last: "5", current: "5"))
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
}
