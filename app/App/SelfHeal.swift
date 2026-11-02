import CoreServices
import Darwin
import Foundation
import OSLog
import WidgetKit

/// App edition: after an update (Sparkle, or the app replaced by hand from the DMG) the first launch of the new
/// build brings the widget over to the new bundle, so the user does not have to remove and re-add it.
/// Steps (see SelfHealPlan for why): register the bundle with LaunchServices, end the widget processes of this
/// bundle (they still run the old code), ask WidgetKit to reload from the app. Measured 02.11.2026 on macOS 26:
/// without ending the old process every reload fails (1050) and chronod pauses the widget for an hour; with
/// these steps the next reload succeeds within a second. chronod itself is never restarted.
@MainActor
enum SelfHeal {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "tokenmaccer", category: "selfheal")
    private static let widgetName = "TokenMaccerWidget"

    static func runAtLaunch() {
        guard Edition.isApp else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let shared = Selection.defaults
        let last = shared.string(forKey: SelfHealPlan.lastBuildKey)
        guard SelfHealPlan.buildChanged(last: last, current: current) else { return }
        // record first: whatever happens below, the next launch of this build does not heal again
        shared.set(current, forKey: SelfHealPlan.lastBuildKey)
        let enabled = SelfHealPlan.isEnabled(defaultsValue: UserDefaults.standard.string(forKey: SelfHealPlan.modeKey))
        log.notice("build changed \(last ?? "none", privacy: .public) -> \(current, privacy: .public), self-heal \(enabled ? "on" : "off", privacy: .public)")
        guard enabled else { return }

        let registered = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        let appName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        let ended = endProcesses { SelfHealPlan.isWidgetProcess(path: $0, appName: appName, widgetName: widgetName) }
        log.notice("LSRegisterURL \(registered, privacy: .public), ended widget processes \(ended, privacy: .public)")

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            WidgetCenter.shared.reloadAllTimelines()
            log.notice("reloadAllTimelines requested")
            // for the log only: does the widget (if it is on the desktop) now run the new build?
            for _ in 0..<20 {
                try? await Task.sleep(for: .seconds(3))
                if shared.string(forKey: SelfHealPlan.widgetBuildKey) == current {
                    log.notice("widget runs build \(current, privacy: .public)")
                    return
                }
            }
            log.notice("widget has not run build \(current, privacy: .public) within 60 s (not on the desktop?)")
        }
    }

    /// Sends SIGTERM to this user's processes whose executable path matches. Returns how many.
    private static func endProcesses(matching: (String) -> Bool) -> Int {
        let uid = getuid()
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return 0 }
        var ended = 0
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != me {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            // Both the current path of the executable and the path it was started from: after Sparkle moved the
            // old bundle away, proc_pidpath can fail (measured 02.11.2026), the start path still names it.
            let paths = [currentPath(pid), launchPath(pid)].compactMap { $0 }
            if paths.contains(where: matching), kill(pid, SIGTERM) == 0 { ended += 1 }
        }
        return ended
    }

    private static func currentPath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Executable path the process was started with (KERN_PROCARGS2: argc, then the path).
    private static func launchPath(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let start = MemoryLayout<Int32>.size
        let end = buffer[start..<size].firstIndex(of: 0) ?? size
        return end > start ? String(decoding: buffer[start..<end], as: UTF8.self) : nil
    }
}
