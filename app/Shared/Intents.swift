import AppIntents
import WidgetKit

struct SelectPeriod: AppIntent {
    static let title: LocalizedStringResource = "Select period"
    static let isDiscoverable = false

    @Parameter(title: "Period") var period: String

    init() { period = "1D" }
    init(_ p: String) { period = p }

    func perform() async throws -> some IntentResult {
        Selection.period = period
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct NextPeriod: AppIntent {
    static let title: LocalizedStringResource = "Next period"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        Selection.nextPeriod()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct ToggleUnit: AppIntent {
    static let title: LocalizedStringResource = "Tokens or USD"
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        Selection.unit = Selection.unit == .tokens ? .usd : .tokens
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
