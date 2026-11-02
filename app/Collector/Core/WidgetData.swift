import Foundation

let periodOrder = ["1D", "7D", "30D", "YTD", "1Y", "ALL"]

/// Input, output and USD of a span (Python's `Sums`).
struct Sums {
    var inp: Double = 0
    var out: Double = 0
    var usd: Double = 0

    static func + (a: Sums, b: Sums) -> Sums { Sums(inp: a.inp + b.inp, out: a.out + b.out, usd: a.usd + b.usd) }
    func scaled(_ f: Double) -> Sums { Sums(inp: inp * f, out: out * f, usd: usd * f) }
}

/// Aggregation for the widget; a line-by-line port of the Python collector's widget_data().
struct WidgetBuilder {
    let store: Store
    let prices: Prices
    let totals: [String: Sums]
    /// Days (YYYY-MM-DD) that have any hourly values.
    let daysWithHours: Set<String>

    init(store: Store, prices: Prices) {
        self.store = store
        self.prices = prices
        totals = Self.dailyTotals(store, prices)
        var withHours = Set<String>()
        for key in store.hours.keys {
            let u = Array(key.utf8)
            if u.count >= 11, u[10] == UInt8(ascii: "T") { withHours.insert(String(decoding: u[0..<10], as: UTF8.self)) }
        }
        daysWithHours = withHours
    }

    static func dailyTotals(_ store: Store, _ prices: Prices) -> [String: Sums] {
        var result: [String: Sums] = [:]
        for (day, models) in store.days {
            var z = result[day] ?? Sums()
            for (m, v) in models {
                z.inp += Double(totalInput(v))
                z.out += Double(v.at(1))
                z.usd += prices.usd(m, v)
            }
            result[day] = z
        }
        return result
    }

    func rangeSum(_ start: CivilDate, _ end: CivilDate) -> Sums {
        var s = Sums()
        var d = start
        while d <= end {
            if let z = totals[d.iso] { s = s + z }
            d = d.adding(days: 1)
        }
        return s
    }

    static func change(_ now: Double, _ before: Double) -> Double? {
        if before == 0 { return nil }
        return PyFloat.round((now - before) / before * 100, 1)
    }

    /// Usage of an earlier day from midnight up to the current time of day (current hour pro rata).
    /// Only if that day has no hourly values at all: the daily total pro rata by elapsed time of day.
    func untilNow(_ day: String, _ now: LocalTime) -> Sums {
        let frac = Double(now.minute) / 60
        var s = Sums()
        for h in 0...now.hour {
            let f = h == now.hour ? frac : 1.0
            for (m, v) in store.hours[day + String(format: "T%02d", h)] ?? OrderedDict() {
                s.inp += Double(totalInput(v)) * f
                s.out += Double(v.at(1)) * f
                s.usd += prices.usd(m, v) * f
            }
        }
        if !daysWithHours.contains(day), let t = totals[day] {
            s = t.scaled((Double(now.hour) + frac) / 24)
        }
        return s
    }

    static func orNone(_ s: Sums) -> Sums? { s.inp != 0 ? s : nil }

    static func point(_ s: Sums) -> JSONValue {
        var o = OrderedDict<JSONValue>()
        o["input"] = .int(PyFloat.roundInt(s.inp))
        o["usd"] = .double(PyFloat.round(s.usd, 2))
        return .object(o)
    }

    /// Running total, starting with 0 at the beginning of the period.
    static func cumulative(_ values: [Sums]) -> [JSONValue] {
        var points = [point(Sums())]
        var run = Sums()
        for v in values {
            run = run + v
            points.append(point(run))
        }
        return points
    }

    func dayValues(_ start: CivilDate, _ days: Int) -> [Sums] {
        (0..<days).map { totals[start.adding(days: $0).iso] ?? Sums() }
    }

    /// Usage per hour of a day; a day without hourly values is spread evenly over 24 hours.
    func hourValues(_ day: String, _ hours: Int) -> [Sums] {
        if !daysWithHours.contains(day) {
            let z = totals[day] ?? Sums()
            let each = Sums(inp: z.inp / 24, out: z.out / 24, usd: z.usd / 24)
            return [Sums](repeating: each, count: hours)
        }
        return (0..<hours).map { h in
            var z = Sums()
            for (m, v) in store.hours[day + String(format: "T%02d", h)] ?? OrderedDict() {
                z.inp += Double(totalInput(v))
                z.out += Double(v.at(1))
                z.usd += prices.usd(m, v)
            }
            return z
        }
    }

    /// Running total of the previous period; at index `at` (now) it carries exactly the change baseline.
    static func ghost(_ values: [Sums], _ at: Int, _ baseline: Sums?) -> JSONValue {
        guard let baseline else { return .null }
        var points = cumulative(values)
        points[at] = point(baseline)
        return .array(points)
    }

