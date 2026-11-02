# TokenMaccer privacy notice

[Deutsch](privacy.de.md) · Last updated: 2 November 2026

This notice covers the downloadable TokenMaccer app and its optional leaderboard. It describes what the code in this repository does; where a fact depends on a service provider rather than on the code (for example how long Supabase keeps its logs), it says so and gives the provider's own statement.

## Without joining the leaderboard

TokenMaccer reads Claude Code's transcripts on your Mac (`~/.claude/projects`) and keeps daily totals there (`~/Library/Application Support/TokenMaccer/`, plus `widget.json` in the app's App Group container for the widget). None of this leaves your Mac. The app makes no request to the leaderboard server and has no account for you.

The only network request is the **update check** ([Sparkle](https://sparkle-project.org)): the app downloads `appcast.xml` from this repository's latest GitHub release, automatically once a day (switch it off in **Settings… › Updates**), and when you click **Check for Updates…**; when a new version is listed there, it downloads that version from the same release. Like any download, GitHub sees your IP address and the request header with the app's name and version. The check sends nothing about you or your usage.

The `install.sh` setup (built from source) makes no network requests at all.

## The website tokenmaccer.app

The website (download page, this notice, invitation links) is hosted by [Vercel](https://vercel.com). Like any web server, Vercel receives your IP address, the address you open (for an invitation link, that includes the group's invitation code) and your browser's request headers, and records requests in its logs. On the plan this website uses (Pro), Vercel shows these logs to the maintainer for one day; Vercel does not state how long it keeps them on its own systems beyond that. The maintainer does not export or copy these logs. The pages set no cookies, use no analytics and load nothing from other servers. They remember your language choice only in your browser (local storage). An invitation page hands the code to the app on your Mac and sends it nowhere else.

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
| Groups (optional) | Per group: its name, its invitation code, the account ID of its owner, when it was created | Only to the group's members: name, invitation code and who owns it |
| Group memberships (optional) | Per group you are in: your account ID and when you joined | Only to the group's members: your display name, GitHub username and your place and totals on the group's ranking |
| Join attempts | Your GitHub user ID (else your account ID) and how many times you tried to join a group in each hour (at most 30 per hour) | No |
| Server logs | Supabase records requests to its API, sign-in and Edge Functions in its own logs, including IP addresses. TokenMaccer's Edge Functions write only error codes to them | No |

Never sent: project names, prompts, file names, models or any other content of your sessions. The collector reports at most every 30 minutes, after its regular pass; the app itself sends no reports.

Only accounts with a GitHub sign-in can join: the server refuses to create a leaderboard profile for any other account.

### Leaderboard window and profile pictures

After its report the collector also fetches the boards for the app's leaderboard window: per period and unit the first 50 places (display name, GitHub username, total) and your own place. Then it downloads the GitHub profile pictures of the participants on these boards from `avatars.githubusercontent.com`, by GitHub username: at most 12 per pass, each again after seven days. These requests carry no key, token or cookie of TokenMaccer; like any download, GitHub sees your IP address and the request. Before you join and after you leave no picture is downloaded. Other participants' apps download your GitHub profile picture the same way, by your username; it is public on GitHub anyway.

The share card ("#3 of 120 this week") is drawn on your Mac. It goes only where you send it from the share menu, together with a link to the project page on GitHub (github.com/valentinherrera/tokenmaccer).

### Groups

Groups are optional and need the leaderboard. Whoever has a group's invitation link (`https://tokenmaccer.app/join/…` or `tokenmaccer://join/…`) or its code can join it. Only the members of a group see that it exists, its name, its invitation code, who is in it (display name, GitHub username, who owns it) and its ranking; a wrong code reveals nothing about any group. A group's ranking shows what the global leaderboard already shows of every participant (display name, GitHub username, totals), limited to the group's members. The owner can rename the group, make a new link (the old one stops working at once), remove members and delete the group. Limits: at most 10 groups of your own, 20 groups in all, 100 members per group, 30 join attempts per hour.

After every report, right after every group change you make in the app, and when you open the Leaderboard window, pick a group there or open **Groups…** (at most once a minute), the collector fetches your groups, their members and their rankings (per period and unit the first 50 places and your own) and then the profile pictures of the people on these rankings, the same way as for the global boards above. A group's invitation card is drawn on your Mac and goes only where you send it, together with the invitation link.

### What is stored on your Mac

- `leaderboard.json` in `~/Library/Application Support/TokenMaccer/`: your display name, GitHub username, account ID, your latest places, the times of the last report and the last attempt, the last error.
- The keychain item "TokenMaccer leaderboard sign-in" with the access and refresh token. Only TokenMaccer's background collector can read it.
- `leaderboard-top.json` (the boards of the leaderboard window, see above) and the folder `avatars/` with the cached profile pictures, in the same folder as `leaderboard.json`.
- `leaderboard-groups.json` in the same folder: your groups (name, invitation code, whether you own them), their members (display name, GitHub username, a member handle the owner uses to remove someone) and their rankings.
- `leaderboard-widget.json` in the App Group container: a copy for the leaderboard widget, per board the first eight places and your own, the same for each of your groups (with the group's name), with the profile pictures of these people.

### How long

- **Account, sessions, profile and totals:** until you leave. There is no automatic deletion of inactive participants: if you stop background updates without leaving, your last totals stay on the server; they drop off the board after three days without a report but are only deleted when you leave. The maintainer does not remove inactive accounts either; an account is removed by hand only when you ask for it or to stop abuse.
- **Report limit:** stays after you leave, so leaving and joining again cannot get around the 25-minute limit. It is deleted with the first report the server receives once it is more than one hour old.
- **Groups and memberships:** until you leave the group or the leaderboard, the owner removes you, or the owner deletes the group.
- **Join attempts:** stay after you leave; entries older than a day are deleted with the next join attempt anyone makes.
- **Server logs:** as long as Supabase keeps them for this project. The project is on Supabase's free plan, for which Supabase states a log retention of one day ("API & Database"). Supabase stores its logs in data centres in the EU. The period is set by Supabase, not by TokenMaccer, and changes if the plan changes.

### Leaving and deleting

**Leave…** in the app deletes your sign-in account on the server. Your profile, totals, sessions, group memberships and GitHub identity on the server go with it. Groups you own pass to the member who joined first; a group without another member is deleted. Then the app removes the sign-in from your keychain, `leaderboard.json`, `leaderboard-top.json`, `leaderboard-groups.json`, `leaderboard-widget.json` and the cached profile pictures. It reports success only after the server confirmed the deletion. Not deleted by Leave: the report limit entry, the join attempts (see above) and entries in Supabase's logs.

**Leave Group…** (Leaderboard window › Groups…) removes only that one membership, with the same hand-over when you own the group; your entry on the leaderboard stays.

If you sign in with a different GitHub account than the one that joined while leaving, the app refuses it and deletes the account that sign-in created on the server again, unless that account takes part in the leaderboard itself.

**Stop › Stop Background Updates & Remove Data…** leaves the leaderboard first and removes nothing while that fails.

## Who is responsible, and contact

Responsible (controller) for the leaderboard and the website: PAUS UG (haftungsbeschränkt), Gustav-Poensgen-Str. 49, 40215 Düsseldorf, Germany, represented by its managing director Valentin Herrera, who maintains this repository (GitHub: [valentinherrera](https://github.com/valentinherrera)). Email: valentin@paus.works. Legal notice: <https://tokenmaccer.app/impressum>.

Service providers: [Supabase](https://supabase.com) hosts the server (database, sign-in, Edge Functions); [Vercel](https://vercel.com) hosts the website. Both process the data on our behalf under their data processing addendums. GitHub provides the sign-in; GitHub's own privacy statement applies to your GitHub account. Updates are downloaded from GitHub Releases.

### Legal basis

- **Leaderboard and groups:** Art. 6(1)(b) GDPR. Storing and showing your display name, username, totals and place, and your groups, is the service you ask for when you join; you end it at any time with **Leave…**. The profile pictures the app downloads from GitHub are part of this board.
- **Name and email address from GitHub:** the leaderboard does not use them; Supabase Auth stores them because GitHub passes them on at sign-in. Art. 6(1)(f), our legitimate interest in a sign-in through GitHub instead of an account system of our own.
- **Report limit, join-attempt counter and the security checks behind them:** Art. 6(1)(f), our legitimate interest in keeping the leaderboard free of manipulation and overload.
- **Server logs at Supabase and Vercel:** Art. 6(1)(f), our legitimate interest in running and securing the server and the website.
- **Update check:** it goes directly from your Mac to GitHub, and we receive nothing from it. Art. 6(1)(f), our interest in delivering security and bug fixes; you can switch it off.

Taking part in the leaderboard is neither required by law nor by contract. If you do not join, the app works the same, only without the leaderboard. There is no automated decision-making or profiling.

### Transfers outside the EU

The leaderboard's database, sign-in and backups are stored in Supabase's region eu-west-1 (AWS, Ireland), and Supabase stores its logs in the EU. Supabase's contracting company is Supabase Pte. Ltd. in Singapore, supported by Supabase, Inc. in the USA; transfers to them rely on the EU Standard Contractual Clauses in Supabase's data processing addendum (Art. 46(2)(c) GDPR).

Vercel Inc. (USA) is certified under the EU-U.S. Data Privacy Framework, so transfers to Vercel rely on the EU Commission's adequacy decision for it (Art. 45 GDPR); Vercel's data processing addendum adds the EU Standard Contractual Clauses.

GitHub (USA), which you use for sign-in and from which updates and profile pictures are downloaded, is also certified under the EU-U.S. Data Privacy Framework and processes these data as its own controller under GitHub's privacy statement.

### Your rights

You have the right to access your data (Art. 15 GDPR), to have it corrected (Art. 16) or deleted (Art. 17), to restrict its processing (Art. 18) and to receive it in a portable format (Art. 20). Where we rely on our legitimate interest (Art. 6(1)(f)), you can object to the processing on grounds relating to your particular situation (Art. 21). Write to valentin@paus.works. **Leave…** in the app deletes your account and leaderboard data at once (what stays, and for how long, is listed under "Leaving and deleting" and "How long").

You also have the right to lodge a complaint with a data protection supervisory authority. The authority responsible for us is the Landesbeauftragte für Datenschutz und Informationsfreiheit Nordrhein-Westfalen, Postfach 20 04 44, 40102 Düsseldorf, Germany, <https://www.ldi.nrw.de>.

Questions, requests about your data, or reports of a problem: open an issue at <https://github.com/valentinherrera/tokenmaccer/issues>. Issues are public; do not post personal data there. For anything private, write to valentin@paus.works.
