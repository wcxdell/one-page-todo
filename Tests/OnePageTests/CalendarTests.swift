import Foundation
import SwiftUI
import XCTest
@testable import OnePage

final class CalendarTests: XCTestCase {
    func testLeapFebruaryIncludesEveryDayAndAdjacentMonths() throws {
        let calendar = try makeCalendar()
        let date = try makeDate(2024, 2, 15, calendar: calendar)
        let days = CalendarLayout.days(containing: date, period: .month, calendar: calendar)

        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(days.first, try makeDate(2024, 1, 29, calendar: calendar))
        XCTAssertEqual(days.last, try makeDate(2024, 3, 3, calendar: calendar))
        XCTAssertTrue(days.contains(try makeDate(2024, 2, 29, calendar: calendar)))
        XCTAssertEqual(days.filter { calendar.isDate($0, equalTo: date, toGranularity: .month) }.count, 29)
        XCTAssertTrue(days.allSatisfy { $0 == calendar.startOfDay(for: $0) })
    }

    func testMonthGridsUseFourFiveOrSixCompleteMondayFirstWeeks() throws {
        let calendar = try makeCalendar()
        let cases = [
            (date: try makeDate(2021, 2, 12, calendar: calendar), count: 28,
             first: try makeDate(2021, 2, 1, calendar: calendar), last: try makeDate(2021, 2, 28, calendar: calendar)),
            (date: try makeDate(2024, 4, 12, calendar: calendar), count: 35,
             first: try makeDate(2024, 4, 1, calendar: calendar), last: try makeDate(2024, 5, 5, calendar: calendar)),
            (date: try makeDate(2024, 9, 12, calendar: calendar), count: 42,
             first: try makeDate(2024, 8, 26, calendar: calendar), last: try makeDate(2024, 10, 6, calendar: calendar)),
            (date: try makeDate(2025, 12, 12, calendar: calendar), count: 35,
             first: try makeDate(2025, 12, 1, calendar: calendar), last: try makeDate(2026, 1, 4, calendar: calendar))
        ]

        for item in cases {
            let days = CalendarLayout.days(containing: item.date, period: .month, calendar: calendar)
            XCTAssertEqual(days.count, item.count)
            XCTAssertEqual(days.first, item.first)
            XCTAssertEqual(days.last, item.last)
            XCTAssertEqual(Set(days).count, days.count)
            for (index, day) in days.enumerated() {
                XCTAssertEqual(calendar.component(.weekday, from: day), (index + 1) % 7 + 1)
            }
        }
    }

