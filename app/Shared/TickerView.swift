import AppIntents
import Charts
import SwiftUI

enum Size { case small, medium, large }

/// Stock-ticker style view. Rising usage is orange, falling usage green.
struct TickerView: View {
    let data: WidgetData?
    let period: String
    let unit: Unit
    let size: Size

    @Environment(\.widgetRenderingMode) private var mode
    @Environment(\.colorScheme) private var scheme

    private var p: Period? { data?.periods[period] }

    /// Pill color with enough contrast for white text: darker (increased-contrast) variants in light mode,
    /// system colors in dark mode.
    private var pillColor: Color {
        let up = (change ?? 0) > 0
        if scheme == .dark { return up ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen) }
        return up ? Color(red: 0.788, green: 0.204, blue: 0) : Color(red: 0.141, green: 0.541, blue: 0.239)
    }

    /// Baseline of the curve, like the previous close of a stock: average per point in the previous period.
    private func baseline(_ p: Period) -> Double? {
        guard let c = change, c > -100 else { return nil }
        let now = unit == .tokens ? Double(p.input) : p.usd
        return now / (1 + c / 100) / Double(max(p.series.count, 1))
    }

    private var change: Double? {
        unit == .tokens ? p?.change_input : p?.change_usd
    }

    private var trendColor: Color {
        guard let c = change else { return Color.primary.opacity(0.6) }
        return c > 0 ? Color(nsColor: .systemOrange) : Color(nsColor: .systemGreen)
    }

    var body: some View {
        if let p {
            switch size {
            case .small: small(p)
            case .medium: medium(p)
            case .large: large(p)
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Claude Code").font(.headline)
                Text("No data yet. The collector runs every 15 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Building blocks

    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude Code").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 4)
            let name = Text(Format.periodName(period))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            // In the small widget the header is the period switch; medium/large have the chip row.
            if size == .small {
                Button(intent: NextPeriod()) { name }.buttonStyle(.plain)
            } else {
                name
            }
        }
    }

    private func headline(_ p: Period, fontSize: CGFloat) -> some View {
        Button(intent: ToggleUnit()) {
            Text(unit == .tokens ? Format.tokens(p.input) : Format.usd(p.usd))
                .font(.system(size: fontSize, weight: .semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText())
                .widgetAccentable()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var changePill: some View {
        if change != nil {
            let text = Text(Format.percent(change))
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            if mode == .fullColor {
                text.foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 6).fill(pillColor))
            } else {
                // Clear/tinted: no colored fill, the sign carries the meaning
                text.foregroundStyle(.secondary).widgetAccentable()
            }
        }
    }

    private func subline(_ p: Period) -> some View {
        let parts = [
            unit == .tokens ? Format.usd(p.usd) : Format.tokens(p.input) + " in",
            Format.tokens(p.output) + " out",
            p.ratio.map { "\($0):1" } ?? "–",
        ]
        return Text(parts.joined(separator: " · "))
            .font(.system(size: 11)).monospacedDigit()
            .foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
    }

    private func chips(_ active: String) -> some View {
        HStack(spacing: 4) {
            ForEach(Selection.periods, id: \.self) { k in
                Button(intent: SelectPeriod(k)) {
                    Text(k)
                        .font(.system(size: 11, weight: k == active ? .semibold : .regular))
                        .foregroundStyle(k == active ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(k == active ? Color.primary.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            if let d = data?.updatedDate {
                Text("Updated \(d.formatted(date: .omitted, time: .shortened))")
            }
        }
        .font(.system(size: 11)).foregroundStyle(.tertiary)
    }

    private func curve(_ p: Period) -> some View {
        Curve(series: p.series, unit: unit, color: trendColor, baseline: baseline(p))
            .accessibilityLabel("Trend, \(Format.periodName(period))")
    }

    // MARK: Sizes

    private func small(_ p: Period) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            headline(p, fontSize: 26)
            changePill
            Spacer(minLength: 2)
            curve(p)
        }
    }

    private func medium(_ p: Period) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    headline(p, fontSize: 28)
                    changePill
                    subline(p)
                }
                .frame(width: 140, alignment: .leading)
                curve(p)
            }
            Spacer(minLength: 0)
            chips(period)
        }
    }

    private func large(_ p: Period) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                headline(p, fontSize: 34)
                changePill
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                GridRow {
                    // never repeat the headline: show the other unit here
                    if unit == .tokens {
                        stat("USD", Format.usd(p.usd))
                    } else {
                        stat("Input", Format.tokens(p.input))
                    }
                    stat("Output", Format.tokens(p.output))
                    stat("In per out", p.ratio.map { "\($0):1" } ?? "–")
                }
            }
            curve(p).frame(maxHeight: .infinity)
            chips(period)
            footer
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }
}

/// Line with a gradient fill. The dotted rule is the average per point in the previous period
/// (the basis of the change, like a stock's previous close); without a previous period, the own average.
struct Curve: View {
    let series: [Point]
    let unit: Unit
    let color: Color
    let baseline: Double?

    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        let values = series.map { unit == .tokens ? Double($0.input) : $0.usd }
        let mean = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        let opacity: Double = mode == .fullColor ? 0.28 : 0.10
        let gradient = LinearGradient(colors: [color.opacity(opacity), color.opacity(0.0)], startPoint: .top, endPoint: .bottom)
        let points: [(Int, Double)] = Array(values.enumerated())
        Chart {
            ForEach(points, id: \.0) { p in
                AreaMark(x: .value("t", p.0), y: .value("v", p.1))
                    .foregroundStyle(gradient)
                    .interpolationMethod(.linear)
                LineMark(x: .value("t", p.0), y: .value("v", p.1))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
            }
            RuleMark(y: .value("Baseline", baseline ?? mean))
                .foregroundStyle(Color.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [1, 3]))
        }
        .widgetAccentable()
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...max(series.count - 1, 1))
        .chartLegend(.hidden)
    }
}
