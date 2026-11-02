import CoreServices
import Darwin
import Foundation
import OSLog
import Security
import WidgetKit

/// App edition: after an update (Sparkle, or the app replaced by hand from the DMG) a launch of the app brings
/// the widget over to the new bundle, so the user does not have to remove and re-add it.
/// Steps (see SelfHealPlan for when and why): register the bundle with LaunchServices, end the stale widget
/// processes of this app (they still run the old code), ask WidgetKit to reload from the app, then wait for the
/// widget to report the new build; without that report the steps are repeated twice and the next launch tries
/// again. Measured 02.11.2026 on macOS 26: without ending the old process every reload fails (1050) and chronod
/// pauses the widget for an hour; with these steps the next reload succeeds within a second. chronod itself is
/// never restarted.
@MainActor
enum SelfHeal {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "tokenmaccer", category: "selfheal")
    private static let widgetName = "TokenMaccerWidget"

    static func runAtLaunch() {
        guard Edition.isApp else { return }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let shared = Selection.defaults
        let last = shared.string(forKey: SelfHealPlan.lastBuildKey)
        if SelfHealPlan.buildChanged(last: last, current: current) {
            log.notice("build changed \(last ?? "none", privacy: .public) -> \(current, privacy: .public)")
            shared.set(current, forKey: SelfHealPlan.lastBuildKey)
        }
        guard SelfHealPlan.isEnabled(defaultsValue: UserDefaults.standard.string(forKey: SelfHealPlan.modeKey)) else {
            log.notice("self-heal off (TMSelfHeal)")
            return
        }
        let confirmed = shared.string(forKey: SelfHealPlan.confirmedBuildKey)
        let stale = staleWidgetProcesses()
        guard SelfHealPlan.needsHeal(confirmedBuild: confirmed, current: current, staleProcesses: stale.count) else {
            return
        }
        log.notice("self-heal: confirmed build \(confirmed ?? "none", privacy: .public), current \(current, privacy: .public), stale widget processes \(stale.count, privacy: .public)")

        let started = Date()
        let registered = LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
        let ended = end(stale)
        log.notice("LSRegisterURL \(registered, privacy: .public), ended widget processes \(ended, privacy: .public)")

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            WidgetCenter.shared.reloadAllTimelines()
            log.notice("reloadAllTimelines requested")
            for second in stride(from: 2, through: SelfHealPlan.confirmWindow, by: 2) {
                try? await Task.sleep(for: .seconds(2))
                if confirmedByWidget(current: current, since: started) {
                    shared.set(current, forKey: SelfHealPlan.confirmedBuildKey)
                    log.notice("widget runs build \(current, privacy: .public) after \(second, privacy: .public) s, self-heal confirmed")
                    return
                }
                if SelfHealPlan.retryAt.contains(second) {
                    let again = end(staleWidgetProcesses())
                    WidgetCenter.shared.reloadAllTimelines()
                    log.notice("retry after \(second, privacy: .public) s: ended widget processes \(again, privacy: .public), reloadAllTimelines requested")
                }
            }
            log.notice("widget has not reported build \(current, privacy: .public) within \(SelfHealPlan.confirmWindow, privacy: .public) s (not on the desktop?); next launch tries again")
        }
    }

    private static func confirmedByWidget(current: String, since started: Date) -> Bool {
        let shared = Selection.defaults
        let reportedAt = shared.object(forKey: WidgetHealth.lastAttemptKey) == nil
            ? nil : Date(timeIntervalSince1970: shared.double(forKey: WidgetHealth.lastAttemptKey))
        return SelfHealPlan.widgetConfirms(widgetBuild: shared.string(forKey: SelfHealPlan.widgetBuildKey),
                                           reportedAt: reportedAt, current: current, healStarted: started)
    }

    /// Path of the widget executable inside the running bundle.
    private static var installedWidgetPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/\(widgetName).appex/Contents/MacOS/\(widgetName)")
            .path
    }

    /// This user's widget processes of this app that do not run the installed widget executable.
    private static func staleWidgetProcesses() -> [pid_t] {
        let installed = installedWidgetPath
        let appName = Bundle.main.bundleURL.deletingPathExtension().lastPathComponent
        var changedAt: Date?
        var st = stat()
        if stat(installed, &st) == 0 {
            changedAt = Date(timeIntervalSince1970: TimeInterval(st.st_ctimespec.tv_sec)
                             + TimeInterval(st.st_ctimespec.tv_nsec) / 1_000_000_000)
        }
        let mine = signature(getpid())
        let widgetIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".widget"
        let uid = getuid()
        let me = getpid()
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var stale: [pid_t] = []
        for pid in pids.prefix(Int(count)) where pid > 0 && pid != me {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { continue }
            // Both the current path of the executable and the path it was started from: after Sparkle moved the
            // old bundle away, proc_pidpath can fail (measured 02.11.2026), the start path still names it.
            let current = currentPath(pid)
            let launch = launchPath(pid)
            let paths = [current, launch].compactMap { $0 }
            // cheap filter first (executable name), then the code signature decides
            guard paths.contains(where: { ($0 as NSString).lastPathComponent == widgetName }),
                SelfHealPlan.isOwnWidget(signature: signature(pid), paths: paths, widgetIdentifier: widgetIdentifier,
                                         team: mine?.team, appName: appName, widgetName: widgetName)
            else { continue }
            let startedAt = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
                                 + TimeInterval(info.pbi_start_tvusec) / 1_000_000)
            if SelfHealPlan.isStale(currentPath: current, launchPath: launch, installed: installed,
                                    startedAt: startedAt, installedChangedAt: changedAt) {
                stale.append(pid)
            }
        }
        return stale
    }

    /// Sends SIGTERM to the given processes. Returns how many received it.
    private static func end(_ pids: [pid_t]) -> Int {
        pids.filter { kill($0, SIGTERM) == 0 }.count
    }

    /// Identifier and team of a running process's code signature; nil when it cannot be read (for example when
    /// its executable was deleted).
    private static func signature(_ pid: pid_t) -> SelfHealPlan.Signature? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess,
            let code
        else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
            == errSecSuccess, let dict = info as? [String: Any]
        else { return nil }
        return SelfHealPlan.Signature(identifier: dict[kSecCodeInfoIdentifier as String] as? String,
                                      team: dict[kSecCodeInfoTeamIdentifier as String] as? String)
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