    func testWeekStartsMondayAcrossYearDespiteSundayFirstCalendar() throws {
        let calendar = try makeCalendar()
        XCTAssertEqual(calendar.firstWeekday, 1)
        let date = try makeDate(2026, 1, 1, hour: 18, calendar: calendar)
        let days = CalendarLayout.days(containing: date, period: .week, calendar: calendar)

        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first, try makeDate(2025, 12, 29, calendar: calendar))
        XCTAssertEqual(days.last, try makeDate(2026, 1, 4, calendar: calendar))
        XCTAssertEqual(days.map { calendar.component(.weekday, from: $0) }, [2, 3, 4, 5, 6, 7, 1])
        XCTAssertTrue(days.allSatisfy { $0 == calendar.startOfDay(for: $0) })
    }

    func testMonthShiftsClampShortMonthsAndCrossYears() throws {
        let calendar = try makeCalendar()
        let cases = [
            (from: try makeDate(2024, 1, 31, hour: 15, calendar: calendar), amount: 1,
             to: try makeDate(2024, 2, 29, calendar: calendar)),
            (from: try makeDate(2023, 1, 31, calendar: calendar), amount: 1,
             to: try makeDate(2023, 2, 28, calendar: calendar)),
            (from: try makeDate(2024, 3, 31, calendar: calendar), amount: -1,
             to: try makeDate(2024, 2, 29, calendar: calendar)),
            (from: try makeDate(2024, 12, 31, calendar: calendar), amount: 1,
             to: try makeDate(2025, 1, 31, calendar: calendar)),
            (from: try makeDate(2025, 1, 31, calendar: calendar), amount: -1,
             to: try makeDate(2024, 12, 31, calendar: calendar))
        ]

        for item in cases {
            XCTAssertEqual(CalendarLayout.shift(item.from, by: item.amount, period: .month, calendar: calendar), item.to)
        }
    }

    func testWeekShiftsCrossYearInBothDirections() throws {
        let calendar = try makeCalendar()
        let before = try makeDate(2025, 12, 29, calendar: calendar)
        let after = try makeDate(2026, 1, 5, calendar: calendar)

        XCTAssertEqual(CalendarLayout.shift(before, by: 1, period: .week, calendar: calendar), after)
        XCTAssertEqual(CalendarLayout.shift(after, by: -1, period: .week, calendar: calendar), before)
    }

    func testDSTMonthGridsContainUniqueConsecutiveLocalDays() throws {
        let calendar = try makeCalendar("America/Los_Angeles")
        for month in [3, 11] {
            let date = try makeDate(2024, month, 15, calendar: calendar)
            let days = CalendarLayout.days(containing: date, period: .month, calendar: calendar)
            XCTAssertEqual(days.count, 35)
            XCTAssertEqual(Set(days).count, days.count)
            XCTAssertTrue(days.allSatisfy { $0 == calendar.startOfDay(for: $0) })
            for (previous, next) in zip(days, days.dropFirst()) {
                XCTAssertEqual(calendar.date(byAdding: .day, value: 1, to: previous), next)
            }
        }

        let spring = try makeDate(2024, 3, 10, calendar: calendar)
        let springNext = try makeDate(2024, 3, 11, calendar: calendar)
        let autumn = try makeDate(2024, 11, 3, calendar: calendar)
        let autumnNext = try makeDate(2024, 11, 4, calendar: calendar)
        XCTAssertEqual(springNext.timeIntervalSince(spring), 23 * 60 * 60)
        XCTAssertEqual(autumnNext.timeIntervalSince(autumn), 25 * 60 * 60)
    }

    func testWeekShiftsAcrossBothDSTTransitionsKeepLocalMidnight() throws {
        let calendar = try makeCalendar("America/Los_Angeles")
        let cases = [
            (before: try makeDate(2024, 3, 4, hour: 18, calendar: calendar),
             after: try makeDate(2024, 3, 11, calendar: calendar)),
            (before: try makeDate(2024, 10, 28, hour: 18, calendar: calendar),
             after: try makeDate(2024, 11, 4, calendar: calendar))
        ]

        for item in cases {
            let start = calendar.startOfDay(for: item.before)
            let shifted = CalendarLayout.shift(item.before, by: 1, period: .week, calendar: calendar)
            XCTAssertEqual(shifted, item.after)
            XCTAssertEqual(CalendarLayout.shift(shifted, by: -1, period: .week, calendar: calendar), start)
            let days = CalendarLayout.days(containing: item.before, period: .week, calendar: calendar)
            let nextDays = CalendarLayout.days(containing: shifted, period: .week, calendar: calendar)
            XCTAssertEqual(days.count, 7)
            XCTAssertEqual(nextDays.count, 7)
            XCTAssertEqual(Set(days + nextDays).count, 14)
            XCTAssertEqual(nextDays.first, shifted)
            for (previous, next) in zip(days + nextDays, (days + nextDays).dropFirst()) {
                XCTAssertEqual(calendar.date(byAdding: .day, value: 1, to: previous), next)
            }
        }
    }

    func testGroupingNormalizesDatesAndKeepsCompletedTasksOnAssignedDay() throws {
        let calendar = try makeCalendar("America/Los_Angeles")
        let day = try makeDate(2024, 5, 10, calendar: calendar)
        let completion = try makeDate(2024, 5, 12, hour: 9, calendar: calendar)
        let tasks = [
            makeTask("上午任务", date: try makeDate(2024, 5, 10, hour: 8, minute: 15, calendar: calendar)),
            makeTask("已完成任务", date: try makeDate(2024, 5, 10, hour: 13, calendar: calendar), completedAt: completion),
            makeTask("晚上任务", date: try makeDate(2024, 5, 10, hour: 23, minute: 45, calendar: calendar))
        ]
        let grouped = CalendarLayout.tasksByDay(tasks, calendar: calendar)

        XCTAssertEqual(Set(grouped.keys), Set([day]))
        XCTAssertEqual(grouped[day], tasks)
        XCTAssertNil(grouped[calendar.startOfDay(for: completion)])
        XCTAssertTrue(CalendarLayout.undated(tasks).isEmpty)
    }

    func testUndatedTasksNeverUseCreationCompletionOrReferenceToday() throws {
        let calendar = try makeCalendar()
        let referenceToday = try makeDate(2032, 2, 20, calendar: calendar)
        var pending = makeTask("未安排", date: nil)
        pending.createdAt = referenceToday
        let completed = makeTask("已完成但未安排", date: nil, completedAt: referenceToday)
        let dated = makeTask("已安排", date: referenceToday)
        let tasks = [pending, completed, dated]
        let grouped = CalendarLayout.tasksByDay(tasks, calendar: calendar)

        XCTAssertEqual(grouped[referenceToday], [dated])
        XCTAssertEqual(CalendarLayout.undated(tasks), [pending, completed])
        XCTAssertTrue(CalendarLayout.tasksByDay([pending, completed], calendar: calendar).isEmpty)
    }

    func testRepeatedDSTHourAndDuplicateTitlesRetainBothTasks() throws {
        let calendar = try makeCalendar("America/Los_Angeles")
        let formatter = ISO8601DateFormatter()
        let firstHour = try XCTUnwrap(formatter.date(from: "2024-11-03T01:30:00-07:00"))
        let secondHour = try XCTUnwrap(formatter.date(from: "2024-11-03T01:30:00-08:00"))
        let day = try makeDate(2024, 11, 3, calendar: calendar)
        let tasks = [makeTask("重复标题", date: firstHour), makeTask("重复标题", date: secondHour)]
        let grouped = CalendarLayout.tasksByDay(tasks, calendar: calendar)

        XCTAssertNotEqual(firstHour, secondHour)
        XCTAssertNotEqual(tasks[0].id, tasks[1].id)
        XCTAssertEqual(grouped.count, 1)
        XCTAssertEqual(grouped[day]?.map(\.id), tasks.map(\.id))
    }

    func testRecomputingGroupingMovesOnlyTheEditedTask() throws {
        let calendar = try makeCalendar()
        let oldDay = try makeDate(2024, 12, 31, calendar: calendar)
        let newDay = try makeDate(2025, 1, 1, calendar: calendar)
        var tasks = [makeTask("改期", date: oldDay), makeTask("保留", date: oldDay), makeTask("未安排", date: nil)]
        let original = CalendarLayout.tasksByDay(tasks, calendar: calendar)
        tasks[0].date = try makeDate(2025, 1, 1, hour: 15, calendar: calendar)
        let moved = CalendarLayout.tasksByDay(tasks, calendar: calendar)

        XCTAssertEqual(original[oldDay]?.map(\.id), [tasks[0].id, tasks[1].id])
        XCTAssertEqual(moved[oldDay]?.map(\.id), [tasks[1].id])
        XCTAssertEqual(moved[newDay]?.map(\.id), [tasks[0].id])
        tasks[0].date = nil
        XCTAssertNil(CalendarLayout.tasksByDay(tasks, calendar: calendar)[newDay])
        XCTAssertEqual(CalendarLayout.undated(tasks).map(\.id), [tasks[0].id, tasks[2].id])
    }

    @MainActor func testStoreEditsAndCompletionRegroupUsingOnlyRetainedTemporaryFixture() throws {
        let calendar = try makeCalendar()
        let oldDay = try makeDate(2024, 6, 12, calendar: calendar)
        let newDay = try makeDate(2024, 7, 1, calendar: calendar)
        let dated = makeTask("已安排", date: oldDay)
        let undated = makeTask("未安排", date: nil)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwenwork", isDirectory: true)
            .appendingPathComponent("CalendarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("tasks.json")
        try JSONEncoder().encode(SavedData(tasks: [dated, undated], groups: [])).write(to: fileURL)
        let store = Store(fileURL: fileURL)

        XCTAssertNil(store.error)
        store.toggle(dated.id)
        XCTAssertNotNil(store.data.tasks.first?.completedAt)
        XCTAssertEqual(CalendarLayout.tasksByDay(store.data.tasks, calendar: calendar)[oldDay]?.map(\.id), [dated.id])
        store.update(dated.id) { $0.date = newDay; $0.title = "已改期" }
        let moved = CalendarLayout.tasksByDay(store.data.tasks, calendar: calendar)
        XCTAssertNil(moved[oldDay])
        XCTAssertEqual(moved[newDay]?.first?.title, "已改期")
        XCTAssertNotNil(moved[newDay]?.first?.completedAt)
        store.update(dated.id) { $0.date = nil }
        XCTAssertTrue(CalendarLayout.tasksByDay(store.data.tasks, calendar: calendar).isEmpty)
        XCTAssertEqual(CalendarLayout.undated(store.data.tasks).map(\.id), [dated.id, undated.id])
        XCTAssertNil(store.error)
        let retained = try JSONDecoder().decode(SavedData.self, from: Data(contentsOf: fileURL))
        XCTAssertEqual(retained, store.data)
    }

    @MainActor func testViewAcceptsParentBindingsInRequiredOrder() throws {
        let calendar = try makeCalendar()
        let day = try makeDate(2024, 5, 10, calendar: calendar)
        let id = UUID()
        let view = TaskCalendarView(selectedDate: .constant(day), selectedTaskID: .constant(id), period: .constant(.week), addTask: { _ in })

        XCTAssertEqual(view.selectedDate, day)
        XCTAssertEqual(view.selectedTaskID, id)
        XCTAssertEqual(view.period, .week)
    }

    private func makeCalendar(_ timeZone: String = "UTC") throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZone))
        calendar.firstWeekday = 1
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, minute: Int = 0, calendar: Calendar) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)))
    }

    private func makeTask(_ title: String, date: Date?, completedAt: Date? = nil) -> Todo {
        Todo(title: title, date: date, completedAt: completedAt, createdAt: Date(timeIntervalSinceReferenceDate: 0))
    }
}
