import Foundation

enum CalendarPeriod: String, CaseIterable {
    case month, week
}

enum CalendarLayout {
    static func days(containing date: Date, period: CalendarPeriod, calendar: Calendar = .current) -> [Date] {
        let anchor: Date
        let dayCount: Int
        switch period {
        case .month:
            guard let interval = calendar.dateInterval(of: .month, for: date),
                  let range = calendar.range(of: .day, in: .month, for: date) else { return [] }
            anchor = calendar.startOfDay(for: interval.start)
            dayCount = range.count
        case .week:
            anchor = calendar.startOfDay(for: date)
            dayCount = 7
        }
        let leading = (calendar.component(.weekday, from: anchor) + 5) % 7
        guard let start = calendar.date(byAdding: .day, value: -leading, to: anchor) else { return [] }
        let count = period == .month ? ((leading + dayCount + 6) / 7) * 7 : 7
        return (0..<count).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: start).map { calendar.startOfDay(for: $0) }
        }
    }

    static func shift(_ date: Date, by amount: Int, period: CalendarPeriod, calendar: Calendar = .current) -> Date {
        let component: Calendar.Component = period == .month ? .month : .weekOfYear
        let start = calendar.startOfDay(for: date)
        let shifted = calendar.date(byAdding: component, value: amount, to: start) ?? start
        return calendar.startOfDay(for: shifted)
    }

    static func tasksByDay(_ tasks: [Todo], calendar: Calendar = .current) -> [Date: [Todo]] {
        tasks.reduce(into: [:]) { result, task in
            guard let date = task.date else { return }
            result[calendar.startOfDay(for: date), default: []].append(task)
        }
    }

    static func undated(_ tasks: [Todo]) -> [Todo] {
        tasks.filter { $0.date == nil }
    }
}
