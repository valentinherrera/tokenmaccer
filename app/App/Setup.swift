import AppKit
import Observation
import ServiceManagement
import SwiftUI
import TokenMaccerCore
import WidgetKit

/// App edition: registers the bundled collector as a background agent (SMAppService, every 300 s) and
/// reports what the user needs to know on one small window. The collector itself takes over a source
/// install's history before its first pass (under its lock, see CollectorConfig.legacyDir).
@MainActor @Observable
final class Setup {
    /// Claude Code config folder; the transcripts are in its `projects/`.
    private(set) var claudeDir: String
    let dataDir: String
    private(set) var transcriptsFound = false
    private(set) var service: SMAppService.Status = .notRegistered
    private(set) var lastUpdate: Date?
    /// What the widget itself reported after its last read (not what the collector wrote).
    private(set) var widget: WidgetStatus = .notSeen
    /// The widget read within the last 30 minutes (onboarding step 2 checks off).
    private(set) var widgetRunning = false
    private(set) var running = false
    private(set) var note: String?

    private let agent: SMAppService?
    private let home: String
    @ObservationIgnored private var started = false
    @ObservationIgnored private var clearOnQuit = false
    /// Set when the user chose "Stop background updates"; the app then does not re-register on launch.
    private let stoppedKey = "backgroundUpdatesStopped"

    init() {
        let env = ProcessInfo.processInfo.environment
        let realHome = WidgetData.realHome ?? NSHomeDirectory()
        home = realHome
        let data = realHome + "/Library/Application Support/TokenMaccer"
        dataDir = data
        // The background agent starts without the user's shell environment: a CLAUDE_CONFIG_DIR the app was
        // started with is saved to settings.json, which the collector reads. Without one nothing is written
        // and both stay at ~/.claude (or at the folder chosen earlier).
        let configured = (env["TOKENMACCER_CLAUDE_DIR"] ?? env["CLAUDE_CONFIG_DIR"]).flatMap { $0.isEmpty ? nil : $0 }
        let saved = AppSettings.load(dataDir: data)
        let expand = { (dir: String) in dir == "~" || dir.hasPrefix("~/") ? realHome + dir.dropFirst() : dir }
        if let configured, expand(configured) != saved.claudeDir {
            try? AppSettings(claudeDir: expand(configured)).save(dataDir: data)
        }
        claudeDir = expand(configured ?? saved.claudeDir ?? "~/.claude")
        let plist = Bundle.main.object(forInfoDictionaryKey: "TMAgentPlist") as? String
        agent = plist.map { SMAppService.agent(plistName: $0) }
    }

    var helperURL: URL? { Bundle.main.url(forAuxiliaryExecutable: "tokenmaccer-collector") }

    /// First appearance of the window: register, collect once (the collector takes over old history first).
    func start() {
        guard !started else { return }
        started = true
        if !UserDefaults.standard.bool(forKey: stoppedKey), agent?.status != .enabled { register() }
        refresh()
        Task { await updateNow() }
    }

    func refresh() {
        var isDir: ObjCBool = false
        transcriptsFound = FileManager.default.fileExists(atPath: claudeDir + "/projects", isDirectory: &isDir)
            && isDir.boolValue
        service = agent?.status ?? .notFound
        lastUpdate = WidgetData.load()?.updatedDate
        widget = WidgetHealth.status(in: Selection.defaults)
        widgetRunning = OnboardingPlan.widgetRunning(in: Selection.defaults)
    }

