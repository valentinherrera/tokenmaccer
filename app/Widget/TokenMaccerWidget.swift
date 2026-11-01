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
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The collector writes every 15 minutes; the widget reloads shortly after.
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: .now) ?? .now
        completion(Timeline(entries: [current()], policy: .after(next)))
    }

    private func current() -> Entry {
        Entry(date: .now, data: WidgetData.load(), period: Selection.period, unit: Selection.unit)
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
