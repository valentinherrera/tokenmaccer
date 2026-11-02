import Foundation
import XCTest

/// The app edition's status window reports what the widget itself saw (Shared/WidgetHealth.swift),
/// not what the collector wrote. These tests pin the widget's read outcomes and the status derived from them.
final class WidgetHealthTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var dir: URL!

    override func setUpWithError() throws {
        suite = "tokenmaccer.tests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: read outcomes

    func testReadWithoutContainerIsNoContainer() {
        let r = WidgetData.read(from: nil)
        XCTAssertNil(r.data)
        XCTAssertEqual(r.result, .noContainer)
    }

    func testReadMissingFile() {
        XCTAssertEqual(WidgetData.read(from: dir.appendingPathComponent("widget.json")).result, .missing)
    }

    func testReadGarbageIsUnreadable() throws {
        let url = dir.appendingPathComponent("widget.json")
        try Data("{not json".utf8).write(to: url)
        XCTAssertEqual(WidgetData.read(from: url).result, .unreadable)
        XCTAssertNil(WidgetData.load(from: url))
    }

    func testReadValidFile() throws {
        let url = dir.appendingPathComponent("widget.json")
        try Data(#"{"updated":"2026-11-02T03:00:00Z","periods":{},"order":["1D"]}"#.utf8).write(to: url)
        let r = WidgetData.read(from: url)
        XCTAssertEqual(r.result, .ok)
        XCTAssertEqual(r.data?.order, ["1D"])
        XCTAssertNotNil(WidgetData.load(from: url))
    }

    // MARK: status

    func testNothingRecordedIsNotSeen() {
        XCTAssertEqual(WidgetHealth.status(in: defaults), .notSeen)
    }

    func testRecentSuccessIsShowing() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        WidgetHealth.record(.ok, at: t, in: defaults)
        XCTAssertEqual(WidgetHealth.status(in: defaults, now: t.addingTimeInterval(5 * 60)), .showing(t))
    }

    func testOldSuccessIsIdle() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        WidgetHealth.record(.ok, at: t, in: defaults)
        XCTAssertEqual(WidgetHealth.status(in: defaults, now: t.addingTimeInterval(31 * 60)), .idle(t))
    }

    /// The case the reviewer raised: the collector wrote, but the widget could not get the container.
    func testFailureIsReportedEvenAfterEarlierSuccess() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        WidgetHealth.record(.ok, at: t, in: defaults)
        WidgetHealth.record(.noContainer, at: t.addingTimeInterval(300), in: defaults)
        XCTAssertEqual(
            WidgetHealth.status(in: defaults, now: t.addingTimeInterval(310)), .failed(.noContainer, lastSuccess: t))
    }

    func testFirstReadFailingHasNoLastSuccess() {
        WidgetHealth.record(.unreadable, in: defaults)
        XCTAssertEqual(WidgetHealth.status(in: defaults), .failed(.unreadable, lastSuccess: nil))
    }

    func testRecoveryAfterFailure() {
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        WidgetHealth.record(.missing, at: t, in: defaults)
        WidgetHealth.record(.ok, at: t.addingTimeInterval(300), in: defaults)
        XCTAssertEqual(
            WidgetHealth.status(in: defaults, now: t.addingTimeInterval(310)), .showing(t.addingTimeInterval(300)))
    }
}