    func register(openSettings: Bool = true) {
        guard let agent else { return }
        do {
            if agent.status != .enabled { try agent.register() }
            UserDefaults.standard.set(false, forKey: stoppedKey)
        } catch {
            // Registration that needs approval in System Settings also ends up here on some systems.
            if agent.status != .requiresApproval { note = "Background updates could not start: \(error.localizedDescription)" }
        }
        refresh()
        if openSettings, agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    func stop() {
        guard let agent else { return }
        do {
            try agent.unregister()
            UserDefaults.standard.set(true, forKey: stoppedKey)
            note = "Background updates are off. The widget keeps the last numbers."
        } catch {
            note = "Could not stop background updates: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    /// "Choose Folder…": the user points at the Claude Code config folder (or its projects folder). The app is
    /// not sandboxed, so the path alone is enough; it goes to settings.json for the background collector.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: home)
        panel.message = "Choose the Claude Code folder that contains “projects” (usually ~/.claude)."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let dir = AppSettings.claudeDir(fromChosen: url.path)
        do {
            try AppSettings(claudeDir: dir).save(dataDir: dataDir)
            claudeDir = dir
            note = nil
        } catch {
            note = "Could not save the folder: \(error.localizedDescription)"
        }
        refresh()
        Task { await updateNow() }
    }

    /// "Stop Background Updates & Remove Data…": unregisters the agent and deletes what the app edition wrote
    /// (history and settings in Application Support, widget.json and the shared settings in the App Group).
    /// A source install's folder (~/.claude/tools/tokenmaccer) is never touched. Afterwards only the app is left.
    /// The app's own defaults are cleared too, and not written again: a reinstall then starts like a first
    /// install (registers on first open). AppKit saves the window position after willTerminate, so on quit
    /// the app clears its defaults once more and exits there, before that save.
    func removeEverything() {
        let failures = Self.remove(data: true)
        if let first = failures.first, first.hasPrefix("leaderboard:") {
            note = "Nothing removed. " + first.dropFirst("leaderboard: ".count) + "."
            refresh()
            return
        }
        if !clearOnQuit {
            clearOnQuit = true
            _ = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                Setup.clearOwnDefaults()
                exit(0)
            }
        }
        note = failures.isEmpty
            ? "Background updates stopped and data removed. Move TokenMaccer from Applications to the Trash to finish."
            : "Could not remove everything: " + failures.joined(separator: "; ")
        refresh()
    }

    /// Unregisters the background agent and, with `data`, deletes the app edition's files. Returns the failures.
    nonisolated static func remove(data: Bool) -> [String] {
        var failures: [String] = []
        let home = WidgetData.realHome ?? NSHomeDirectory()
        if data {
            // a leaderboard entry must not outlive the data: leave first, and stop if the server says no
            let left = Leaderboard.leaveBeforeRemoval(
                dataDir: home + "/Library/Application Support/TokenMaccer",
                helper: Bundle.main.url(forAuxiliaryExecutable: "tokenmaccer-collector"))
            if !left.ok {
                return ["leaderboard: \(left.error ?? "unknown error"). Leave the leaderboard first, then try again"]
            }
        }
        if let plist = Bundle.main.object(forInfoDictionaryKey: "TMAgentPlist") as? String {
            let agent = SMAppService.agent(plistName: plist)
            do {
                if agent.status != .notRegistered && agent.status != .notFound { try agent.unregister() }
            } catch {
                failures.append("background updates: \(error.localizedDescription)")
            }
        }
        guard data else { return failures }
        let fm = FileManager.default
        var paths = [home + "/Library/Application Support/TokenMaccer"]
        if let appGroup, let container = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            paths.append(container.appendingPathComponent("widget.json").path)
            UserDefaults(suiteName: appGroup)?.removePersistentDomain(forName: appGroup)
            paths.append(container.appendingPathComponent("Library/Preferences/\(appGroup).plist").path)
        }
        for path in paths where fm.fileExists(atPath: path) {
            do { try fm.removeItem(atPath: path) } catch { failures.append("\(path): \(error.localizedDescription)") }
        }
        clearOwnDefaults()
        return failures
    }

