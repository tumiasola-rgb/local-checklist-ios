import XCTest
import UIKit
@testable import LocalChecklist

final class AppLogicTests: XCTestCase {
    func testAnnualLeapDayUsesNextValidGregorianLeapYear() throws {
        let item = Anniversary(title: "Leap day", day: try XCTUnwrap(DayStamp(rawValue: "2024-02-29")), repeatYearly: true)
        let today = try XCTUnwrap(DayStamp(rawValue: "2025-02-28"))
        XCTAssertEqual(nextAnniversaryDay(item, today: today).rawValue, "2028-02-29")
    }
    func testAnniversaryTodayIsZeroAndPastDateRemainsPast() throws {
        let today = try XCTUnwrap(DayStamp(rawValue: "2026-10-06"))
        let item = Anniversary(title: "Start", day: today, repeatYearly: false)
        XCTAssertEqual(dayDifference(from: today, to: nextAnniversaryDay(item, today: today)), 0)
        let past = Anniversary(title: "Start", day: try XCTUnwrap(DayStamp(rawValue: "2026-10-01")), repeatYearly: false)
        XCTAssertEqual(dayDifference(from: today, to: nextAnniversaryDay(past, today: today)), -5)
    }
    func testAnnualDateDoesNotOccurBeforeItsSelectedStartYear() throws {
        let item = Anniversary(title: "Future", day: try XCTUnwrap(DayStamp(rawValue: "2028-11-01")), repeatYearly: true)
        XCTAssertEqual(nextAnniversaryDay(item, today: try XCTUnwrap(DayStamp(rawValue: "2026-10-06"))).rawValue, "2028-11-01")
    }
    func testTagsDeduplicateCaseInsensitively() {
        XCTAssertEqual(splitTags("work,Work，学习 #学习"), ["work", "学习"])
    }
    func testMonthGridContainsEveryDayAndOnlyWholeWeeks() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        for year in 2024...2030 {
            for month in 1...12 {
                for weekday in 1...7 {
                    let date = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: 15)))
                    let grid = CalendarMonth(date: date, firstWeekday: weekday)
                    XCTAssertEqual(grid.days.count % 7, 0)
                    XCTAssertEqual(calendar.component(.weekday, from: try XCTUnwrap(grid.days.first)), weekday)
                    let inMonth = grid.days.filter { calendar.isDate($0, equalTo: date, toGranularity: .month) }
                    XCTAssertEqual(inMonth.count, calendar.range(of: .day, in: .month, for: date)?.count)
                }
            }
        }
    }
    func testCalendarBoundaryPaddingNeverBecomesOutOfRangeDayStamp() throws {
        for raw in ["0001-01-01", "9999-12-01"] {
            let day = try XCTUnwrap(DayStamp(rawValue: raw))
            let date = try XCTUnwrap(day.date())
            let month = CalendarMonth(date: date, firstWeekday: 1)
            XCTAssertEqual(month.weeks.flatMap { $0 }.count % 7, 0)
            for value in month.weeks.flatMap({ $0 }).compactMap({ $0 }) {
                XCTAssertNotNil(DayStamp(rawValue: DayStamp(date: value).rawValue))
            }
        }
    }

    @MainActor
    func testSharePaginationPreservesUnicodeAndWhitespace() throws {
        let text = String(repeating: "每个字都保留 👨‍👩‍👧‍👦🌈 e\u{301}\n\n", count: 90) + String(repeating: "long-url-without-spaces", count: 70)
        let pages = try ShareImageMaker.pages(text: text)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined(), text)
        XCTAssertFalse(pages.contains(where: \.isEmpty))
    }
    @MainActor
    func testSharePaginationFailsInsteadOfTruncatingOverLimit() {
        XCTAssertThrowsError(try ShareImageMaker.pages(text: String(repeating: "\n", count: 10_000), width: 100, height: 60))
    }
}
