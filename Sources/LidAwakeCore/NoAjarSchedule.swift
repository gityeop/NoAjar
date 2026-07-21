import Foundation

public struct NoAjarScheduleSettings: Codable, Equatable {
    public var isEnabled: Bool
    public var rules: [NoAjarScheduleRule]

    public init(isEnabled: Bool = false, rules: [NoAjarScheduleRule] = []) {
        self.isEnabled = isEnabled
        self.rules = rules
    }
}

public struct NoAjarScheduleRule: Codable, Equatable, Identifiable {
    public var id: String
    public var enabled: Bool
    public var mode: AwakeMode
    public var keepHotspotConnected: Bool
    public var networkSSID: String?
    public var weekdays: [Int]
    public var startMinute: Int
    public var endMinute: Int

    public init(
        id: String = UUID().uuidString,
        enabled: Bool = true,
        mode: AwakeMode = .noAjar,
        keepHotspotConnected: Bool = false,
        networkSSID: String? = nil,
        weekdays: [Int] = [2, 3, 4, 5, 6],
        startMinute: Int = 9 * 60,
        endMinute: Int = 18 * 60
    ) {
        self.id = id
        self.enabled = enabled
        self.mode = mode
        self.keepHotspotConnected = keepHotspotConnected
        self.networkSSID = networkSSID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.weekdays = weekdays
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case enabled
        case mode
        case keepHotspotConnected
        case networkSSID
        case weekdays
        case startMinute
        case endMinute
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        mode = try container.decode(AwakeMode.self, forKey: .mode)
        networkSSID = try container
            .decodeIfPresent(String.self, forKey: .networkSSID)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        keepHotspotConnected = try container.decodeIfPresent(Bool.self, forKey: .keepHotspotConnected) ?? (networkSSID != nil)
        weekdays = try container.decode([Int].self, forKey: .weekdays)
        startMinute = try container.decode(Int.self, forKey: .startMinute)
        endMinute = try container.decode(Int.self, forKey: .endMinute)
    }

    public var normalizedWeekdays: [Int] {
        Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
    }

    public var durationMinutes: Int {
        let delta = endMinute - startMinute
        return delta > 0 ? delta : delta + minutesPerDay
    }

    public var isTimeValid: Bool {
        (0..<minutesPerDay).contains(startMinute) && (0..<minutesPerDay).contains(endMinute)
    }
}

public struct NoAjarScheduleSuppression: Codable, Equatable {
    public var ruleID: String
    public var windowEnd: Date

    public init(ruleID: String, windowEnd: Date) {
        self.ruleID = ruleID
        self.windowEnd = windowEnd
    }
}

public struct NoAjarScheduleWindow: Equatable {
    public let rule: NoAjarScheduleRule
    public let start: Date
    public let end: Date

    public init(rule: NoAjarScheduleRule, start: Date, end: Date) {
        self.rule = rule
        self.start = start
        self.end = end
    }
}

