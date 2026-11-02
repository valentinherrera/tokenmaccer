import Foundation
import TokenMaccerCore

// One collection pass, then exit (the app registers this as a background agent with a 300 s interval).
let args = Array(CommandLine.arguments.dropFirst())
if args.contains("--help") || args.contains("-h") {
    print(Collector.usage)
    exit(0)
}
do {
    let config = try Collector.configuration(arguments: args, environment: ProcessInfo.processInfo.environment)
    let result = Collector.run(config)
    if !result.stdout.isEmpty { print(result.stdout) }
    if !result.stderr.isEmpty { FileHandle.standardError.write(Data((result.stderr + "\n").utf8)) }
    exit(result.exitCode)
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(2)
}
