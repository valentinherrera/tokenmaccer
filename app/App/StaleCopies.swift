import CoreServices
import Foundation
import OSLog
import WidgetKit

/// App edition: at every launch from an Applications folder, unregister the other TokenMaccer copies Launch
/// Services still knows (Trash, DMG, App Translocation, build folders), register the running one again and ask
/// WidgetKit to reload. Why and what exactly: StaleCopiesPlan. Runs in the background (the dump takes about two
/// seconds), changes only Launch Services' registration and never touches a file.
enum StaleCopies {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "tokenmaccer", category: "stalecopies")

    @MainActor
    static func runAtLaunch() {
        guard Edition.isApp, !MoveToApplications.runningOutside,
              StaleCopiesPlan.isEnabled(defaultsValue: UserDefaults.standard.string(forKey: StaleCopiesPlan.modeKey)),
              let identifier = Bundle.main.bundleIdentifier
        else { return }
        let bundle = Bundle.main.bundleURL
        let home = WidgetData.realHome ?? NSHomeDirectory()
        let inApplications = InstallLocationPlan.place(bundlePath: bundle.path, home: home, readOnly: false) == .applications
        Task.detached(priority: .utility) {
            let removed = clean(identifier: identifier, running: bundle, inApplications: inApplications)
            guard removed > 0 else { return }
            await MainActor.run {
                WidgetCenter.shared.reloadAllTimelines()
                log.notice("reloadAllTimelines requested after unregistering \(removed, privacy: .public) copies")
            }
        }
    }

    /// Unregisters the other copies and registers the running one again. Returns how many copies were unregistered.
    private static func clean(identifier: String, running: URL, inApplications: Bool) -> Int {
        let (status, dump) = run(StaleCopiesPlan.lsregister, ["-dump"])
        guard status == 0 else {
            log.error("lsregister -dump failed (\(status, privacy: .public))")
            return 0
        }
        let registered = StaleCopiesPlan.registeredPaths(dump: dump, bundleIdentifier: identifier)
        let stale = StaleCopiesPlan.toUnregister(registered: registered, running: running.path,
                                                 runningInApplications: inApplications)
        guard !stale.isEmpty else {
            log.notice("registered copies: \(registered.count, privacy: .public), none to unregister")
            return 0
        }
        var removed = 0
        for path in stale {
            let (code, output) = run(StaleCopiesPlan.lsregister, ["-u", path])
            if code == 0 { removed += 1 }
            log.notice("unregistered \(path, privacy: .public): \(code, privacy: .public) \(output, privacy: .public)")
        }
        let registeredAgain = LSRegisterURL(running as CFURL, true)
        log.notice("unregistered \(removed, privacy: .public) of \(stale.count, privacy: .public) other copies, LSRegisterURL \(registeredAgain, privacy: .public)")
        return removed
    }

    private static func run(_ tool: String, _ args: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