public enum NoAjarScheduleEvaluator {
    public static func activeWindow(
        settings: NoAjarScheduleSettings,
        suppressions: [NoAjarScheduleSuppression],
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> NoAjarScheduleWindow? {
        guard settings.isEnabled else { return nil }
        return activeWindow(
            rules: settings.rules,
            suppressions: suppressions,
            at: date,
            calendar: calendar
        )
    }

    public static func activeWindow(
        rules: [NoAjarScheduleRule],
        suppressions: [NoAjarScheduleSuppression] = [],
        at date: Date = Date(),
        calendar: Calendar = .current
    ) -> NoAjarScheduleWindow? {
        activeWindows(rules: rules, at: date, calendar: calendar)
            .filter { !isSuppressed($0, by: suppressions, at: date) }
            .sorted(by: windowPriority)
            .first
    }

    public static func nextWindow(
        settings: NoAjarScheduleSettings,
        after date: Date = Date(),
        calendar: Calendar = .current
    ) -> NoAjarScheduleWindow? {
        guard settings.isEnabled else { return nil }
        return nextWindow(rules: settings.rules, after: date, calendar: calendar)
    }

    public static func nextWindow(
        rules: [NoAjarScheduleRule],
        after date: Date = Date(),
        calendar: Calendar = .current
    ) -> NoAjarScheduleWindow? {
        let candidates = rules.flatMap { rule in
            upcomingWindows(for: rule, after: date, calendar: calendar)
        }
        return candidates.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return windowPriority(lhs, rhs)
            }
            return lhs.start < rhs.start
        }.first
    }

    public static func overlappingRuleIDs(_ rules: [NoAjarScheduleRule]) -> Set<String> {
        let intervals = rules.flatMap(weeklyIntervals)
        var ids = Set<String>()
        for lhsIndex in intervals.indices {
            for rhsIndex in intervals.indices where rhsIndex > lhsIndex {
                let lhs = intervals[lhsIndex]
                let rhs = intervals[rhsIndex]
                guard lhs.ruleID != rhs.ruleID,
                      lhs.start < rhs.end,
                      rhs.start < lhs.end else { continue }
                ids.insert(lhs.ruleID)
                ids.insert(rhs.ruleID)
            }
        }
        return ids
    }

    public static func suppressions(
        _ suppressions: [NoAjarScheduleSuppression],
        validAt date: Date = Date()
    ) -> [NoAjarScheduleSuppression] {
        suppressions.filter { $0.windowEnd > date }
    }

    private static func activeWindows(
        rules: [NoAjarScheduleRule],
        at date: Date,
        calendar: Calendar
    ) -> [NoAjarScheduleWindow] {
        let dayStart = calendar.startOfDay(for: date)
        let candidateDays = [-1, 0].compactMap {
            calendar.date(byAdding: .day, value: $0, to: dayStart)
        }
        return rules.flatMap { rule in
            candidateDays.compactMap { window(for: rule, startingOn: $0, calendar: calendar) }
        }.filter { $0.start <= date && date < $0.end }
    }

    private static func upcomingWindows(
        for rule: NoAjarScheduleRule,
        after date: Date,
        calendar: Calendar
    ) -> [NoAjarScheduleWindow] {
        guard rule.enabled, rule.isTimeValid, !rule.normalizedWeekdays.isEmpty else {
            return []
        }
        let dayStart = calendar.startOfDay(for: date)
        return (0...8).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: dayStart),
                  let window = window(for: rule, startingOn: day, calendar: calendar),
                  window.start > date else {
                return nil
            }
            return window
        }
    }

    private static func window(
        for rule: NoAjarScheduleRule,
        startingOn day: Date,
        calendar: Calendar
    ) -> NoAjarScheduleWindow? {
        guard rule.enabled,
              rule.isTimeValid,
              rule.normalizedWeekdays.contains(calendar.component(.weekday, from: day)) else {
            return nil
        }
        guard let start = calendar.date(byAdding: .minute, value: rule.startMinute, to: day),
              let end = calendar.date(byAdding: .minute, value: rule.durationMinutes, to: start) else {
            return nil
        }
        return NoAjarScheduleWindow(rule: rule, start: start, end: end)
    }

    private static func isSuppressed(
        _ window: NoAjarScheduleWindow,
        by suppressions: [NoAjarScheduleSuppression],
        at date: Date
    ) -> Bool {
        suppressions.contains { suppression in
            suppression.ruleID == window.rule.id &&
                date < suppression.windowEnd &&
                abs(suppression.windowEnd.timeIntervalSince(window.end)) < 1
        }
    }

    private static func windowPriority(_ lhs: NoAjarScheduleWindow, _ rhs: NoAjarScheduleWindow) -> Bool {
        if lhs.rule.mode != rhs.rule.mode {
            return lhs.rule.mode == .noAjar
        }
        if lhs.end != rhs.end {
            return lhs.end < rhs.end
        }
        return lhs.rule.id < rhs.rule.id
    }

    private static func weeklyIntervals(for rule: NoAjarScheduleRule) -> [WeeklyInterval] {
        guard rule.enabled,
              rule.isTimeValid,
              !rule.normalizedWeekdays.isEmpty else {
            return []
        }

        return rule.normalizedWeekdays.flatMap { weekday -> [WeeklyInterval] in
            let start = (weekday - 1) * minutesPerDay + rule.startMinute
            let end = start + rule.durationMinutes
            if end <= minutesPerWeek {
                return [WeeklyInterval(ruleID: rule.id, start: start, end: end)]
            }
            return [
                WeeklyInterval(ruleID: rule.id, start: start, end: minutesPerWeek),
                WeeklyInterval(ruleID: rule.id, start: 0, end: end - minutesPerWeek)
            ]
        }
    }
}

private let minutesPerDay = 24 * 60
private let minutesPerWeek = 7 * minutesPerDay

private struct WeeklyInterval {
    let ruleID: String
    let start: Int
    let end: Int
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
