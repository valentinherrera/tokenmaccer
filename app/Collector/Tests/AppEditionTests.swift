import Foundation
import XCTest

@testable import TokenMaccerCore

/// App edition leftovers: the transcripts folder for the background agent (settings.json) and the
/// take-over of a source install inside the agent's own first pass.
extension CollectorTests {

    /// launchd starts the agent without CLAUDE_CONFIG_DIR: the folder the app saved in settings.json is used,
    /// an explicit flag or variable still wins, and without the file nothing changes.
    func testSettingsFileGivesTheAgentTheClaudeDir() throws {
        let home = tmp + "/home"
        let dataDir = tmp + "/support"
        let env = ["HOME": home, "TOKENMACCER_PRICES": CollectorTests.pricesURL.path, "TOKENMACCER_DATA_DIR": dataDir]
        func firstSource(_ e: [String: String] = [:], _ args: [String] = []) throws -> String? {
            try Collector.configuration(arguments: args, environment: env.merging(e) { $1 }).sources.first
        }
        // default case: no settings file, nothing written by reading the configuration
        XCTAssertEqual(try firstSource(), home + "/.claude/projects")
        XCTAssertFalse(FileManager.default.fileExists(atPath: AppSettings.path(dataDir: dataDir)))

        try AppSettings(claudeDir: "/Volumes/work/claude-config").save(dataDir: dataDir)
        XCTAssertEqual(AppSettings.load(dataDir: dataDir), AppSettings(claudeDir: "/Volumes/work/claude-config"))
        XCTAssertEqual(try firstSource(), "/Volumes/work/claude-config/projects")
        XCTAssertEqual(try firstSource(["CLAUDE_CONFIG_DIR": "/env/claude"]), "/env/claude/projects")
        XCTAssertEqual(try firstSource([:], ["--claude-dir", "/flag/claude"]), "/flag/claude/projects")

        // an unreadable or empty settings file falls back to the default instead of stopping the collector
        try Data("{broken".utf8).write(to: URL(fileURLWithPath: AppSettings.path(dataDir: dataDir)))
        XCTAssertEqual(try firstSource(), home + "/.claude/projects")
        try AppSettings().save(dataDir: dataDir)
        XCTAssertEqual(try firstSource(), home + "/.claude/projects")
    }

    /// settings.json "extraSources": the agent also reads an archive folder, and a session that exists both
    /// in projects/ and in the archive (moved or copied) is counted once.
    func testSettingsExtraSourcesAreReadAndDeduplicated() throws {
        let archive = tmp + "/archive"
        let dataDir = tmp + "/support"
        let env = ["HOME": tmp + "/home", "TOKENMACCER_PRICES": CollectorTests.pricesURL.path,
                   "TOKENMACCER_DATA_DIR": dataDir]
        try AppSettings(extraSources: [archive, ""]).save(dataDir: dataDir)
        XCTAssertEqual(AppSettings.load(dataDir: dataDir).extraSources, [archive])
        let sources = try Collector.configuration(arguments: [], environment: env).sources
        XCTAssertEqual(sources, [tmp + "/home/.claude/projects", archive])

        let live = write("live.jsonl", [turn("m1", ts(0), inp: 5, cread: 0)])
        try FileManager.default.createDirectory(atPath: archive + "/p", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: live, toPath: archive + "/p/live.jsonl")
        let old = line(turn("m0", ts(45, 12), inp: 7, cread: 0)) + "\n"
        try Data(old.utf8).write(to: URL(fileURLWithPath: archive + "/p/old.jsonl"))
        var cfg = try config()
        cfg.sources.append(archive)
        XCTAssertEqual(Collector.run(cfg).exitCode, 0)
        XCTAssertEqual(total(), 12, "archive-only session counted, duplicated session counted once")
    }

    /// "Choose Folder…" accepts the config folder itself or its projects folder.
    func testChosenFolderBecomesTheClaudeDir() throws {
        XCTAssertEqual(AppSettings.claudeDir(fromChosen: claude), claude)
        XCTAssertEqual(AppSettings.claudeDir(fromChosen: claude + "/projects"), claude)
        XCTAssertEqual(AppSettings.claudeDir(fromChosen: tmp + "/elsewhere/projects"), tmp + "/elsewhere")
        XCTAssertEqual(AppSettings.claudeDir(fromChosen: tmp + "/other"), tmp + "/other")
    }

    /// The agent may run before the app window ever opens (RunAtLoad): it takes over the source install's
    /// history itself, before its first pass, so the order cannot start an empty store and lose the history.
    func testAgentTakesOverHistoryBeforeItsFirstPass() throws {
        let home = tmp + "/home"
        let legacy = LegacyMigration.legacyDataDir(home: home)
        write("a.jsonl", [turn("m1", ts(1, 10)), turn("m2", ts(0))])
        // a source install: the Python collector's data folder with store.json
        _ = Collector.run(
            CollectorConfig(
                dataDir: legacy, sources: [claude + "/projects"], prices: try Prices(contentsOf: Self.pricesURL),
                now: nowISO))
        let oldStore = FileManager.default.contents(atPath: legacy + "/store.json")
        XCTAssertNotNil(oldStore)

        let support = tmp + "/support"
        let env = ["HOME": home, "TOKENMACCER_PRICES": CollectorTests.pricesURL.path]
        let args = ["--data-dir", support, "--claude-dir", claude, "--now", nowISO]
        let agent = try Collector.configuration(arguments: args, environment: env, appGroup: "ABCDE12345.tokenmaccer")
        XCTAssertEqual(agent.legacyDir, legacy)
        let r = Collector.run(agent)
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        XCTAssertTrue(r.stdout.hasPrefix("took over the history in \(legacy)"), r.stdout)
        XCTAssertEqual(r.newTurns, 0, "continues from the copied offsets, nothing counted twice")
        XCTAssertEqual(FileManager.default.contents(atPath: legacy + "/store.json"), oldStore, "old folder untouched")
        XCTAssertTrue(r.stdout.split(separator: "\n").last?.hasPrefix("0 new turns") == true, r.stdout)

        // the store exists now: a later pass (or the app) copies nothing and keeps the agent's store
        try Data("{}".utf8).write(to: URL(fileURLWithPath: legacy + "/store.json"))
        let again = Collector.run(agent)
        XCTAssertFalse(again.stdout.contains("took over"), again.stdout)
        XCTAssertNotEqual(FileManager.default.contents(atPath: support + "/store.json"), Data("{}".utf8))

        // a standalone run (no App Group) never touches ~/.claude/tools/tokenmaccer
        let standalone = try Collector.configuration(arguments: args, environment: env)
        XCTAssertNil(standalone.legacyDir)
    }
}
