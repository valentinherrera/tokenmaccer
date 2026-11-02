import Foundation

/// Takes over the history of a source install (install.sh + Python collector, data in
/// ~/.claude/tools/tokenmaccer/) the first time the app edition starts. The old folder is only read:
/// nothing is moved or deleted there, so the source install keeps working until the user removes it.
public enum LegacyMigration {
    public enum Outcome: Equatable, Sendable {
        /// The app edition already has a store (or nothing to take over).
        case notNeeded
        /// store.json and this many backups were copied.
        case copied(backups: Int)
        /// The old store exists but cannot be read as a store; nothing was copied.
        case skipped(String)
    }

    /// Default location of the source install's data folder.
    public static func legacyDataDir(home: String) -> String { joinPath(home, ".claude/tools/tokenmaccer") }

    /// Copies `legacyDir/store.json` (and the readable `backups/store-*.json`) into `dataDir`
    /// when `dataDir/store.json` does not exist yet. Files are validated with the collector's own reader
    /// first, so the collector never starts from a file it would reject.
    public static func run(legacyDir: String, dataDir: String) -> Outcome {
        let fm = FileManager.default
        let old = StoreFiles(dataDir: legacyDir)
        let new = StoreFiles(dataDir: dataDir)
        guard !fm.fileExists(atPath: new.store), fm.fileExists(atPath: old.store) else { return .notNeeded }
        guard let data = fm.contents(atPath: old.store), isStore(data) else {
            return .skipped("\(old.store) is not a readable TokenMaccer store")
        }
        do {
            // The store first: backups without a store.json would make the collector stop (by design).
            try saveAtomic(new.store, data)
            var copied = 0
            let backups = old.backupFiles().filter { fm.contents(atPath: $0).map(isStore) ?? false }
            if !backups.isEmpty {
                try fm.createDirectory(atPath: new.backups, withIntermediateDirectories: true)
                for b in backups {
                    let target = joinPath(new.backups, (b as NSString).lastPathComponent)
                    if fm.fileExists(atPath: target) { continue }
                    try fm.copyItem(atPath: b, toPath: target)
                    copied += 1
                }
            }
            return .copied(backups: copied)
        } catch {
            return .skipped("copy failed: \(error.localizedDescription)")
        }
    }

    static func isStore(_ data: Data) -> Bool {
        guard let json = try? JSONParser.parse(data) else { return false }
        return Store(json: json) != nil
    }
}
