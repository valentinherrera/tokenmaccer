import AppKit
import Observation
import ServiceManagement
import SwiftUI
import TokenMaccerCore
import WidgetKit

/// App edition: takes over a source install's history, registers the bundled collector as a background
/// agent (SMAppService, every 300 s) and reports what the user needs to know on one small window.
@MainActor @Observable
final class Setup {
    let claudeDir: String
    let dataDir: String
    private(set) var transcriptsFound = false
    private(set) var service: SMAppService.Status = .notRegistered
    private(set) var lastUpdate: Date?
    private(set) var running = false
    private(set) var note: String?

    private let agent: SMAppService?
    private let home: String
    @ObservationIgnored private var started = false
    /// Set when the user chose "Stop background updates"; the app then does not re-register on launch.
    private let stoppedKey = "backgroundUpdatesStopped"

    init() {
        let env = ProcessInfo.processInfo.environment
        home = WidgetData.realHome ?? NSHomeDirectory()
        let configured = env["TOKENMACCER_CLAUDE_DIR"] ?? env["CLAUDE_CONFIG_DIR"]
        let dir = configured.flatMap { $0.isEmpty ? nil : $0 } ?? "~/.claude"
        claudeDir = dir == "~" || dir.hasPrefix("~/") ? home + dir.dropFirst() : dir
        dataDir = home + "/Library/Application Support/TokenMaccer"
        let plist = Bundle.main.object(forInfoDictionaryKey: "TMAgentPlist") as? String
        agent = plist.map { SMAppService.agent(plistName: $0) }
    }

    var helperURL: URL? { Bundle.main.url(forAuxiliaryExecutable: "tokenmaccer-collector") }

    /// First appearance of the window: migrate, register, collect once.
    func start() {
        guard !started else { return }
        started = true
        switch LegacyMigration.run(legacyDir: LegacyMigration.legacyDataDir(home: home), dataDir: dataDir) {
        case .notNeeded: break
        case .copied(let n): note = "Took over the history of your install.sh setup (\(n) backups)."
        case .skipped(let why): note = "Previous history not taken over: \(why)"
        }
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

    /// `TokenMaccer --unregister`: removes the background agent and exits (used by the removal steps).
    nonisolated static func unregisterFromCommandLine() -> Never {
        guard let plist = Bundle.main.object(forInfoDictionaryKey: "TMAgentPlist") as? String else { exit(1) }
        let agent = SMAppService.agent(plistName: plist)
        do {
            if agent.status != .notRegistered && agent.status != .notFound { try agent.unregister() }
            print("background updates removed")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("could not remove background updates: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Runs the bundled collector once (same binary the background agent runs).
    func updateNow() async {
        guard !running, let helperURL else { return }
        running = true
        var args: [String] = []
        if let appGroup { args += ["--app-group", appGroup] }
        let (status, output) = await Self.run(helperURL, args)
        running = false
        if status == 0, output.hasPrefix("another collector run is in progress") {
            note = "An update is already running in the background; the numbers follow in a moment."
        } else if status == 0 {
            if note?.hasPrefix("An update is already running") == true { note = nil }
            // "<n> new turns · …": reload the widget at once when something new came in
            if let n = Int(output.split(separator: " ").first ?? ""), n > 0 { WidgetCenter.shared.reloadAllTimelines() }
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
    @State private var setup = Setup()
    private let tick = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("TokenMaccer").font(.title2.weight(.semibold))
                    Text("Claude Code token usage on your desktop. Everything stays on this Mac.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section {
                    StatusRow(
                        state: setup.transcriptsFound ? .ok : .problem, title: "Claude Code transcripts",
                        value: setup.transcriptsFound ? "Found" : "Not found",
                        detail: abbreviate(setup.claudeDir + "/projects"))
                    service
                    StatusRow(
                        state: setup.lastUpdate == nil ? .off : .ok, title: "Last update",
                        value: setup.lastUpdate.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Not yet",
                        detail: nil)
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
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                if setup.service == .enabled || setup.service == .requiresApproval {
                    Button("Stop background updates") { setup.stop() }
                }
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
        .onAppear { setup.start() }
        .onReceive(tick) { _ in setup.refresh() }
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
