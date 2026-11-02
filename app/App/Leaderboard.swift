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

    func refresh() { state = LeaderboardState.load(dataDir: dataDir) }

    /// The same server the collector uses: overrides in the App Group defaults (tests), else app-config.json.
    var endpoint: LeaderboardEndpoint? {
        LeaderboardEndpoint.resolve(
            environment: ProcessInfo.processInfo.environment,
            defaults: appGroup.flatMap { UserDefaults(suiteName: $0) },
            bundled: Bundle.main.url(forResource: "app-config", withExtension: "json").flatMap { try? Data(contentsOf: $0) })
    }

    /// Sign in with GitHub, then let the collector join; `afterJoin` runs a collection pass (first report).
    func join(displayName: String, helper: URL?, afterJoin: @escaping () async -> Void) async {
        guard !busy else { return }
        guard let helper else { error = "The background collector is missing from TokenMaccer.app."; return }
        guard let endpoint else { error = LeaderboardError.noServer.description; return }
        error = nil
        busy = true
        defer { busy = false }
        let verifier = PKCE.verifier()
        let callback: URL
        do {
            callback = try await signIn(endpoint.authorizeURL(challenge: PKCE.challenge(for: verifier)))
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            return  // the user closed the sign-in window
        } catch {
            self.error = "GitHub sign-in failed: \(error.localizedDescription)"
            return
        }
        let code: String
        switch LeaderboardEndpoint.code(fromCallback: callback) {
        case .success(let c): code = c
        case .failure(let e):
            error = "GitHub sign-in failed: \(e)"
            return
        }
        let input = (try? JSONSerialization.data(withJSONObject: ["code": code, "verifier": verifier])) ?? Data()
        let answer = await Self.helper(helper, ["leaderboard", "join", "--display-name", displayName], stdin: input)
        refresh()
        if answer["ok"] as? Bool == true {
            await afterJoin()
            refresh()
        } else {
            error = "Could not join: " + ((answer["error"] as? String) ?? "unknown error")
        }
    }

    func leave(helper: URL?) async {
        guard !busy, let helper else { return }
        error = nil
        busy = true
        defer { busy = false }
        let answer = await Self.helper(helper, ["leaderboard", "leave"], stdin: nil)
        refresh()
        if answer["ok"] as? Bool != true {
            error = (answer["error"] as? String).map { "Could not leave: " + $0 } ?? "Could not leave."
        }
    }

    /// Synchronous leave for "Remove Data" and `--unregister --remove-data`: true when nothing is left on the
    /// server (or the user never joined). At most 30 s.
    nonisolated static func leaveBeforeRemoval(dataDir: String, helper: URL?) -> (ok: Bool, error: String?) {
        guard let state = LeaderboardState.load(dataDir: dataDir), state.joined || state.leavePending else {
            return (true, nil)
        }
        guard let helper else { return (false, "the background collector is missing") }
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
            return (false, "the leaderboard server did not answer")
        }
        let obj = parse(out.fileHandleForReading.readDataToEndOfFile())
        return obj["ok"] as? Bool == true ? (true, nil) : (false, (obj["error"] as? String) ?? "unknown error")
    }

    private func signIn(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: url, callback: .customScheme(LeaderboardEndpoint.callbackScheme)
            ) { callback, error in
                if let callback {
                    cont.resume(returning: callback)
                } else {
                    cont.resume(throwing: error ?? ASWebAuthenticationSessionError(.canceledLogin))
                }
            }
            session.presentationContextProvider = anchor
            auth = session
            if !session.start() {
                cont.resume(throwing: LeaderboardError.server(0, "the sign-in window could not open"))
            }
        }
    }

    nonisolated private static func parse(_ data: Data) -> [String: Any] {
        let last = String(decoding: data, as: UTF8.self).split(separator: "\n").last.map(String.init) ?? ""
        return (try? JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]) ?? [:]
    }

    nonisolated private static func helper(_ url: URL, _ args: [String], stdin: Data?) async -> [String: Any] {
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
                cont.resume(returning: ["ok": false, "error": error.localizedDescription])
            }
        }
    }
}

final class AuthAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.keyWindow ?? NSApp.windows.first ?? NSWindow() }
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
                    state: s.lastError == nil ? .ok : .problem, title: "Leaderboard",
                    value: "Joined as \(s.displayName ?? "–")", detail: detail(s)
                ) {
                    Button("Leave…") { confirmLeave = true }.disabled(leaderboard.busy)
                }
            } else if leaderboard.leavePending {
                StatusRow(
                    state: .problem, title: "Leaderboard", value: "Leaving not finished",
                    detail: "Reports are stopped. Your entry is still on the server."
                ) {
                    Button("Leave Again") { Task { await leaderboard.leave(helper: setup.helperURL) } }
                        .disabled(leaderboard.busy)
                }
            } else {
                StatusRow(
                    state: .off, title: "Leaderboard", value: "Not joined",
                    detail: "Optional: compare your totals with other Claude Code users."
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
            if let error = leaderboard.error ?? (leaderboard.joined ? nil : leaderboard.state?.lastError) {
                Text(error).font(.callout).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $joining) {
            JoinLeaderboardSheet { name in
                joining = false
                Task { await leaderboard.join(displayName: name, helper: setup.helperURL) { await setup.updateNow() } }
            } cancel: {
                joining = false
            }
        }
        .confirmationDialog("Leave the leaderboard?", isPresented: $confirmLeave) {
            Button("Leave and Delete", role: .destructive) { Task { await leaderboard.leave(helper: setup.helperURL) } }
        } message: {
            Text("Your profile and all reported totals are deleted from the leaderboard server, and the sign-in is removed from this Mac. Your history on this Mac stays.")
        }
    }

    private func detail(_ s: LeaderboardState) -> String {
        var parts: [String] = []
        if let login = s.githubLogin, !login.isEmpty { parts.append("GitHub @\(login)") }
        if let error = s.lastError {
            parts.append(error)
        } else if let at = s.lastReportAt {
            parts.append("Last report " + at.formatted(date: .omitted, time: .shortened))
        } else {
            parts.append("First report with the next update")
        }
        let unit = Selection.unit
        if let place = s.place(period: Selection.period, unit: unit.rawValue) {
            parts.append("#\(place.rank ?? 0) of \(place.participants), \(Format.periodName(Selection.period).lowercased()), \(unit == .usd ? "USD" : "tokens")")
        }
        return parts.joined(separator: " · ")
    }
}

/// Consent and display name before the GitHub sign-in.
struct JoinLeaderboardSheet: View {
    let join: (String) -> Void
    let cancel: () -> Void
    @State private var name = ""

    private var cleaned: String? { LeaderboardSync.cleanDisplayName(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Join the Leaderboard").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                consent("arrow.up.circle",
                        "At most every 30 minutes, TokenMaccer sends your totals for today, 7 days, 30 days, year to date, 1 year and all time: input and output tokens and their value in USD at API prices.")
                consent("lock",
                        "Never projects, prompts, file names or any other content. Everything else stays on this Mac.")
                consent("person.2",
                        "Other participants see your display name, your GitHub username and these totals.")
                consent("trash",
                        "Leave at any time: your profile and all reported totals are deleted from the server.")
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Display name", text: $name, prompt: Text("Display name (1–32 characters)"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { if let cleaned { join(cleaned) } }
                Text("Sign-in with GitHub through the leaderboard server (Supabase). The sign-in is kept in your keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Continue with GitHub") { if let cleaned { join(cleaned) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(cleaned == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func consent(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }
}
