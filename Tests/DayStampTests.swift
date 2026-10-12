import XCTest
@testable import LocalChecklist

final class DayStampTests: XCTestCase {
    func testLeapAndMalformedDaysAreStrictlyValidated() {
        for invalid in ["2025-02-29", "1900-02-29", "2026-04-31", "2026-13-01", "2026-00-01", "2026-01-00", "0000-01-01", "2026-1-01", "26-01-01", "2026-01-01T12:00:00Z", "２０２６-01-01"] {
            XCTAssertNil(DayStamp(rawValue: invalid), invalid)
        }
        for valid in ["0001-01-01", "2000-02-29", "2024-02-29", "9999-12-31"] {
            XCTAssertNotNil(DayStamp(rawValue: valid), valid)
        }
    }

    func testDayDifferenceUsesCivilDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let spring = DayStamp(rawValue: "2026-03-08")!
        let afterSpring = DayStamp(rawValue: "2026-03-09")!
        XCTAssertEqual(dayDifference(from: spring, to: afterSpring, calendar: calendar), 1)
        XCTAssertEqual(try XCTUnwrap(afterSpring.date(in: calendar)).timeIntervalSince(XCTUnwrap(spring.date(in: calendar))), 23 * 3600, accuracy: 1)
        let autumn = DayStamp(rawValue: "2026-11-01")!
        let afterAutumn = DayStamp(rawValue: "2026-11-02")!
        XCTAssertEqual(dayDifference(from: autumn, to: afterAutumn, calendar: calendar), 1)
        XCTAssertEqual(try XCTUnwrap(afterAutumn.date(in: calendar)).timeIntervalSince(XCTUnwrap(autumn.date(in: calendar))), 25 * 3600, accuracy: 1)
        XCTAssertEqual(dayDifference(from: afterAutumn, to: autumn), -1)
    }

    func testLeapAndHistoricalCalendarArithmetic() {
        XCTAssertEqual(dayDifference(from: DayStamp(rawValue: "2024-02-28")!, to: DayStamp(rawValue: "2024-03-01")!), 2)
        XCTAssertEqual(dayDifference(from: DayStamp(rawValue: "2025-02-28")!, to: DayStamp(rawValue: "2025-03-01")!), 1)
        XCTAssertEqual(dayDifference(from: DayStamp(rawValue: "1582-10-04")!, to: DayStamp(rawValue: "1582-10-15")!), 11)
        XCTAssertEqual(dayDifference(from: DayStamp(rawValue: "0001-01-01")!, to: DayStamp(rawValue: "9999-12-31")!), 3_652_058)
    }

    func testSkippedCivilDayDoesNotNormalizeToAnotherDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Pacific/Apia"))
        XCTAssertNil(DayStamp(rawValue: "2011-12-30")!.date(in: calendar))
        XCTAssertEqual(dayDifference(from: DayStamp(rawValue: "2011-12-29")!, to: DayStamp(rawValue: "2011-12-31")!, calendar: calendar), 2)
    }

    func testGregorianStorageDoesNotChangeWithUserDisplayCalendar() throws {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = DayStamp(rawValue: "2026-10-06")!
        let date = try XCTUnwrap(reference.date(in: calendar))
        XCTAssertEqual(DayStamp(date: date, calendar: calendar), reference)
    }

    func testInclusiveRangeSingleDateUndatedAndDueDay() {
        let first = DayStamp(rawValue: "2026-10-06")!
        let middle = DayStamp(rawValue: "2026-10-07")!
        let last = DayStamp(rawValue: "2026-10-08")!
        let after = DayStamp(rawValue: "2026-10-09")!
        let ranged = TodoItem(title: "Range", startDay: first, endDay: last)
        XCTAssertTrue(ranged.occurs(on: first)); XCTAssertTrue(ranged.occurs(on: middle)); XCTAssertTrue(ranged.occurs(on: last))
        XCTAssertFalse(ranged.occurs(on: after)); XCTAssertEqual(ranged.dueDay, last)
        let onlyStart = TodoItem(title: "Start", startDay: first)
        XCTAssertTrue(onlyStart.occurs(on: first)); XCTAssertFalse(onlyStart.occurs(on: middle)); XCTAssertEqual(onlyStart.dueDay, first)
        let onlyEnd = TodoItem(title: "End", endDay: last)
        XCTAssertTrue(onlyEnd.occurs(on: last)); XCTAssertFalse(onlyEnd.occurs(on: first)); XCTAssertEqual(onlyEnd.dueDay, last)
        XCTAssertFalse(TodoItem(title: "Undated").occurs(on: first))
    }

    func testDayStampCodableRoundTripAndInvalidDecode() throws {
        let day = DayStamp(rawValue: "2024-02-29")!
        let data = try JSONEncoder().encode(day)
        XCTAssertEqual(try JSONDecoder().decode(DayStamp.self, from: data), day)
        XCTAssertThrowsError(try JSONDecoder().decode(DayStamp.self, from: Data("\"2023-02-29\"".utf8)))
    }
}
