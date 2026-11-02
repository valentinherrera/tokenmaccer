import AppKit
import AuthenticationServices
import Observation
import SwiftUI
import TokenMaccerCore

/// The window's side of the opt-in leaderboard. The app signs in with GitHub (ASWebAuthenticationSession,
/// PKCE) and hands the authorization code to the bundled collector, which exchanges it, keeps the tokens in
/// its keychain item, joins and from then on reports at most every 30 minutes. The app itself sends nothing
/// to the server; it reads the collector's leaderboard.json for the status.
@MainActor @Observable
final class Leaderboard {
    private(set) var state: LeaderboardState?
    private(set) var busy = false
    private(set) var renaming = false
    var error: String?

    @ObservationIgnored private let dataDir: String
    @ObservationIgnored private var auth: ASWebAuthenticationSession?
    @ObservationIgnored private let anchor = AuthAnchor()

    init(dataDir: String) {
        self.dataDir = dataDir
        refresh()
    }

    var joined: Bool { state?.joined == true }
    var leavePending: Bool { state?.leavePending == true }
    var needsSignIn: Bool { state?.needsSignIn == true }

    func refresh() { state = LeaderboardState.load(dataDir: dataDir) }

    /// The same server the collector uses: app-config.json; Debug builds also take overrides (tests).
    var endpoint: LeaderboardEndpoint? {
        LeaderboardEndpoint.resolve(
            environment: ProcessInfo.processInfo.environment,
            defaults: appGroup.flatMap { UserDefaults(suiteName: $0) },
            bundled: Bundle.main.url(forResource: "app-config", withExtension: "json").flatMap { try? Data(contentsOf: $0) })
    }

    /// Sign in with GitHub, then let the collector join; `afterJoin` runs a collection pass (first report).
    /// Without a display name the server takes the GitHub username (changed afterwards with `rename`).
    func join(displayName: String? = nil, helper: URL?, afterJoin: @escaping () async -> Void) async {
        guard !busy else { return }
        guard let helper else { error = String(localized: "The background collector is missing from TokenMaccer.app."); return }
        guard let endpoint else { error = LeaderboardError.noServer.description; return }
        error = nil
        busy = true
        defer { busy = false }
        guard let input = await gitHubSignIn(endpoint) else { return }
        let answer = await Self.helper(
            helper, ["leaderboard", "join"] + (displayName.map { ["--display-name", $0] } ?? []), stdin: input)
        refresh()
        if answer.ok {
            await afterJoin()
            refresh()
        } else {
            error = String(localized: "Could not join: \(answer.error ?? String(localized: "unknown error"))")
        }
    }

    /// Changes the display name on the server (the collector's sign-in; no GitHub window).
    func rename(_ displayName: String, helper: URL?) async {
        guard !renaming, let helper else { return }
        error = nil
        renaming = true
        defer { renaming = false }
        let answer = await Self.helper(helper, ["leaderboard", "rename", "--display-name", displayName], stdin: nil)
        refresh()
        if !answer.ok { error = String(localized: "Could not change the name: \(answer.error ?? String(localized: "unknown error"))") }
    }

    /// What the join panel shows (onboarding step 3 and the Join sheet), for the widget's period and unit.
    var joinStatus: JoinStatus {
        var s = JoinStatus()
        s.phase = busy ? .busy : joined ? .joined : .idle
        s.error = error
        s.displayName = state?.displayName
        s.githubLogin = state?.githubLogin
        s.period = Selection.period
        s.usd = Selection.unit == .usd
        if let place = state?.place(period: s.period, unit: Selection.unit.rawValue) {
            s.rank = place.rank
            s.participants = place.participants
        }
        s.renaming = renaming
        return s
    }