    /// Deletes ~/Library/Preferences/<bundle id>.plist through cfprefsd (the "stopped" switch, window positions).
    nonisolated static func clearOwnDefaults() {
        guard let id = Bundle.main.bundleIdentifier else { return }
        UserDefaults.standard.removePersistentDomain(forName: id)
        CFPreferencesAppSynchronize(id as CFString)
        // cfprefsd writes an empty plist a moment later (asynchronously); wait for it (at most 3 s), then
        // remove the file, and only when it really is empty.
        let file = (WidgetData.realHome ?? NSHomeDirectory()) + "/Library/Preferences/\(id).plist"
        for _ in 0..<60 {
            guard FileManager.default.fileExists(atPath: file) else { return }
            if let left = NSDictionary(contentsOfFile: file), left.count == 0 {
                try? FileManager.default.removeItem(atPath: file)
                return
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// `TokenMaccer --unregister [--remove-data]`: the same as the window's buttons, for the removal steps
    /// in the README. Exits.
    nonisolated static func unregisterFromCommandLine(removeData: Bool) -> Never {
        guard Bundle.main.object(forInfoDictionaryKey: "TMAgentPlist") is String else { exit(1) }
        let failures = remove(data: removeData)
        if failures.isEmpty {
            print(removeData ? "background updates and data removed" : "background updates removed")
            exit(0)
        }
        FileHandle.standardError.write(Data(("could not remove: " + failures.joined(separator: "; ") + "\n").utf8))
        exit(1)
    }

    /// Runs the bundled collector once (same binary the background agent runs).
    func updateNow() async {
        guard !running, let helperURL else { return }
        running = true
        var args: [String] = []
        if let appGroup { args += ["--app-group", appGroup] }
        let (status, output) = await Self.run(helperURL, args)
        running = false
        let lines = output.split(separator: "\n").map(String.init)
        if lines.contains(where: { $0.hasPrefix("took over the history") }) {
            note = "Took over the history of your install.sh setup."
        } else if let skipped = lines.first(where: { $0.hasPrefix("history not taken over") }) {
            note = "Previous history not taken over: " + skipped.dropFirst("history not taken over: ".count)
        }
        if status == 0, output.hasPrefix("another collector run is in progress") {
            note = "An update is already running in the background; the numbers follow in a moment."
        } else if status == 0 {
            if note?.hasPrefix("An update is already running") == true { note = nil }
            // last line "<n> new turns · …": reload the widget at once when something new came in
            if let n = Int(lines.last?.split(separator: " ").first ?? ""), n > 0 { WidgetCenter.shared.reloadAllTimelines() }
            if note?.hasPrefix("Update failed") == true { note = nil }
        } else {
            note = "Update failed: " + (output.split(separator: "\n").last.map(String.init) ?? "exit \(status)")
        }
        refresh()
    }

    nonisolated private static func run(_ url: URL, _ args: [String]) async -> (Int32, String) {
        await withCheckedContinuation { cont in
            let p = Process()
            let pipe = Pipe()
            p.executableURL = url
            p.arguments = args
            p.standardOutput = pipe
            p.standardError = pipe
            p.qualityOfService = .utility
            p.terminationHandler = { proc in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: (proc.terminationStatus, text))
            }
            do {
                try p.run()
            } catch {
                cont.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}

/// First-run and status window of the app edition.
struct SetupView: View {
    @State private var setup = AppModels.setup
    @State private var leaderboard = AppModels.leaderboard
    @State private var confirmRemoval = false
    @State private var welcome = Welcome.shared
    @State private var step: OnboardingPlan.Step = .about
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()
    /// Faster while the onboarding waits for the widget, so the step checks off within seconds.
    private let fastTick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if welcome.visible { onboarding } else { status }
        }
        .onAppear { setup.start() }
        .onReceive(tick) { _ in
            setup.refresh()
            leaderboard.refresh()
        }
        .onReceive(fastTick) { _ in
            if welcome.visible && step == .widget && !setup.widgetRunning { setup.refresh() }
        }
    }

    private var onboarding: some View {
        OnboardingView(
            step: $step, transcriptsFound: setup.transcriptsFound,
            transcriptsPath: abbreviate(setup.claudeDir + "/projects"), widgetRunning: setup.widgetRunning,
            join: leaderboard.joinStatus,
            chooseFolder: { setup.chooseFolder() },
            joinAction: { Task { await leaderboard.join(helper: setup.helperURL) { await setup.updateNow() } } },
            rename: { name in Task { await leaderboard.rename(name, helper: setup.helperURL) } },
            finish: {
                welcome.finish()
                step = .about
            })
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TokenMaccer").font(.title2.weight(.semibold))
                    Text(leaderboard.joined
                         ? "Claude Code token usage on your desktop. Only your period totals go to the leaderboard."
                         : "Claude Code token usage on your desktop. Everything stays on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    StatusRow(
                        state: setup.transcriptsFound ? .ok : .problem, title: "Claude Code transcripts",
                        value: setup.transcriptsFound ? "Found" : "Not found",
                        detail: abbreviate(setup.claudeDir + "/projects")
                    ) {
                        if !setup.transcriptsFound { Button("Choose Folder…") { setup.chooseFolder() } }
                    }
                    service
                    StatusRow(
                        state: setup.lastUpdate == nil ? .off : .ok, title: "Last update",
                        value: setup.lastUpdate.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Not yet",
                        detail: nil)
                    widget
                }
                Section {
                    Label {
                        Text("Add the widget: right-click the desktop › Edit Widgets… › TokenMaccer.")
                    } icon: {
                        Image(systemName: "rectangle.3.group")
                    }
                    if let note = setup.note {
                        Text(note).font(.callout).foregroundStyle(.secondary)
                    }
                }
                LeaderboardSection(leaderboard: leaderboard, setup: setup)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Menu("Stop") {
                    if setup.service == .enabled || setup.service == .requiresApproval {
                        Button("Stop Background Updates") { setup.stop() }
                    }
                    Button("Stop Background Updates & Remove Data…") { confirmRemoval = true }
                }
                .fixedSize()
                .confirmationDialog(
                    "Stop background updates and remove TokenMaccer's data?", isPresented: $confirmRemoval
                ) {
                    Button("Remove Data", role: .destructive) { setup.removeEverything() }
                } message: {
                    Text(leaderboard.joined || leaderboard.leavePending
                         ? "Leaves the leaderboard (your profile and totals are deleted from the server) and deletes your token history and the widget's numbers on this Mac. Claude Code's transcripts are not touched. Afterwards move TokenMaccer to the Trash."
                         : "Deletes your token history and the widget's numbers on this Mac. Claude Code's transcripts are not touched. Afterwards move TokenMaccer to the Trash.")
                }
                CheckForUpdatesButton()
                Spacer()
                if setup.running { ProgressView().controlSize(.small) }
                Button("Update now") { Task { await setup.updateNow() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(setup.running || setup.helperURL == nil)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var service: some View {
        switch setup.service {
        case .enabled:
            StatusRow(state: .ok, title: "Background updates", value: "On, every 5 minutes", detail: nil)
        case .requiresApproval:
            StatusRow(state: .problem, title: "Background updates", value: "Needs your approval",
                      detail: "Allow TokenMaccer in System Settings › General › Login Items.") {
                Button("Open Login Items") { setup.openLoginItems() }
            }
        default:
            StatusRow(state: .off, title: "Background updates", value: "Off", detail: nil) {
                Button("Turn On") { setup.register() }
            }
        }
    }

    @ViewBuilder private var widget: some View {
        switch setup.widget {
        case .notSeen:
            StatusRow(state: .off, title: "Widget", value: "Not added yet", detail: nil)
        case .showing(let read):
            StatusRow(state: .ok, title: "Widget", value: "Showing your numbers",
                      detail: "Read at " + read.formatted(date: .omitted, time: .shortened))
        case .idle(let read):
            StatusRow(state: .off, title: "Widget", value: "Not on the desktop",
                      detail: "Last read " + read.formatted(date: .abbreviated, time: .shortened))
        case .failed(.missing, _):
            StatusRow(state: .off, title: "Widget", value: "Waiting for data",
                      detail: "The widget found no numbers yet; they follow after the next update.")
        case .failed(let result, _):
            StatusRow(state: .problem, title: "Widget", value: "Cannot read the data",
                      detail: result == .noContainer
                        ? "macOS did not give the widget access to TokenMaccer's shared folder."
                        : "The widget could not read widget.json.")
        }
    }

    private func abbreviate(_ path: String) -> String {
        guard let home = WidgetData.realHome, path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

struct StatusRow<Accessory: View>: View {
    enum State { case ok, problem, off }
    let state: State
    let title: String
    let value: String
    let detail: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            symbol.frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer()
            Text(value).foregroundStyle(.secondary)
            accessory
        }
    }

    @ViewBuilder private var symbol: some View {
        switch state {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .problem: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .off: Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
        }
    }
}

extension StatusRow where Accessory == EmptyView {
    init(state: State, title: String, value: String, detail: String?) {
        self.init(state: state, title: title, value: value, detail: detail) { EmptyView() }
    }
}
