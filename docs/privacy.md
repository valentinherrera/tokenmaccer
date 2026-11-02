# TokenMaccer privacy notice

[Deutsch](privacy.de.md) · Last updated: 2 November 2026

This notice covers the downloadable TokenMaccer app and its optional leaderboard. It describes what the code in this repository does; where a fact depends on something the code does not decide (for example how long Supabase keeps its logs), it says so and marks it **TBD**.

## Without joining the leaderboard

TokenMaccer reads Claude Code's transcripts on your Mac (`~/.claude/projects`) and keeps daily totals there (`~/Library/Application Support/TokenMaccer/`, plus `widget.json` in the app's App Group container for the widget). None of this leaves your Mac. The app makes no request to the leaderboard server and has no account for you.

The only network request is the **update check** ([Sparkle](https://sparkle-project.org)): the app downloads `appcast.xml` from this repository's latest GitHub release, automatically once a day only if you agreed when the app asked, or when you click **Check for Updates…**. Like any download, GitHub sees your IP address and the request header with the app's name and version. The check sends nothing about you or your usage.

The `install.sh` setup (built from source) makes no network requests at all.

## When you join the leaderboard

Joining is optional and off by default. You sign in with GitHub through Supabase Auth in a system sign-in window.

### What is stored on the server

The server is a Supabase project of the maintainer in the region **eu-west-1** (AWS, Ireland).

| What | Contents | Visible to other participants |
|---|---|---|
| Sign-in account (Supabase Auth) | What GitHub passes on at sign-in: your GitHub user ID, username, name, email address and avatar link; when the account was created and when you last signed in | Only the username |
| Sign-in sessions (Supabase Auth) | Per sign-in: IP address, user agent (program name, version and system version as macOS sends them) and the refresh token | No |
| Profile | Your account ID, GitHub username, the display name you chose, when you joined, when your last report arrived | Display name and GitHub username |
| Totals | For each of the six periods (today, 7 days, 30 days, year to date, 1 year, all time): input tokens, output tokens, their value in USD at API list prices, the first day of the period, when it was last updated | Yes, together with your place |
| Report limit | Your GitHub user ID and the time of your last accepted report (at most one report per 25 minutes) | No |
| Server logs | Supabase records requests to its API, sign-in and Edge Functions in its own logs, including IP addresses. TokenMaccer's Edge Functions write only error codes to them | No |

Never sent: project names, prompts, file names, models or any other content of your sessions. The collector reports at most every 30 minutes, after its regular pass; the app itself sends no reports.

Only accounts with a GitHub sign-in can join: the server refuses to create a leaderboard profile for any other account.

### Leaderboard window and profile pictures

After its report the collector also fetches the boards for the app's leaderboard window: per period and unit the first 50 places (display name, GitHub username, total) and your own place. Then it downloads the GitHub profile pictures of the participants on these boards from `avatars.githubusercontent.com`, by GitHub username: at most 12 per pass, each again after seven days. These requests carry no key, token or cookie of TokenMaccer; like any download, GitHub sees your IP address and the request. Before you join and after you leave no picture is downloaded. Other participants' apps download your GitHub profile picture the same way, by your username; it is public on GitHub anyway.

The share card ("#3 of 120 this week") is drawn on your Mac. It goes only where you send it from the share menu, together with a link to the download page.

### What is stored on your Mac

- `leaderboard.json` in `~/Library/Application Support/TokenMaccer/`: your display name, GitHub username, account ID, your latest places, the times of the last report and the last attempt, the last error.
- The keychain item "TokenMaccer leaderboard sign-in" with the access and refresh token. Only TokenMaccer's background collector can read it.
- `leaderboard-top.json` (the boards of the leaderboard window, see above) and the folder `avatars/` with the cached profile pictures, in the same folder as `leaderboard.json`.

### How long

- **Account, sessions, profile and totals:** until you leave. There is no automatic deletion of inactive participants: if you stop background updates without leaving, your last totals stay on the server; they drop off the board after three days without a report but are only deleted when you leave. Whether and when the maintainer removes inactive accounts otherwise: **TBD**.
- **Report limit:** stays after you leave, so leaving and joining again cannot get around the 25-minute limit. It is deleted with the first report the server receives once it is more than one hour old.
- **Server logs:** as long as Supabase keeps them for this project; the period depends on Supabase's plan and is not set by TokenMaccer: **TBD**.

### Leaving and deleting

**Leave…** in the app deletes your sign-in account on the server. Your profile, totals, sessions and GitHub identity on the server go with it. Then the app removes the sign-in from your keychain, `leaderboard.json`, `leaderboard-top.json` and the cached profile pictures. It reports success only after the server confirmed the deletion. Not deleted by Leave: the report limit entry (see above) and entries in Supabase's logs.

If you sign in with a different GitHub account than the one that joined while leaving, the app refuses it and deletes the account that sign-in created on the server again, unless that account takes part in the leaderboard itself.

**Stop › Stop Background Updates & Remove Data…** leaves the leaderboard first and removes nothing while that fails.

## Who is responsible, and contact

The leaderboard is run by the maintainer of this repository (GitHub: [valentinherrera](https://github.com/valentinherrera)). Name and postal address of the responsible person: **TBD**. Legal basis of the processing and information on transfers outside the EU: **TBD**.

Service providers: [Supabase](https://supabase.com) hosts the server (database, sign-in, Edge Functions). GitHub provides the sign-in; GitHub's own privacy statement applies to your GitHub account. Updates are downloaded from GitHub Releases.

Questions, requests about your data, or reports of a problem: open an issue at <https://github.com/valentinherrera/tokenmaccer/issues>. Issues are public; do not post personal data there. A private contact channel: **TBD**.
