import Foundation
import XCTest

/// The app and the widget make no requests of their own: leaderboard boards and GitHub avatars come from files the
/// collector writes, and the collector sends nothing without opt-in (LeaderboardTests, LeaderboardBoardsTests).
/// The only network code in the app is Sparkle and the system's GitHub sign-in window (ASWebAuthenticationSession,
/// started by the user's click on "Continue with GitHub").
final class AppNetworkTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // Tests
        .deletingLastPathComponent().deletingLastPathComponent()  // app

    static let networkAPIs = ["URLSession", "URLRequest", "AsyncImage", "NSURLConnection", "dataTask(", "CFNetwork",
                              "Network.framework", "NWConnection", "contentsOf: URL(string"]

    func swiftFiles(_ folder: String) throws -> [URL] {
        let dir = Self.repo.appendingPathComponent(folder)
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }

    func hits(_ file: URL) throws -> [String] {
        let text = try String(contentsOf: file, encoding: .utf8)
        return Self.networkAPIs.filter { text.contains($0) }
    }

    func testAppAndWidgetSourcesHaveNoNetworkCalls() throws {
        let files = try swiftFiles("App") + swiftFiles("Shared") + swiftFiles("Widget")
        XCTAssertTrue(files.contains { $0.lastPathComponent == "LeaderboardWindow.swift" }, "scan found the app sources")
        for file in files {
            XCTAssertEqual(try hits(file), [], "\(file.lastPathComponent) calls the network")
        }
    }

    /// Positive control: the scan does find the collector's transport.
    func testScanFindsTheCollectorsTransport() throws {
        let core = try swiftFiles("Collector/Core")
        let leaderboard = try XCTUnwrap(core.first { $0.lastPathComponent == "Leaderboard.swift" })
        XCTAssertTrue(try hits(leaderboard).contains("URLSession"))
    }
}
