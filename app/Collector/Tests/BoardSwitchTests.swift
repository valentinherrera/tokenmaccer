import Foundation
import XCTest

@testable import TokenMaccerCore

// The leaderboard widget's title click (BoardSelection.board / next / setBoard in Shared/LeaderboardWidgetData.swift):
// global → the user's groups → global, kept per Edit Widget choice.
final class BoardSwitchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""
    private let a = "AAAA-1111"
    private let b = "BBBB-2222"

    override func setUp() {
        suite = "tokenmaccer.tests.boardswitch.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testCycleOrderGlobalThenGroupsThenGlobal() {
        XCTAssertEqual(BoardSelection.next(after: nil, groups: [a, b]), a)
        XCTAssertEqual(BoardSelection.next(after: a, groups: [a, b]), b)
        XCTAssertNil(BoardSelection.next(after: b, groups: [a, b]))
        // ids compare without case (the server sends lower case, Edit Widget may keep upper case)
        XCTAssertEqual(BoardSelection.next(after: a.lowercased(), groups: [a, b]), b)
    }

    func testCycleWithoutGroupsStaysGlobal() {
        XCTAssertNil(BoardSelection.next(after: nil, groups: []))
    }

    func testCurrentGroupNoLongerListedGoesBackToGlobal() {
        XCTAssertNil(BoardSelection.next(after: "gone", groups: [a, b]))
    }

    func testNoClickShowsTheEditWidgetChoice() {
        XCTAssertNil(BoardSelection.board(configured: nil, defaults: defaults, groups: [a]))
        XCTAssertEqual(BoardSelection.board(configured: b, defaults: defaults, groups: [a, b]), b)
    }

    func testClickedBoardIsKeptPerChoice() {
        BoardSelection.setBoard(a, configured: nil, defaults: defaults)
        XCTAssertEqual(BoardSelection.board(configured: nil, defaults: defaults, groups: [a, b]), a)
        // a widget with another Edit Widget choice keeps its own board
        XCTAssertEqual(BoardSelection.board(configured: b, defaults: defaults, groups: [a, b]), b)
    }

    func testClickedGlobalOverridesAGroupChoice() {
        BoardSelection.setBoard(nil, configured: b, defaults: defaults)
        XCTAssertNil(BoardSelection.board(configured: b, defaults: defaults, groups: [a, b]))
    }

    func testClickedGroupTheUserLeftFallsBackToTheChoice() {
        BoardSelection.setBoard(a, configured: nil, defaults: defaults)
        XCTAssertNil(BoardSelection.board(configured: nil, defaults: defaults, groups: [b]))
        // group list not fetched yet: keep the clicked group (it shows "waiting", never a silent switch)
        XCTAssertEqual(BoardSelection.board(configured: nil, defaults: defaults, groups: nil), a)
    }

    func testFullRoundTripOfClicks() {
        var shown: [String?] = []
        for _ in 0..<4 {
            let current = BoardSelection.board(configured: nil, defaults: defaults, groups: [a, b])
            BoardSelection.setBoard(BoardSelection.next(after: current, groups: [a, b]), configured: nil,
                                    defaults: defaults)
            shown.append(BoardSelection.board(configured: nil, defaults: defaults, groups: [a, b]))
        }
        XCTAssertEqual(shown, [a, b, nil, a])
    }
}
