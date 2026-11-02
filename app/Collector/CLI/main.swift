import Foundation
import TokenMaccerCore
import WidgetKit

// One collection pass, then exit (the app registers this as a background agent with a 300 s interval).
// No long-lived process: every run starts with the current time zone and price table.
let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") {
    print(Collector.usage)
    exit(0)
}
do {
    // The background agent passes --app-group; a host app's Info.plist may name it as well.
    let hostGroup = Bundle.main.object(forInfoDictionaryKey: "TMAppGroup") as? String
    let env = ProcessInfo.processInfo.environment
    var config = try Collector.configuration(arguments: args, environment: env, appGroup: hostGroup)
    if let group = config.appGroup, let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) {
        // Look the container up through containermanagerd instead of only building the path: the lookup
        // checks our signature (team-prefixed App Group) and hands out a sandbox extension for the folder.
        // Writing to the bare path skips that and macOS asks the user "access data from other apps?".
        if !args.contains("--widget-out"), (env["TOKENMACCER_WIDGET_PATH"] ?? "").isEmpty {
            config.widgetPath = url.appendingPathComponent("widget.json").path
        }
    }
    let result = Collector.run(config)
    if !result.stdout.isEmpty { print(result.stdout) }
    if !result.stderr.isEmpty { FileHandle.standardError.write(Data((result.stderr + "\n").utf8)) }
    if result.exitCode == 0, result.newTurns > 0, config.appGroup != nil {
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
