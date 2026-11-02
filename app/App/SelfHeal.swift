import CoreServices
import Darwin
import Foundation
import OSLog
import WidgetKit

/// App edition: after an update (Sparkle, or the app replaced by hand from the DMG) the first launch of the new
/// build brings the widget over to the new bundle, so the user does not have to remove and re-add it.
/// Steps (see SelfHealPlan for why): register the bundle with LaunchServices, end the widget processes of this
/// bundle (they still run the old code), ask WidgetKit to reload. Only if the widget was on the desktop and still
/// has not run from the new build a minute later, chronod (the user's own widget daemon) is restarted.
@MainActor
enum SelfHeal {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "tokenmaccer", category: "selfheal")
    private static let widgetName = "TokenMaccerWidget"
    private static let wait: Duration = .seconds(60)

    static func runAtLaunch() {
        guard Edition.isApp else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let shared = Selection.defaults
        let last = shared.string(forKey: SelfHealPlan.lastBuildKey)
        guard SelfHealPlan.buildChanged(last: last, current: current) else { return }
        // record first: whatever happens below, the next launch of this build does not heal again
        shared.set(current, forKey: SelfHealPlan.lastBuildKey)
        let mode = SelfHealPlan.Mode(defaultsValue: UserDefaults.standard.string(forKey: SelfHealPlan.modeKey))
        log.notice("build changed \(last ?? "none", privacy: .public) -> \(current, privacy: .public), mode \(mode.rawValue, privacy: .public)")
        guard mode != .off else { return }

        let widgetWasActive: Bool
        if case .showing = WidgetHealth.status(in: shared) { widgetWasActive = true } else { widgetWasActive = false }

        let registered = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        let appName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        let ended = endProcesses { SelfHealPlan.isWidgetProcess(path: $0, appName: appName, widgetName: widgetName) }
        log.notice("LSRegisterURL \(registered, privacy: .public), ended widget processes \(ended, privacy: .public)")

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            WidgetCenter.shared.reloadAllTimelines()
            log.notice("reloadAllTimelines requested")
            guard mode == .full, widgetWasActive else { return }
            let deadline = ContinuousClock.now + wait
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .seconds(3))
                if shared.string(forKey: SelfHealPlan.widgetBuildKey) == current {
                    log.notice("widget runs build \(current, privacy: .public)")
                    return
                }
            }
            let seen = shared.string(forKey: SelfHealPlan.widgetBuildKey)
            guard SelfHealPlan.needsChronodRestart(
                mode: mode, widgetWasActive: widgetWasActive, widgetBuildAfterWait: seen, current: current
            ) else { return }
            let restarted = endProcesses { $0 == "/System/Library/PrivateFrameworks/ChronoServices.framework/Support/chronod" }
            log.notice("widget still on build \(seen ?? "none", privacy: .public); restarted chronod: \(restarted, privacy: .public)")
            try? await Task.sleep(for: .seconds(2))
            WidgetCenter.shared.reloadAllTimelines()
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
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != me {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }
            let path = String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if matching(path), kill(pid, SIGTERM) == 0 { ended += 1 }
        }
        return ended
    }
}
