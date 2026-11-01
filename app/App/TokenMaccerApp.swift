import SwiftUI
import WidgetKit

@main
struct TokenMaccerApp: App {
    var body: some Scene {
        WindowGroup("TokenMaccer") {
            Overview()
        }
        .windowResizability(.contentSize)
    }
}

/// Host app window: the same view as the large widget, plus how to add the widget.
struct Overview: View {
    @AppStorage("period", store: appGroup.flatMap { UserDefaults(suiteName: $0) }) private var period = "1D"
    @AppStorage("unit", store: appGroup.flatMap { UserDefaults(suiteName: $0) }) private var unit = "tokens"
    @State private var data = WidgetData.load()
    private let tick = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TickerView(data: data, period: period, unit: Unit(rawValue: unit) ?? .tokens, size: .large)
                .frame(width: 340, height: 340)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 20).fill(.quaternary))
            Text("Add the widget: right-click the desktop, choose “Edit Widgets…”, search for “TokenMaccer”.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(width: 372, alignment: .leading)
        }
        .padding(20)
        .onReceive(tick) { _ in
            data = WidgetData.load()
        }
        .onChange(of: period) { WidgetCenter.shared.reloadAllTimelines() }
        .onChange(of: unit) { WidgetCenter.shared.reloadAllTimelines() }
    }
}