    static func metric(
        _ s: Sums, _ previous: Sums?, _ series: [JSONValue], _ prevSeries: JSONValue, _ slots: Int,
        _ start: CivilDate, _ end: CivilDate
    ) -> JSONValue {
        func opt(_ d: Double?) -> JSONValue { d.map { .double($0) } ?? .null }
        var o = OrderedDict<JSONValue>()
        o["input"] = .int(PyFloat.roundInt(s.inp))
        o["output"] = .int(PyFloat.roundInt(s.out))
        o["usd"] = .double(PyFloat.round(s.usd, 2))
        o["ratio"] = s.out != 0 ? .int(PyFloat.roundInt(s.inp / s.out)) : .null
        o["change_input"] = opt(previous.flatMap { change(s.inp, $0.inp) })
        o["change_usd"] = opt(previous.flatMap { change(s.usd, $0.usd) })
        o["series"] = .array(series)
        o["previous"] = prevSeries
        o["slots"] = .int(slots)
        o["from"] = .string(start.iso)
        o["to"] = .string(end.iso)
        return .object(o)
    }

    /// Every period is drawn like a stock chart: the line is the running total and ends at the headline,
    /// the dotted line is the running total of the previous period, the x axis covers the whole period.
    func widgetData(now: LocalTime) -> JSONValue {
        let today = now.date
        let first = totals.keys.min().flatMap { CivilDate(iso: $0) } ?? today
        var r = OrderedDict<JSONValue>()

        // 1D: hours 0-24; today so far vs. yesterday up to the same time of day
        let yesterday = today.adding(days: -1).iso
        let cur = hourValues(today.iso, now.hour + 1)
        var prev = Self.orNone(untilNow(yesterday, now))
        r["1D"] = Self.metric(
            rangeSum(today, today), prev, Self.cumulative(cur),
            Self.ghost(hourValues(yesterday, 24), now.hour + 1, prev), 25, today, today)

        // 7D/30D: n days, today so far vs. the same window n days earlier up to the same time of day
        for (name, n) in [("7D", 7), ("30D", 30)] {
            let start = today.adding(days: -(n - 1))
            let s = rangeSum(start, today)
            prev = Self.orNone(
                rangeSum(start.adding(days: -n), today.adding(days: -(n + 1)))
                    + untilNow(today.adding(days: -n).iso, now))
            r[name] = Self.metric(
                s, prev, Self.cumulative(dayValues(start, n)),
                Self.ghost(dayValues(start.adding(days: -n), n), n, prev), n + 1, start, today)
        }

        // YTD: axis Jan 1 - Dec 31, compared with last year up to the same date
        let jan1 = CivilDate(year: today.year, month: 1, day: 1)
        let yearDays = CivilDate(year: today.year + 1, month: 1, day: 1) - jan1
        let elapsed = (today - jan1) + 1
        let lyEnd =
            CivilDate.valid(today.year - 1, today.month, today.day)
            ? CivilDate(year: today.year - 1, month: today.month, day: today.day)
            : CivilDate(year: today.year - 1, month: today.month, day: 28)  // Feb 29
        let lyJan1 = CivilDate(year: today.year - 1, month: 1, day: 1)
        prev = Self.orNone(rangeSum(lyJan1, lyEnd))
        let lyDays = jan1 - lyJan1
        r["YTD"] = Self.metric(
            rangeSum(jan1, today), prev, Self.cumulative(dayValues(jan1, elapsed)),
            Self.ghost(dayValues(lyJan1, lyDays), min(elapsed, lyDays), prev), yearDays + 1, jan1, today)

        // 1Y: the last 365 days vs. the 365 days before
        let yStart = today.adding(days: -364)
        let pStart = yStart.adding(days: -365)
        prev = Self.orNone(rangeSum(pStart, yStart.adding(days: -1)))
        r["1Y"] = Self.metric(
            rangeSum(yStart, today), prev, Self.cumulative(dayValues(yStart, 365)),
            Self.ghost(dayValues(pStart, 365), 365, prev), 366, yStart, today)

        // ALL: since the first recorded day, nothing to compare with
        let nAll = (today - first) + 1
        r["ALL"] = Self.metric(
            rangeSum(first, today), nil, Self.cumulative(dayValues(first, max(nAll, 0))), .null, nAll + 1, first,
            today)

        var out = OrderedDict<JSONValue>()
        out["updated"] = .string(now.isoWithOffset)
        out["periods"] = .object(r)
        out["order"] = .array(periodOrder.map { .string($0) })
        return .object(out)
    }
}
