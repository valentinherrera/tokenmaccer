import Foundation

/// Settings the app edition hands to its background collector. The agent runs under launchd without the
/// user's shell environment, so a CLAUDE_CONFIG_DIR the app saw (or a folder the user chose) is kept in
/// `<data dir>/settings.json`. Without that file everything stays at the defaults (~/.claude).
public struct AppSettings: Equatable, Sendable {
    /// Claude Code config folder whose `projects/` holds the transcripts (nil = ~/.claude).
    public var claudeDir: String?
    /// Further transcript folders read in addition to `projects/`, e.g. an archive the user moves sessions
    /// into (key "extraSources"; the same idea as TOKENMACCER_EXTRA_SOURCES for the source edition).
    public var extraSources: [String]

    public init(claudeDir: String? = nil, extraSources: [String] = []) {
        self.claudeDir = claudeDir
        self.extraSources = extraSources
    }

    public static func path(dataDir: String) -> String { joinPath(dataDir, "settings.json") }

    /// Missing or unreadable file = defaults (the collector must never stop over this file).
    public static func load(dataDir: String) -> AppSettings {
        guard let data = FileManager.default.contents(atPath: path(dataDir: dataDir)),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return AppSettings() }
        let dir = (obj["claudeDir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let extra = (obj["extraSources"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
        return AppSettings(claudeDir: dir, extraSources: extra)
    }

    public func save(dataDir: String) throws {
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        var obj: [String: Any] = [:]
        if let claudeDir { obj["claudeDir"] = claudeDir }
        if !extraSources.isEmpty { obj["extraSources"] = extraSources }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try saveAtomic(Self.path(dataDir: dataDir), data)
    }

    /// The folder a user picked in the open panel, as a Claude config dir: either the config dir itself
    /// (it contains `projects/`) or its `projects` folder. Anything else is taken as is.
    public static func claudeDir(fromChosen path: String) -> String {
        var isDir: ObjCBool = false
        let fm = FileManager.default
        if fm.fileExists(atPath: joinPath(path, "projects"), isDirectory: &isDir), isDir.boolValue { return path }
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "projects" { return url.deletingLastPathComponent().path }
        return path
    }
}
