import Foundation

/// Where one collection pass reads and writes.
public struct CollectorConfig: Sendable {
    /// store.json, backups/ and .lock live here.
    public var dataDir: String
    /// widget.json for the widget (default: dataDir/widget.json).
    public var widgetPath: String
    /// Transcript folders, read in this order (Claude's projects folder first).
    public var sources: [String]
    public var prices: Prices
    /// Pinned local time (ISO 8601, like TOKENMACCER_NOW); nil = the real time.
    public var now: String?
    /// Re-read everything; days whose transcripts are gone are kept from the existing store.
    public var rebuild: Bool
    /// App Group whose container receives widget.json (nil = standalone run).
    public var appGroup: String?

    public init(
        dataDir: String, widgetPath: String? = nil, sources: [String], prices: Prices, now: String? = nil,
        rebuild: Bool = false, appGroup: String? = nil
    ) {
        self.dataDir = dataDir
        self.widgetPath = widgetPath ?? joinPath(dataDir, "widget.json")
        self.sources = sources
        self.prices = prices
        self.now = now
        self.rebuild = rebuild
        self.appGroup = appGroup
    }
}

public struct CollectorResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var newTurns: Int
}

public enum Collector {
    /// `os.path.expanduser`
    static func expandUser(_ path: String, environment: [String: String]) -> String {
        guard path.hasPrefix("~") else { return path }
        if path == "~" || path.hasPrefix("~/") {
            let home = environment["HOME"] ?? NSHomeDirectory()
            return home + path.dropFirst()
        }
        return (path as NSString).expandingTildeInPath
    }

    public static let usage = """
        tokenmaccer-collector: one collection pass over Claude Code transcripts, then exit.

        Options (environment variable in brackets, same names as the Python collector):
          --data-dir PATH     store.json, backups/ [TOKENMACCER_DATA_DIR]
                              default ~/Library/Application Support/TokenMaccer
          --app-group ID      App Group of the widget [TOKENMACCER_APP_GROUP]; inside TokenMaccer.app the app's group
          --widget-out PATH   widget.json [TOKENMACCER_WIDGET_PATH], default with an App Group
                              ~/Library/Group Containers/<ID>/widget.json, otherwise <data dir>/widget.json
          --claude-dir PATH   Claude Code config dir [TOKENMACCER_CLAUDE_DIR, CLAUDE_CONFIG_DIR], default ~/.claude
          --source PATH       extra transcript folder, repeatable [TOKENMACCER_EXTRA_SOURCES, ':'-separated]
          --prices PATH       price table [TOKENMACCER_PRICES], default: the copy linked into this binary
          --now ISO           pin the current local time [TOKENMACCER_NOW]
          --rebuild           re-read everything; keeps days whose transcripts are gone
        """

    /// widget.json in the App Group container (what the sandboxed widget reads via containerURL).
    public static func groupWidgetPath(home: String, appGroup: String) -> String {
        joinPath(home, "Library/Group Containers/\(appGroup)/widget.json")
    }

