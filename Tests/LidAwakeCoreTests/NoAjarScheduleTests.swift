import XCTest
@testable import LidAwakeCore

final class NoAjarScheduleTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func testWeekdayDaytimeScheduleIsActiveOnlyInsideWindow() throws {
        let rule = NoAjarScheduleRule(id: "workday", weekdays: [2, 3, 4, 5, 6], startMinute: 9 * 60, endMinute: 18 * 60)

        XCTAssertNotNil(activeWindow([rule], at: "2026-06-01 09:00"))
        XCTAssertNotNil(activeWindow([rule], at: "2026-06-01 17:59"))
        XCTAssertNil(activeWindow([rule], at: "2026-06-01 18:00"))
        XCTAssertNil(activeWindow([rule], at: "2026-06-07 10:00"))
    }

    func testOvernightScheduleUsesStartDay() throws {
        let rule = NoAjarScheduleRule(id: "night", weekdays: [2], startMinute: 22 * 60, endMinute: 7 * 60)

        XCTAssertNotNil(activeWindow([rule], at: "2026-06-01 23:00"))
        XCTAssertNotNil(activeWindow([rule], at: "2026-06-02 06:59"))
        XCTAssertNil(activeWindow([rule], at: "2026-06-02 07:00"))
        XCTAssertNil(activeWindow([rule], at: "2026-06-01 21:59"))
    }

    func testMultipleWeekdaysAreSupported() throws {
        let rule = NoAjarScheduleRule(id: "mwf", weekdays: [2, 4, 6], startMinute: 10 * 60, endMinute: 11 * 60)

        XCTAssertNotNil(activeWindow([rule], at: "2026-06-01 10:30"))
        XCTAssertNil(activeWindow([rule], at: "2026-06-02 10:30"))
        XCTAssertNotNil(activeWindow([rule], at: "2026-06-03 10:30"))
        XCTAssertNotNil(activeWindow([rule], at: "2026-06-05 10:30"))
    }

    func testOverlappingRulesAreRejected() {
        let first = NoAjarScheduleRule(id: "first", weekdays: [2], startMinute: 9 * 60, endMinute: 12 * 60)
        let second = NoAjarScheduleRule(id: "second", weekdays: [2], startMinute: 11 * 60, endMinute: 13 * 60)

        XCTAssertEqual(NoAjarScheduleEvaluator.overlappingRuleIDs([first, second]), ["first", "second"])
    }

    func testAdjacentRulesAreAllowed() {
        let first = NoAjarScheduleRule(id: "first", weekdays: [2], startMinute: 9 * 60, endMinute: 12 * 60)
        let second = NoAjarScheduleRule(id: "second", weekdays: [2], startMinute: 12 * 60, endMinute: 18 * 60)

        XCTAssertTrue(NoAjarScheduleEvaluator.overlappingRuleIDs([first, second]).isEmpty)
    }

    func testSuppressionSkipsOnlyCurrentWindow() throws {
        let rule = NoAjarScheduleRule(id: "workday", weekdays: [2, 3], startMinute: 9 * 60, endMinute: 18 * 60)
        let active = try XCTUnwrap(activeWindow([rule], at: "2026-06-01 10:00"))
        let suppression = NoAjarScheduleSuppression(ruleID: rule.id, windowEnd: active.end)

        XCTAssertNil(activeWindow([rule], suppressions: [suppression], at: "2026-06-01 11:00"))
        XCTAssertNotNil(activeWindow([rule], suppressions: [suppression], at: "2026-06-02 10:00"))
    }

    func testDecodingOldRuleDefaultsHotspotOff() throws {
        let json = """
        {
          "id": "legacy",
          "enabled": true,
          "mode": "noAjar",
          "weekdays": [2],
          "startMinute": 540,
          "endMinute": 1080
        }
        """

        let rule = try JSONDecoder().decode(NoAjarScheduleRule.self, from: Data(json.utf8))

        XCTAssertFalse(rule.keepHotspotConnected)
    }

    private func activeWindow(
        _ rules: [NoAjarScheduleRule],
        suppressions: [NoAjarScheduleSuppression] = [],
        at rawDate: String
    ) -> NoAjarScheduleWindow? {
        NoAjarScheduleEvaluator.activeWindow(
            rules: rules,
            suppressions: suppressions,
            at: date(rawDate),
            calendar: calendar
        )
    }

    private func date(_ raw: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: raw)!
    }
}
