import Foundation
import TokenMaccerCore
import WidgetKit

// One collection pass, then exit (the app registers this as a background agent with a 300 s interval).
// No long-lived process: every run starts with the current time zone and price table.
//
// `tokenmaccer-collector leaderboard join|leave [--display-name NAME] [--data-dir P] [--app-group G]` is the
// app's way into the opt-in leaderboard: join reads {"code": …, "verifier": …} from stdin (the result of the
// GitHub sign-in), both print one JSON line {"ok": true|false, …}. The sign-in tokens stay in this
// program's keychain item.
let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") {
    print(Collector.usage)
    exit(0)
}
let env = ProcessInfo.processInfo.environment
let hostGroup = Bundle.main.object(forInfoDictionaryKey: "TMAppGroup") as? String

func leaderboardSync(_ config: CollectorConfig) -> LeaderboardSync {
    let defaults = config.appGroup.flatMap { UserDefaults(suiteName: $0) }
    let endpoint = LeaderboardEndpoint.resolve(
        environment: env, defaults: defaults, bundled: LeaderboardEndpoint.embeddedConfig())
    let service = env["TOKENMACCER_KEYCHAIN_SERVICE"].flatMap { $0.isEmpty ? nil : $0 }
        ?? (Bundle.main.bundleIdentifier ?? "tokenmaccer-collector") + ".leaderboard"
    return LeaderboardSync(
        dataDir: config.dataDir, endpoint: endpoint, sessions: KeychainSessionStore(service: service),
        transport: { URLSessionTransport() })
}

func reply(_ obj: [String: Any]) -> Never {
    let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data("{}".utf8)
    print(String(decoding: data, as: UTF8.self))
    exit((obj["ok"] as? Bool) == true ? 0 : 1)
}

if args.first == "leaderboard" {
    var rest = Array(args.dropFirst())
    let action = rest.isEmpty ? "" : rest.removeFirst()
    var displayName = ""
    if let i = rest.firstIndex(of: "--display-name"), i + 1 < rest.count {
        displayName = rest[i + 1]
        rest.removeSubrange(i...(i + 1))
    }
    let config: CollectorConfig
    do {
        config = try Collector.configuration(arguments: rest, environment: env, appGroup: hostGroup)
    } catch {
        reply(["ok": false, "error": "\(error)"])
    }
    // the same lock as a collection pass: a running pass finishes its report first
    try? FileManager.default.createDirectory(atPath: config.dataDir, withIntermediateDirectories: true)
    let lock = open(config.dataDir + "/.lock", O_WRONLY | O_CREAT, 0o644)
    if lock >= 0 { flock(lock, LOCK_EX) }
    let sync = leaderboardSync(config)
    switch action {
    case "join":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: String],
            let code = obj["code"], let verifier = obj["verifier"]
        else { reply(["ok": false, "error": "expected {\"code\": …, \"verifier\": …} on stdin"]) }
        do {
            let state = try sync.join(code: code, verifier: verifier, displayName: displayName)
            reply(["ok": true, "display_name": state.displayName ?? "", "github_login": state.githubLogin ?? ""])
        } catch {
            reply(["ok": false, "error": "\(error)"])
        }
    case "leave":
        do {
            try sync.leave()
            reply(["ok": true])
        } catch {
            reply(["ok": false, "error": "\(error)"])
        }
    default:
        reply(["ok": false, "error": "usage: leaderboard join|leave [--display-name NAME]"])
    }
}

do {
    // The background agent passes --app-group; a host app's Info.plist may name it as well.
    var config = try Collector.configuration(arguments: args, environment: env, appGroup: hostGroup)
    if let group = config.appGroup, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
        // Look the container up through containermanagerd instead of only building the path: the lookup
        // checks our signature (team-prefixed App Group) and hands out a sandbox extension for the folder.
        // Writing to the bare path skips that and macOS asks the user "access data from other apps?".
        if !args.contains("--widget-out"), (env["TOKENMACCER_WIDGET_PATH"] ?? "").isEmpty {
            config.widgetPath = url.appendingPathComponent("widget.json").path
        }
    }
    let result = Collector.run(config, leaderboard: leaderboardSync(config))
    if !result.stdout.isEmpty { print(result.stdout) }
    if !result.stderr.isEmpty { FileHandle.standardError.write(Data((result.stderr + "\n").utf8)) }
    if result.exitCode == 0, result.newTurns > 0 || result.stdout.contains("leaderboard: reported"),
        config.appGroup != nil
    {
        // Ask WidgetKit for a fresh timeline right away instead of waiting for the 5-minute refresh.
        // The request goes out over XPC; give it a moment before the process exits.
        WidgetCenter.shared.reloadAllTimelines()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }
    exit(result.exitCode)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