    /// Builds the configuration from command-line arguments (without argv[0]) and the environment.
    /// `appGroup` is the fallback App Group (the hosting app's), used when neither flag nor variable sets one.
    public static func configuration(
        arguments: [String], environment env: [String: String], appGroup defaultGroup: String? = nil
    ) throws -> CollectorConfig {
        var opts: [String: String] = [:]
        var extra: [String] = []
        var rebuild = false
        var i = 0
        while i < arguments.count {
            let a = arguments[i]
            switch a {
            case "--rebuild": rebuild = true
            case "--data-dir", "--widget-out", "--claude-dir", "--source", "--prices", "--now", "--app-group":
                guard i + 1 < arguments.count else { throw CollectorError(description: "\(a) needs a value") }
                i += 1
                if a == "--source" { extra.append(arguments[i]) } else { opts[a] = arguments[i] }
            default:
                throw CollectorError(description: "unknown argument \(a)\n\n\(usage)")
            }
            i += 1
        }
        func value(_ flag: String, _ names: String...) -> String? {
            if let v = opts[flag] { return v }
            for n in names { if let v = env[n], !v.isEmpty { return v } }
            return nil
        }
        let x = { (p: String) in expandUser(p, environment: env) }
        let dataDir = x(value("--data-dir", "TOKENMACCER_DATA_DIR") ?? "~/Library/Application Support/TokenMaccer")
        let claudeDir = x(value("--claude-dir", "TOKENMACCER_CLAUDE_DIR", "CLAUDE_CONFIG_DIR") ?? "~/.claude")
        let envExtra = (env["TOKENMACCER_EXTRA_SOURCES"] ?? "").split(separator: ":").map(String.init)
        let sources = [joinPath(claudeDir, "projects")] + (envExtra + extra).filter { !$0.isEmpty }.map(x)
        let prices: Prices
        if let p = value("--prices", "TOKENMACCER_PRICES") {
            prices = try Prices(contentsOf: URL(fileURLWithPath: x(p)))
        } else if let p = Prices.embedded() {
            prices = p
        } else if let url = Bundle.main.url(forResource: "prices", withExtension: "json") {
            prices = try Prices(contentsOf: url)
        } else {
            throw CollectorError(description: "no price table: pass --prices /path/to/prices.json")
        }
        let group = value("--app-group", "TOKENMACCER_APP_GROUP") ?? defaultGroup.flatMap { $0.isEmpty ? nil : $0 }
        let widgetPath =
            value("--widget-out", "TOKENMACCER_WIDGET_PATH").map(x)
            ?? group.map { groupWidgetPath(home: x("~"), appGroup: $0) }
        return CollectorConfig(
            dataDir: dataDir, widgetPath: widgetPath, sources: sources,
            prices: prices, now: value("--now", "TOKENMACCER_NOW"), rebuild: rebuild, appGroup: group)
    }

    /// Re-read everything without losing history: per day the version with more input wins.
    static func rebuild(_ old: Store, sources: [String], today: CivilDate) -> (Store, Int) {
        var new = Store()
        let n = ingest(&new, sources: sources, today: today)
        for (day, models) in old.days {
            let oldSum = models.reduce(0) { $0 + totalInput($1.1) }
            let newSum = (new.days[day] ?? OrderedDict()).reduce(0) { $0 + totalInput($1.1) }
            if oldSum > newSum { new.days[day] = models }
        }
        return (new, n)
    }

    /// One collection pass: lock, load, back up, ingest, write store (only with new turns) and widget.json.
    public static func run(_ config: CollectorConfig) -> CollectorResult {
        let t0 = Date()
        var out: [String] = []
        func fail(_ message: String) -> CollectorResult {
            CollectorResult(exitCode: 1, stdout: out.joined(separator: "\n"), stderr: message, newTurns: 0)
        }
        let now: LocalTime
        if let pinned = config.now {
            guard let t = LocalTime.parseISO(pinned) else { return fail("invalid time: \(pinned)") }
            now = t
        } else {
            now = LocalTime.now()
        }
        let files = StoreFiles(dataDir: config.dataDir)
        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: config.dataDir, withIntermediateDirectories: true)
        } catch {
            return fail("cannot create \(config.dataDir): \(error.localizedDescription)")
        }
        let lock = open(joinPath(config.dataDir, ".lock"), O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard lock >= 0 else { return fail("cannot open the lock file in \(config.dataDir)") }
        defer { close(lock) }
        if flock(lock, LOCK_EX | LOCK_NB) != 0 {
            return CollectorResult(
                exitCode: 0, stdout: "another collector run is in progress; skipping", stderr: "", newTurns: 0)
        }
        var store: Store
        switch files.load() {
        case .failed(let message): return fail(message)
        case .loaded(let s, let message):
            store = s
            if let message { out.append(message) }
        }
        files.backup(today: now.date)
        let n: Int
        if config.rebuild {
            let r = rebuild(store, sources: config.sources, today: now.date)
            store = r.0
            n = r.1
        } else {
            n = ingest(&store, sources: config.sources, today: now.date)
        }
        do {
            // Write the store only when something changed: the job runs every 5 minutes, mostly with nothing new
            if n > 0 || config.rebuild || !fm.fileExists(atPath: files.store) {
                try saveAtomic(files.store, JSONWriter.encode(store.json))
            }
            let w = WidgetBuilder(store: store, prices: config.prices).widgetData(now: now)
            try saveAtomic(config.widgetPath, JSONWriter.encode(w))
            let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
            out.append("\(n) new turns · \(secs) s · updated \(w["updated"]?.string ?? "")")
        } catch {
            return fail("cannot write: \(error.localizedDescription)")
        }
        return CollectorResult(exitCode: 0, stdout: out.joined(separator: "\n"), stderr: "", newTurns: n)
    }
}
