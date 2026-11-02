import SwiftUI
import WidgetKit

struct Entry: TimelineEntry {
    let date: Date
    let data: WidgetData?
    let period: String
    let unit: Unit
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, data: WidgetData.load(), period: "1D", unit: .tokens)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(current(preview: context.isPreview))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The collector writes every 5 minutes; the widget reloads shortly after.
        let next = Calendar.current.date(byAdding: .minute, value: 5, to: .now) ?? .now
        completion(Timeline(entries: [current(preview: context.isPreview)], policy: .after(next)))
    }

    private func current(preview: Bool) -> Entry {
        let (data, result) = WidgetData.read()
        // App edition: leave a note for the app's status window (it cannot see into the sandbox otherwise).
        // Not for the widget gallery's preview: the note means "on the desktop" (onboarding step 2 checks off).
        if Edition.isApp, !preview {
            WidgetHealth.record(result, in: Selection.defaults)
            // which build is really running (the app's self-heal waits for this after an update)
            Selection.defaults.set(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
                                   forKey: SelfHealPlan.widgetBuildKey)
        }
        return Entry(date: .now, data: data, period: Selection.period, unit: Selection.unit)
    }
}

struct WidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: Entry

    var body: some View {
        TickerView(data: entry.data, period: entry.period, unit: entry.unit,
                   size: family == .systemSmall ? .small : family == .systemMedium ? .medium : .large)
            .containerBackground(.background, for: .widget)
    }
}

@main
struct TokenMaccerWidgets: WidgetBundle {
    var body: some Widget {
        TokenMaccerWidget()
        // the leaderboard exists in the app edition only (the install.sh edition has no collector that joins)
        #if TM_APP_EDITION
        LeaderboardWidget()
        #endif
    }
}

struct TokenMaccerWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TokenMaccer", provider: Provider()) { e in
            WidgetView(entry: e)
        }
        .configurationDisplayName("TokenMaccer")
        .description("Claude Code token usage, ticker style: today, 7 and 30 days, year, all time.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: Leaderboard widget

struct BoardEntry: TimelineEntry {
    let date: Date
    let data: LeaderboardWidgetData?
    /// The chosen group's id; nil for the global board.
    let group: String?
    let period: String
    let unit: Unit
}

struct BoardProvider: AppIntentTimelineProvider {
    // the widget gallery and the placeholder show a made-up board, never the participants' real names
    func placeholder(in context: Context) -> BoardEntry { sample() }

    func snapshot(for configuration: LeaderboardScopeIntent, in context: Context) async -> BoardEntry {
        context.isPreview ? sample() : current(configuration)
    }

    private func sample() -> BoardEntry {
        BoardEntry(date: .now, data: .sample, group: nil, period: "1D", unit: .tokens)
    }

    func timeline(for configuration: LeaderboardScopeIntent, in context: Context) async -> Timeline<BoardEntry> {
        // the boards change at most every 30 minutes; the collector asks for a reload when its copy changed
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        return Timeline(entries: [current(configuration)], policy: .after(next))
    }

    private func current(_ configuration: LeaderboardScopeIntent) -> BoardEntry {
        BoardEntry(date: .now, data: LeaderboardWidgetData.load(), group: configuration.scope?.groupID,
                   period: BoardSelection.period, unit: BoardSelection.unit)
    }
}

struct LeaderboardWidget: Widget {
    var body: some WidgetConfiguration {
        // same kind as the StaticConfiguration before groups: placed widgets keep their place and, without a choice,
        // show the global board
        AppIntentConfiguration(kind: "TokenMaccerLeaderboard", intent: LeaderboardScopeIntent.self,
                               provider: BoardProvider()) { e in
            LeaderboardWidgetEntryView(entry: e)
        }
        .configurationDisplayName("TokenMaccer Leaderboard")
        .description("Your place among Claude Code users, or in one of your groups: the top places and your own row.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

struct LeaderboardWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: BoardEntry

    var body: some View {
        LeaderboardWidgetView(data: entry.data, group: entry.group, period: entry.period, unit: entry.unit,
                              size: family == .systemLarge ? .large : .medium)
            .containerBackground(.background, for: .widget)
    }
}