    /// The GitHub sign-in as stdin for the collector ({"code", "verifier"}); nil when cancelled or failed
    /// (then `error` says why, except for a cancel).
    private func gitHubSignIn(_ endpoint: LeaderboardEndpoint) async -> Data? {
        let verifier = PKCE.verifier()
        let callback: URL
        do {
            callback = try await signIn(endpoint.authorizeURL(challenge: PKCE.challenge(for: verifier)))
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            return nil  // the user closed the sign-in window
        } catch {
            self.error = String(localized: "GitHub sign-in failed: \(error.localizedDescription)")
            return nil
        }
        switch LeaderboardEndpoint.code(fromCallback: callback) {
        case .success(let code):
            return (try? JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier])) ?? Data()
        case .failure(let e):
            error = String(localized: "GitHub sign-in failed: \(String(describing: e))")
            return nil
        }
    }

    /// Leave; with `signIn` a fresh GitHub sign-in first (the collector's sign-in is lost or expired).
    func leave(helper: URL?, signIn: Bool = false) async {
        guard !busy, let helper else { return }
        error = nil
        busy = true
        defer { busy = false }
        var stdin: Data?
        if signIn {
            guard let endpoint else { error = LeaderboardError.noServer.description; return }
            guard let input = await gitHubSignIn(endpoint) else { return }
            stdin = input
        }
        let answer = await Self.helper(helper, ["leaderboard", "leave"] + (signIn ? ["--sign-in"] : []), stdin: stdin)
        refresh()
        if !answer.ok {
            error = answer.error.map { String(localized: "Could not leave: \($0)") } ?? String(localized: "Could not leave.")
        }
    }

    /// Synchronous leave for "Remove Data" and `--unregister --remove-data`: true when nothing is left on the
    /// server (or the user never joined). At most 30 s.
    nonisolated static func leaveBeforeRemoval(dataDir: String, helper: URL?) -> (ok: Bool, error: String?) {
        guard let state = LeaderboardState.load(dataDir: dataDir), state.joined || state.leavePending else {
            return (true, nil)
        }
        guard let helper else { return (false, String(localized: "the background collector is missing")) }
        let p = Process()
        let out = Pipe()
        p.executableURL = helper
        p.arguments = ["leaderboard", "leave"] + (appGroup.map { ["--app-group", $0] } ?? [])
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (false, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(30)
        while p.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            return (false, String(localized: "the leaderboard server did not answer"))
        }
        let answer = parse(out.fileHandleForReading.readDataToEndOfFile())
        return answer.ok ? (true, nil) : (false, answer.error ?? String(localized: "unknown error"))
    }

    private func signIn(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: url, callback: .customScheme(LeaderboardEndpoint.callbackScheme)
            ) { @Sendable callback, error in
                // AuthenticationServices calls this on an XPC queue, not the main thread. Without @Sendable the
                // closure inherits the class's @MainActor isolation and Swift 6 traps on the executor check
                // (crash 02.11.2026, _dispatch_assert_queue_fail). It only resumes the continuation.
                if let callback {
                    cont.resume(returning: callback)
                } else {
                    cont.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            session.presentationContextProvider = anchor
            auth = session
            if !session.start() {
                cont.resume(throwing: LeaderboardError.server(0, String(localized: "the sign-in window could not open")))
            }
        }
    }

    /// The collector's one-line JSON answer, reduced to what the app uses (Sendable across the continuation).
    struct HelperAnswer: Sendable {
        var ok: Bool
        var error: String?
    }

    nonisolated private static func parse(_ data: Data) -> HelperAnswer {
        let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        let obj = (try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]) ?? [:]
        return HelperAnswer(ok: obj["ok"] as? Bool == true, error: obj["error"] as? String)
    }

    nonisolated private static func helper(_ url: URL, _ args: [String], stdin: Data?) async -> HelperAnswer {
        await withCheckedContinuation { cont in
            let p = Process()
            let out = Pipe()
            let input = Pipe()
            p.executableURL = url
            p.arguments = args + (appGroup.map { ["--app-group", $0] } ?? [])
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = input
            p.terminationHandler = { _ in
                cont.resume(returning: parse(out.fileHandleForReading.readDataToEndOfFile()))
            }
            do {
                try p.run()
                if let stdin { input.fileHandleForWriting.write(stdin) }
                try? input.fileHandleForWriting.close()
            } catch {
                cont.resume(returning: HelperAnswer(ok: false, error: error.localizedDescription))
            }
        }
    }
}

final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // Normally called on the main thread; if AuthenticationServices ever asks from another queue, hop instead
        // of trapping in assumeIsolated (same crash class as the completion handler above).
        if Thread.isMainThread {
            return MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() } }
    }
}

/// "Leaderboard" section of the window.
struct LeaderboardSection: View {
    let leaderboard: Leaderboard
    let setup: Setup
    @State private var joining = false
    @State private var confirmLeave = false

