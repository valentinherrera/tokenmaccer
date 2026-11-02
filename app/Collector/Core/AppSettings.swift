import Foundation

/// Settings the app edition hands to its background collector. The agent runs under launchd without the
/// user's shell environment, so a CLAUDE_CONFIG_DIR the app saw (or a folder the user chose) is kept in
/// `<data dir>/settings.json`. Without that file everything stays at the defaults (~/.claude).
public struct AppSettings: Equatable, Sendable {
    /// Claude Code config folder whose `projects/` holds the transcripts (nil = ~/.claude).
    public var claudeDir: String?

    public init(claudeDir: String? = nil) { self.claudeDir = claudeDir }

    public static func path(dataDir: String) -> String { joinPath(dataDir, "settings.json") }

    /// Missing or unreadable file = defaults (the collector must never stop over this file).
    public static func load(dataDir: String) -> AppSettings {
        guard let data = FileManager.default.contents(atPath: path(dataDir: dataDir)),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return AppSettings() }
        let dir = (obj["claudeDir"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return AppSettings(claudeDir: dir)
    }

    public func save(dataDir: String) throws {
        try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        var obj: [String: Any] = [:]
        if let claudeDir { obj["claudeDir"] = claudeDir }
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
