import Foundation

/// A calendar day without time zone (Python's `datetime.date`), proleptic Gregorian.
struct CivilDate: Comparable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Days since 1970-01-01 (H. Hinnant's days_from_civil).
    var ordinal: Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    init(ordinal z0: Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        self.init(year: yoe + era * 400 + (m <= 2 ? 1 : 0), month: m, day: d)
    }

    func adding(days n: Int) -> CivilDate { CivilDate(ordinal: ordinal + n) }

    static func - (a: CivilDate, b: CivilDate) -> Int { a.ordinal - b.ordinal }
    static func < (a: CivilDate, b: CivilDate) -> Bool { a.ordinal < b.ordinal }

    static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func valid(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        (1...9999).contains(y) && (1...12).contains(m) && d >= 1 && d <= daysInMonth(y, m)
    }

    /// `date.isoformat()`
    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// `date.fromisoformat('YYYY-MM-DD')`
    init?(iso s: String) {
        let u = Array(s.utf8)
        guard u.count == 10, u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-"),
            let y = Self.digits(u, 0, 4), let m = Self.digits(u, 5, 2), let d = Self.digits(u, 8, 2),
            Self.valid(y, m, d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    static func digits(_ u: [UInt8], _ at: Int, _ n: Int) -> Int? {
        guard at + n <= u.count else { return nil }
        var v = 0
        for k in at..<(at + n) {
            let c = u[k]
            guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
            v = v * 10 + Int(c - UInt8(ascii: "0"))
        }
        return v
    }
}

/// A local wall-clock time (Python's naive `datetime` in local time).
struct LocalTime: Sendable {
    let date: CivilDate
    let hour: Int
    let minute: Int
    let second: Int

    /// `strftime('%Y-%m-%dT%H')`
    var hourKey: String { date.iso + String(format: "T%02d", hour) }

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone.current
        return c
    }

    init(date: CivilDate, hour: Int, minute: Int, second: Int) {
        self.date = date
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    init(_ instant: Date) {
        let c = Self.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
        self.init(
            date: CivilDate(year: c.year ?? 1970, month: c.month ?? 1, day: c.day ?? 1),
            hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }

    static func now() -> LocalTime { LocalTime(Date()) }

    /// The instant of this wall-clock time in the current time zone.
    var instant: Date {
        let c = DateComponents(
            year: date.year, month: date.month, day: date.day, hour: hour, minute: minute, second: second)
        return Self.calendar.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    /// `now.astimezone().isoformat(timespec='seconds')`, e.g. 2026-11-02T03:00:00+01:00
    var isoWithOffset: String {
        let offset = TimeZone.current.secondsFromGMT(for: instant)
        let a = Swift.abs(offset)
        var tz = String(format: "%@%02d:%02d", offset < 0 ? "-" : "+", a / 3600, (a % 3600) / 60)
        if a % 60 != 0 { tz += String(format: ":%02d", a % 60) }
        return date.iso + String(format: "T%02d:%02d:%02d", hour, minute, second) + tz
    }

    /// Python: `dt.datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone()` as local wall time.
    /// Follows Python 3.9's rules (the macOS system Python): `YYYY-MM-DD`, any one separator character,
    /// `HH[:MM[:SS[.fff|.ffffff]]]`, offset `±HH:MM[:SS[.ffffff]]`. Returns nil where Python raises.
    /// A time without offset is local time already.
    static func parseISO(_ raw: String) -> LocalTime? {
        let u = Array(raw.replacingOccurrences(of: "Z", with: "+00:00").utf8)
        guard u.count >= 10, u[4] == UInt8(ascii: "-"), u[7] == UInt8(ascii: "-"),
            let y = CivilDate.digits(u, 0, 4), let mo = CivilDate.digits(u, 5, 2), let d = CivilDate.digits(u, 8, 2),
            CivilDate.valid(y, mo, d)
        else { return nil }
        let date = CivilDate(year: y, month: mo, day: d)
        if u.count == 10 { return LocalTime(date: date, hour: 0, minute: 0, second: 0) }
        // The separator is one character; Python 3.9 counts it in UTF-8 bytes only for ASCII.
        guard u[10] < 0x80, u.count > 11 else { return nil }
        let rest = Array(u[11...])
        let tzAt = rest.firstIndex { $0 == UInt8(ascii: "+") || $0 == UInt8(ascii: "-") }
        let timePart = Array(rest[..<(tzAt ?? rest.count)])
        guard let (h, mi, s) = parseClock(timePart, allowShortFraction: true) else { return nil }
        guard let tzAt else { return LocalTime(date: date, hour: h, minute: mi, second: s) }
        let tzPart = Array(rest[(tzAt + 1)...])
        guard [5, 8, 15].contains(tzPart.count), let (th, tm, ts) = parseClock(tzPart, allowShortFraction: false)
        else { return nil }
        var offset = th * 3600 + tm * 60 + ts
        if rest[tzAt] == UInt8(ascii: "-") { offset = -offset }
        let utc = date.ordinal * 86400 + h * 3600 + mi * 60 + s - offset
        return LocalTime(Date(timeIntervalSince1970: TimeInterval(utc)))
    }

    /// `HH[:MM[:SS[.fff|.ffffff]]]`; the offset form needs exactly six fraction digits.
    private static func parseClock(_ u: [UInt8], allowShortFraction: Bool) -> (Int, Int, Int)? {
        guard let h = CivilDate.digits(u, 0, 2), h < 24 else { return nil }
        var m = 0
        var s = 0
        var p = 2
        if p < u.count {
            guard u[p] == UInt8(ascii: ":"), let v = CivilDate.digits(u, p + 1, 2), v < 60 else { return nil }
            m = v
            p += 3
        }
        if p < u.count {
            guard u[p] == UInt8(ascii: ":"), let v = CivilDate.digits(u, p + 1, 2), v < 60 else { return nil }
            s = v
            p += 3
        }
        if p < u.count {
            let n = u.count - p - 1
            guard u[p] == UInt8(ascii: "."), n == 6 || (allowShortFraction && n == 3),
                CivilDate.digits(u, p + 1, n) != nil
            else { return nil }
        }
        return (h, m, s)
    }
}
