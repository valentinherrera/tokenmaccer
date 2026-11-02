import Foundation
import TokenMaccerCore
import WidgetKit

// One collection pass, then exit (the app registers this as a background agent with a 300 s interval).
// No long-lived process: every run starts with the current time zone and price table.
//
// `tokenmaccer-collector leaderboard join|rename|leave [--display-name NAME] [--sign-in] [--data-dir P] [--app-group G]`
// is the app's way into the opt-in leaderboard: join reads {"code": …, "verifier": …} from stdin (the result of the
// GitHub sign-in; without --display-name the server takes the GitHub username), rename changes the display name
// of a joined account, all print one JSON line {"ok": true|false, …}. The sign-in tokens stay in this
// program's keychain item. `leaderboard group create|join|leave|rename|renew|remove-member|delete|refresh [--name N]
// [--code C] [--group ID] [--member ID]` changes a group (or only fetches the groups again) and prints
// {"ok": …, "group": {…}, "error": …, "error_kind": …}. `leaderboard endpoint` prints the server this build would use and whether it
// honours overrides (Debug only); it sends nothing (scripts/check_release_endpoint.sh).
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

/// The background agent writes widget.json into the App Group container. Look the container up through
/// containermanagerd instead of only building the path: the lookup checks our signature (team-prefixed App Group)
/// and hands out a sandbox extension for the folder. Writing to the bare path skips that and macOS asks the user
/// "access data from other apps?".
func useContainer(_ config: inout CollectorConfig) {
    guard let group = config.appGroup, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
        !args.contains("--widget-out"), (env["TOKENMACCER_WIDGET_PATH"] ?? "").isEmpty
    else { return }
    config.widgetPath = url.appendingPathComponent("widget.json").path
}

/// Ask WidgetKit for a fresh timeline right away instead of waiting for the 5-minute refresh. The request goes
/// out over XPC; give it a moment before the process exits.
func reloadWidgets() {
    WidgetCenter.shared.reloadAllTimelines()
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
}