    var body: some View {
        Section {
            if leaderboard.joined, let s = leaderboard.state {
                StatusRow(
                    state: s.lastError == nil ? .ok : .problem, title: String(localized: "Leaderboard"),
                    value: String(localized: "Joined as \(s.displayName ?? "–")"), detail: detail(s)
                ) {
                    Button("Change Name…") { joining = true }.disabled(leaderboard.busy)
                    Button("Leave…") { confirmLeave = true }.disabled(leaderboard.busy)
                }
            } else if leaderboard.needsSignIn {
                StatusRow(
                    state: .problem, title: String(localized: "Leaderboard"), value: String(localized: "Leaving not finished"),
                    detail: leaderboard.state?.githubLogin.map {
                        String(localized: "Reports are stopped. Your account is still on the leaderboard server; deleting it needs one more GitHub sign-in as @\($0).")
                    } ?? String(localized: "Reports are stopped. Your account is still on the leaderboard server; deleting it needs one more GitHub sign-in.")
                ) {
                    Button("Sign In and Delete…") {
                        Task { await leaderboard.leave(helper: setup.helperURL, signIn: true) }
                    }
                    .disabled(leaderboard.busy)
                }
            } else if leaderboard.leavePending {
                StatusRow(
                    state: .problem, title: String(localized: "Leaderboard"), value: String(localized: "Leaving not finished"),
                    detail: String(localized: "Reports are stopped. Your account is still on the leaderboard server.")
                ) {
                    Button("Leave Again") { Task { await leaderboard.leave(helper: setup.helperURL) } }
                        .disabled(leaderboard.busy)
                }
            } else {
                StatusRow(
                    state: .off, title: String(localized: "Leaderboard"), value: String(localized: "Not joined"),
                    detail: String(localized: "Optional: compare your totals with other Claude Code users.")
                ) {
                    Button("Join…") { joining = true }.disabled(leaderboard.busy)
                }
            }
            if leaderboard.busy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for GitHub and the leaderboard server…").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error = leaderboard.error
                ?? (leaderboard.joined ? nil : leaderboard.state?.lastError.map {
                    LeaderboardProblem(kind: leaderboard.state?.lastErrorKind, message: $0).text
                }) {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $joining) {
            JoinSheet(leaderboard: leaderboard, setup: setup) { joining = false }
        }
        .confirmationDialog("Leave the leaderboard?", isPresented: $confirmLeave) {
            Button("Leave and Delete", role: .destructive) { Task { await leaderboard.leave(helper: setup.helperURL) } }
        } message: {
            Text("Your account, your profile and all reported totals are deleted from the leaderboard server, and the sign-in is removed from this Mac. Your history on this Mac stays.")
        }
    }

    private func detail(_ s: LeaderboardState) -> String {
        var parts: [String] = []
        if let login = s.githubLogin, !login.isEmpty { parts.append(String(localized: "GitHub @\(login)")) }
        if let error = s.lastError {
            parts.append(LeaderboardProblem(kind: s.lastErrorKind, message: error).text)
        } else if let at = s.lastReportAt {
            parts.append(String(localized: "Last report \(at.formatted(date: .omitted, time: .shortened))"))
        } else {
            parts.append(String(localized: "First report with the next update"))
        }
        let unit = Selection.unit
        if let place = s.place(period: Selection.period, unit: unit.rawValue) {
            parts.append(String(localized: "#\(place.rank ?? 0) of \(place.participants) (\(Format.periodName(Selection.period)), \(Format.unitName(unit)))"))
        }
        return parts.joined(separator: " · ")
    }
}

/// The one-button join (JoinPanel) in a sheet; after joining it shows the place and the name, and "Change Name…"
/// opens it there directly.
struct JoinSheet: View {
    let leaderboard: Leaderboard
    let setup: Setup
    let close: () -> Void

    var body: some View {
        let status = leaderboard.joinStatus
        VStack(alignment: .leading, spacing: 14) {
            Text(status.phase == .joined ? "You're on the Leaderboard" : "Join the Leaderboard")
                .font(.title3.weight(.semibold))
            JoinPanel(status: status) {
                Task { await leaderboard.join(helper: setup.helperURL) { await setup.updateNow() } }
            } rename: { name in
                Task { await leaderboard.rename(name, helper: setup.helperURL) }
            }
            HStack {
                Spacer()
                if status.phase == .joined {
                    Button(action: close) { Text("Done").primaryLabel() }
                        .buttonStyle(.borderedProminent).tint(Palette.buttonBackground).keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel, action: close)
                        .keyboardShortcut(.cancelAction)
                        .disabled(status.phase == .busy)
                }
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
