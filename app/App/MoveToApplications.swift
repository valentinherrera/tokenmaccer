import AppKit
import OSLog

/// App edition: started outside the Applications folder (DMG, Downloads, App Translocation), the app asks to move
/// itself to /Applications before it registers anything (InstallLocationPlan says when). "Move" copies the bundle,
/// replaces an older TokenMaccer there (to the Trash, after ending it if it runs), removes the bundle it started
/// from (or ejects the DMG) and starts again from the copy. "Not Now" keeps it running from where it is, without
/// background updates and without the widget registration, and asks again at the next launch.
@MainActor
enum MoveToApplications {
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "tokenmaccer", category: "move")

    /// Set when the app runs outside the Applications folder after "Not Now" (or a failed move): Setup then does
    /// not register the collector and SelfHeal does not register this bundle with Launch Services.
    private(set) static var runningOutside = false

    /// Runs in `TokenMaccerApp.init`, before SelfHeal and before any window; the question follows right after launch.
    static func checkAtLaunch() {
        let bundle = Bundle.main.bundleURL
        let home = WidgetData.realHome ?? NSHomeDirectory()
        let place = InstallLocationPlan.place(bundlePath: bundle.path, home: home, readOnly: isReadOnly(bundle))
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        guard InstallLocationPlan.shouldOffer(
            place: place, isApp: Edition.isApp,
            enabled: InstallLocationPlan.isEnabled(defaultsValue: UserDefaults.standard.string(forKey: InstallLocationPlan.modeKey)),
            debugBuild: debugBuild)
        else { return }
        log.notice("running outside Applications (\(String(describing: place), privacy: .public)): \(bundle.path, privacy: .public)")
        // set now, so SelfHeal and Setup register nothing while the question is open
        runningOutside = true
        // Asked once the app has finished launching. An alert run from App.init (before NSApplication.run) is
        // modal but never drawn: measured 02.11.2026, it was invisible yet took the keyboard, and a Return typed
        // into another app chose "Move". The main queue first runs after launch, when windows are drawn.
        DispatchQueue.main.async { offer(bundle) }
    }

    private static func offer(_ bundle: URL) {
        NSApp.activate()
        guard ask() else {
            log.notice("move declined")
            return
        }
        do {
            try move(from: bundle)
        } catch {
            log.error("move failed: \(error.localizedDescription, privacy: .public)")
            fail(error)
        }
    }

    private static func ask() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Move TokenMaccer to the Applications folder?")
        alert.informativeText = String(localized: "TokenMaccer is running from outside the Applications folder. The widget and the background updates only work from there. TokenMaccer copies itself to Applications, replaces an older version there and starts again.")
        alert.addButton(withTitle: String(localized: "Move to Applications"))
        alert.addButton(withTitle: String(localized: "Not Now")).keyEquivalent = "\u{1b}"  // Esc
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func fail(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "TokenMaccer could not move itself")
        alert.informativeText = String(localized: "Drag TokenMaccer into the Applications folder in Finder and open it from there. (\(error.localizedDescription))")
        alert.runModal()
    }

    private struct MoveError: LocalizedError {
        let errorDescription: String?
    }

    private static func move(from bundle: URL) throws {
        let fm = FileManager.default
        let destination = URL(fileURLWithPath: InstallLocationPlan.destination(bundleName: bundle.lastPathComponent))
        let original = originalURL(of: bundle)

        // an older TokenMaccer in /Applications: end it if it runs, then to the Trash (it can be restored from there)
        if fm.fileExists(atPath: destination.path) {
            endRunning(at: destination)
            var trashed: NSURL?
            try fm.trashItem(at: destination, resultingItemURL: &trashed)
            log.notice("old copy moved to the Trash: \(trashed?.path ?? "?", privacy: .public)")
        }
        // ditto keeps the code signature, extended attributes and symlinks of the bundle
        let (status, output) = run("/usr/bin/ditto", [bundle.path, destination.path])
        guard status == 0 else {
            try? fm.removeItem(at: destination)
            throw MoveError(errorDescription: output.isEmpty ? "ditto \(status)" : output)
        }
        // the user already opened this app once, Gatekeeper checked it then; without the quarantine flag the copy
        // starts from Applications without being translocated again
        _ = run("/usr/bin/xattr", ["-d", "-r", "com.apple.quarantine", destination.path])
        log.notice("copied to \(destination.path, privacy: .public)")

        var cleanup = ""
        if let image = InstallLocationPlan.diskImageToEject(path: original.path, imageMountPoints: diskImageMountPoints()) {
            cleanup = "/usr/bin/hdiutil detach -quiet \(quoted(image)) || true"
        } else if InstallLocationPlan.trashOriginal(
            originalPath: original.path, originalReadOnly: isReadOnly(original), destination: destination.path) {
            var trashed: NSURL?
            do {
                try fm.trashItem(at: original, resultingItemURL: &trashed)
                log.notice("started copy moved to the Trash: \(original.path, privacy: .public)")
            } catch {
                log.error("could not trash \(original.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        relaunch(destination, cleanup: cleanup)
    }

    /// Starts the copy once this process has ended (so two instances never run), then ejects the DMG if there is one.
    private static func relaunch(_ app: URL, cleanup: String) -> Never {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \(quoted(app.path)); \(cleanup)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            log.error("relaunch failed: \(error.localizedDescription, privacy: .public)")
            NSWorkspace.shared.open(app)
        }
        log.notice("relaunching from \(app.path, privacy: .public)")
        exit(0)
    }

    private static func endRunning(at url: URL) {
        let target = url.standardizedFileURL.path
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleURL?.standardizedFileURL.path == target && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        for app in running { app.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for app in running where !app.isTerminated { app.forceTerminate() }
    }

    private static func isReadOnly(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
    }

    /// The bundle before App Translocation (Security's SecTranslocateCreateOriginalPathForURL, looked up at run
    /// time as LetsMove and Sparkle do); the bundle itself when it is not translocated or the lookup fails.
    private static func originalURL(of url: URL) -> URL {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return url }
        defer { dlclose(handle) }
        guard let isSym = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return url }
        var translocated = false
        guard unsafeBitCast(isSym, to: IsTranslocated.self)(url as CFURL, &translocated, nil), translocated,
              let original = unsafeBitCast(origSym, to: OriginalPath.self)(url as CFURL, nil)?.takeRetainedValue()
        else { return url }
        return original as URL
    }

    /// Mount points of the mounted disk images (hdiutil info -plist).
    private static func diskImageMountPoints() -> [String] {
        let (status, output) = run("/usr/bin/hdiutil", ["info", "-plist"])
        guard status == 0, let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.flatMap { ($0["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String } }
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

    private static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
