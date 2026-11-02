import Foundation
import XCTest

/// First-run onboarding (Shared/OnboardingPlan.swift): who sees it, and when the widget step checks itself off.
final class OnboardingPlanTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "tokenmaccer.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOnlyNewInstallsSeeTheOnboarding() {
        let data = "/Users/x/Library/Application Support/TokenMaccer"
        let legacy = "/Users/x/.claude/tools/tokenmaccer"
        func existing(_ files: Set<String>) -> Bool {
            OnboardingPlan.existingInstall(dataDir: data, legacyDir: legacy) { files.contains($0) }
        }
        XCTAssertFalse(existing([]))
        XCTAssertTrue(existing([data + "/store.json"]), "history on this Mac")
        XCTAssertTrue(existing([data + "/leaderboard.json"]), "joined (or leaving) without a store yet")
        XCTAssertTrue(existing([legacy + "/store.json"]), "install.sh history the collector takes over")
        XCTAssertFalse(existing([data + "/settings.json"]), "a chosen folder alone is not an install")
        XCTAssertFalse(OnboardingPlan.existingInstall(dataDir: data, legacyDir: nil) { $0 == legacy + "/store.json" })

        XCTAssertTrue(OnboardingPlan.shouldShow(done: false, existingInstall: false, forced: false))
        XCTAssertFalse(OnboardingPlan.shouldShow(done: true, existingInstall: false, forced: false))
        XCTAssertFalse(OnboardingPlan.shouldShow(done: false, existingInstall: true, forced: false),
                       "an existing install (Valentin's) is never interrupted")
        XCTAssertTrue(OnboardingPlan.shouldShow(done: true, existingInstall: true, forced: true))
    }

    /// The widget step checks off from the widget's own note (WidgetHealth.record), failed reads included.
    func testWidgetStepChecksOffFromTheWidgetsNote() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertFalse(OnboardingPlan.widgetRunning(in: defaults, now: now), "never read")
        WidgetHealth.record(.missing, at: now - 10, in: defaults)
        XCTAssertTrue(OnboardingPlan.widgetRunning(in: defaults, now: now), "on the desktop, no numbers yet")
        WidgetHealth.record(.ok, at: now - 5, in: defaults)
        XCTAssertTrue(OnboardingPlan.widgetRunning(in: defaults, now: now))
        XCTAssertFalse(OnboardingPlan.widgetRunning(in: defaults, now: now + WidgetHealth.freshFor + 60),
                       "an old note means the widget is gone")
    }

    func testStepsAreThree() {
        XCTAssertEqual(OnboardingPlan.Step.allCases.count, 3)
    }
}