if args.first == "leaderboard" {
    var rest = Array(args.dropFirst())
    let action = rest.isEmpty ? "" : rest.removeFirst()
    var displayName: String?
    if let i = rest.firstIndex(of: "--display-name"), i + 1 < rest.count {
        displayName = rest[i + 1]
        rest.removeSubrange(i...(i + 1))
    }
    // group options: --name, --code, --group, --member (each with a value)
    var option: [String: String] = [:]
    for key in ["--name", "--code", "--group", "--member"] {
        if let i = rest.firstIndex(of: key), i + 1 < rest.count {
            option[key] = rest[i + 1]
            rest.removeSubrange(i...(i + 1))
        }
    }
    let groupVerb = action == "group" && !rest.isEmpty && !rest[0].hasPrefix("-") ? rest.removeFirst() : ""
    let wantsSignIn = rest.contains("--sign-in")
    rest.removeAll { $0 == "--sign-in" }
    var config: CollectorConfig
    do {
        config = try Collector.configuration(arguments: rest, environment: env, appGroup: hostGroup)
    } catch {
        reply(["ok": false, "error": "\(error)"])
    }
    useContainer(&config)
    // join, rename, leave and group actions change what the leaderboard widget may show (Leave removes its copy of the boards)
    func done(_ obj: [String: Any]) -> Never {
        if config.appGroup != nil, LeaderboardWidgetFile.sync(dataDir: config.dataDir, widgetPath: config.widgetPath) {
            reloadWidgets()
        }
        reply(obj)
    }
    // the same lock as a collection pass: a running pass finishes its report first
    try? FileManager.default.createDirectory(atPath: config.dataDir, withIntermediateDirectories: true)
    let lock = open(config.dataDir + "/.lock", O_WRONLY | O_CREAT, 0o644)
    if lock >= 0 { flock(lock, LOCK_EX) }
    let sync = leaderboardSync(config)
    switch action {
    case "endpoint":
        reply(["ok": true, "url": sync.endpoint?.url.absoluteString ?? "",
               "overrides_allowed": LeaderboardEndpoint.overridesAllowed])
    case "join":
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: String],
            let code = obj["code"], let verifier = obj["verifier"]
        else { reply(["ok": false, "error": "expected {\"code\": …, \"verifier\": …} on stdin"]) }
        do {
            let state = try sync.join(code: code, verifier: verifier, displayName: displayName)
            done(["ok": true, "display_name": state.displayName ?? "", "github_login": state.githubLogin ?? ""])
        } catch {
            done(["ok": false, "error": "\(error)"])
        }
    case "rename":
        guard let displayName else { reply(["ok": false, "error": "rename needs --display-name NAME"]) }
        do {
            let state = try sync.rename(displayName: displayName)
            done(["ok": true, "display_name": state.displayName ?? "", "github_login": state.githubLogin ?? ""])
        } catch {
            done(["ok": false, "error": "\(error)"])
        }
    case "leave":
        // --sign-in: a fresh GitHub sign-in ({"code": …, "verifier": …} on stdin) for a lost or dead one
        var signIn: (code: String, verifier: String)?
        if wantsSignIn {
            let input = FileHandle.standardInput.readDataToEndOfFile()
            guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: String],
                let code = obj["code"], let verifier = obj["verifier"]
            else { reply(["ok": false, "error": "expected {\"code\": …, \"verifier\": …} on stdin"]) }
            signIn = (code, verifier)
        }
        do {
            try sync.leave(signIn: signIn)
            done(["ok": true])
        } catch {
            done(["ok": false, "error": "\(error)"])
        }
    case "group":
        let g = option["--group"] ?? ""
        let groupAction: GroupAction?
        switch groupVerb {
        case "create": groupAction = option["--name"].map { .create(name: $0) }
        case "join": groupAction = option["--code"].map { .join(code: $0) }
        case "leave": groupAction = g.isEmpty ? nil : .leave(group: g)
        case "rename": groupAction = g.isEmpty ? nil : option["--name"].map { .rename(group: g, name: $0) }
        case "renew": groupAction = g.isEmpty ? nil : .renew(group: g)
        case "remove-member": groupAction = g.isEmpty ? nil : option["--member"].map { .removeMember(group: g, member: $0) }
        case "delete": groupAction = g.isEmpty ? nil : .delete(group: g)
        case "refresh": groupAction = .refresh
        default: groupAction = nil
        }
        guard let groupAction else {
            reply(["ok": false, "error": "usage: leaderboard group create --name N | join --code C | leave|renew|delete --group ID"
                   + " | rename --group ID --name N | remove-member --group ID --member ID | refresh"])
        }
        do {
            var answer: [String: Any] = ["ok": true]
            if let group = try sync.group(groupAction) { answer["group"] = group.json }
            done(answer)
        } catch {
            var answer: [String: Any] = ["ok": false, "error": "\(error)"]
            if let e = error as? GroupError {
                answer["error_kind"] = e.kind
            } else if let kind = (error as? LeaderboardError)?.kind {
                answer["error_kind"] = kind
            }
            done(answer)
        }
    default:
        reply(["ok": false, "error": "usage: leaderboard join|rename|leave|group|endpoint [--display-name NAME]"])
    }
}

do {
    // The background agent passes --app-group; a host app's Info.plist may name it as well.
    var config = try Collector.configuration(arguments: args, environment: env, appGroup: hostGroup)
    useContainer(&config)
    let result = Collector.run(config, leaderboard: leaderboardSync(config))
    if !result.stdout.isEmpty { print(result.stdout) }
    if !result.stderr.isEmpty { FileHandle.standardError.write(Data((result.stderr + "\n").utf8)) }
    if result.exitCode == 0, config.appGroup != nil,
        result.newTurns > 0 || result.stdout.contains("leaderboard: reported")
            || result.stdout.contains(LeaderboardWidgetFile.updatedLog)
    {
        reloadWidgets()
    }
    exit(result.exitCode)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
