import SwiftUI

@MainActor
struct MobileCalendarView: View {
    let onOpenTask: (UUID) -> Void
    let onAddTask: (Date?, UUID?) -> Void
    let onOpenSync: () -> Void

    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.calendar) private var calendar
    @Environment(\.mobileAppearance) private var appearance
    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    @State private var period = CalendarPeriod.month
    @State private var showUnscheduled = true
    @ScaledMetric(relativeTo: .body) private var dayDiameter: CGFloat = 28

    private var minimumDayWidth: CGFloat { max(44, dayDiameter + 8) }
    private var minimumGridWidth: CGFloat { minimumDayWidth * 7 }
    private var usesNativeGlass: Bool {
        if #available(iOS 26.0, *) {
            return appearance.usesGlass
        }
        return false
    }

    var body: some View {
        Group {
            if usesNativeGlass {
                calendarContent
                    .navigationTitle(L("日历"))
                    .navigationBarTitleDisplayMode(.inline)
            } else {
                calendarContent
            }
        }
        .toolbar {
            if #available(iOS 26.0, *), appearance.usesGlass {
                MobilePageToolbar(
                    addTitle: L("新建任务"),
                    onAdd: { onAddTask(selectedDate, nil) },
                    onSync: onOpenSync
                )
            }
        }
    }

    private var calendarContent: some View {
        let tasks = store.data.tasks
        let grouped = CalendarLayout.tasksByDay(tasks, calendar: calendar)
        let days = CalendarLayout.days(containing: selectedDate, period: period, calendar: calendar)
        let selectedDay = calendar.startOfDay(for: selectedDate)

        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !usesNativeGlass {
                    MobilePageHeader(
                        title: L("日历"),
                        onAdd: { onAddTask(selectedDate, nil) },
                        onSync: onOpenSync
                    )
                }
                VStack(alignment: .leading, spacing: 8) {
                    periodControls(days: days)
                    HStack(spacing: 12) {
                        periodSelector
                        MobileChromeButton(title: L("今天")) { selectDay(.now) }
                            .accessibilityIdentifier("calendar-today")
                            .accessibilityLabel(L("返回今天"))
                    }
                }
                ViewThatFits(in: .horizontal) {
                    calendarGrid(days: days, grouped: grouped)
                    ScrollView(.horizontal) {
                        calendarGrid(days: days, grouped: grouped)
                            .frame(width: minimumGridWidth)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                }
                Style.separator.frame(height: 1)
                agenda(tasks: grouped[selectedDay, default: []])
                Style.separator.frame(height: 1)
                unscheduled(tasks: CalendarLayout.undated(tasks))
            }
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if usesNativeGlass {
                Style.background
            } else {
                Style.background.ignoresSafeArea()
            }
        }
        .foregroundStyle(Style.ink)
        .font(Style.font(17))
    }

    private func periodControls(days: [Date]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                periodHeading(days: days)
                    .fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 0)
                periodNavigation
                    .fixedSize(horizontal: true, vertical: true)
            }
            VStack(alignment: .leading, spacing: 12) {
                periodHeading(days: days)
                periodNavigation
            }
        }
    }

    private func periodHeading(days: [Date]) -> some View {
        Text(periodTitle(days: days))
            .font(Style.font(20, bold: true))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("calendar-period-title")
            .accessibilityLabel(periodAccessibilityTitle(days: days))
    }

    private var periodNavigation: some View {
        ViewThatFits(in: .horizontal) {
            navigationButtons
            ScrollView(.horizontal) {
                navigationButtons
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 8) {
            MobileChromeButton(title: L(period == .month ? "上个月" : "上一周"), symbol: "chevron.left") {
                movePeriod(by: -1)
            }
            .accessibilityIdentifier("calendar-previous")
            MobileChromeButton(title: L(period == .month ? "下个月" : "下一周"), symbol: "chevron.right") {
                movePeriod(by: 1)
            }
            .accessibilityIdentifier("calendar-next")
        }
        .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder
    private var periodSelector: some View {
        if usesNativeGlass {
            Picker(L("日历"), selection: $period) {
                ForEach(CalendarPeriod.allCases, id: \.self) { value in
                    Text(L(value == .month ? "月" : "周"))
                        .tag(value)
                        .accessibilityIdentifier(value == .month ? "calendar-month" : "calendar-week")
                }
            }
            .pickerStyle(.segmented).controlSize(.large).tint(nil)
            .frame(minHeight: 44)
            .accessibilityIdentifier("calendar-period-picker")
        } else {
            HStack(spacing: 4) {
                ForEach(CalendarPeriod.allCases, id: \.self) { value in
                    Button { period = value } label: {
                        Text(L(value == .month ? "月" : "周"))
                            .font(Style.font(16, bold: period == value))
                            .foregroundStyle(period == value ? Style.accentInk : Style.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(period == value ? Style.selection : Color.clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(value == .month ? "calendar-month" : "calendar-week")
                    .accessibilityLabel(L(value == .month ? "按月显示" : "按周显示"))
                    .accessibilityAddTraits(period == value ? .isSelected : [])
                }
            }
            .padding(4)
            .accessibilityElement(children: .contain)
        }
    }

    private func calendarGrid(days: [Date], grouped: [Date: [Todo]]) -> some View {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = calendar
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(minimum: minimumDayWidth), spacing: 0), count: 7),
            spacing: 0
        ) {
            ForEach([1, 2, 3, 4, 5, 6, 0], id: \.self) { index in
                Text(formatter.shortStandaloneWeekdaySymbols[index])
                    .font(Style.font(13))
                    .foregroundStyle(Style.secondaryText)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(formatter.standaloneWeekdaySymbols[index])
            }
            ForEach(days, id: \.self) { date in
                dayCell(date, tasks: grouped[date, default: []])
            }
        }
        .frame(minWidth: minimumGridWidth)
    }

    private func dayCell(_ date: Date, tasks: [Todo]) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
        let today = calendar.isDateInToday(date)
        let inMonth = calendar.isDate(date, equalTo: selectedDate, toGranularity: .month)
        let dateLabel = dateText(date, format: L10n.dateFormat("yyyy年M月d日 EEEE", "EEEE, MMMM d, yyyy"))

        return Button { selectDay(date) } label: {
            VStack(spacing: 4) {
                Text(calendar.component(.day, from: date).formatted(.number.locale(L10n.locale)))
                    .font(Style.font(16, bold: selected || today))
                    .monospacedDigit()
                    .foregroundStyle(selected ? Style.detail : (inMonth || period == .week ? Style.ink : Style.mutedText))
                    .frame(width: dayDiameter, height: dayDiameter)
                    .background(selected ? Style.accent : Color.clear, in: Circle())
                    .overlay {
                        Circle().strokeBorder(today && !selected ? Style.secondaryText : Color.clear, lineWidth: 1)
                    }
                HStack(spacing: 4) {
                    ForEach(0..<min(tasks.count, 3), id: \.self) { _ in
                        Circle().fill(selected ? Style.accent : Style.mutedText).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar-day-\(SyncDay.key(date, timeZone: calendar.timeZone))")
        .accessibilityLabel(today ? LF("%@，今天", dateLabel) : dateLabel)
        .accessibilityValue(taskSummary(tasks))
        .accessibilityHint(L("选择日期，查看当天全部任务"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func agenda(tasks: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(dateText(selectedDate, format: L10n.dateFormat("M月d日 · EEEE", "MMMM d · EEEE")))
                    .font(Style.font(17, bold: true))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityLabel(dateText(selectedDate, format: L10n.dateFormat("yyyy年M月d日 EEEE", "EEEE, MMMM d, yyyy")))
                summary(tasks)
            }
            if tasks.isEmpty {
                Text(L("这一天没有安排任务"))
                    .foregroundStyle(Style.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
            } else {
                taskRows(tasks)
            }
        }
    }

    private func unscheduled(tasks: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        unscheduledToggle(taskCount: tasks.count)
                            .fixedSize(horizontal: true, vertical: true)
                        Spacer(minLength: 0)
                        addUnscheduledButton
                            .fixedSize(horizontal: true, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        unscheduledToggle(taskCount: tasks.count)
                        addUnscheduledButton
                    }
                }
                summary(tasks)
            }
            if showUnscheduled {
                if tasks.isEmpty {
                    Text(L("未安排日期的任务会显示在这里"))
                        .foregroundStyle(Style.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 12)
                } else {
                    taskRows(tasks)
                }
            }
        }
    }

    private func unscheduledToggle(taskCount: Int) -> some View {
        Button { showUnscheduled.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: showUnscheduled ? "chevron.down" : "chevron.right")
                    .font(Style.font(12, bold: true))
                    .foregroundStyle(Style.secondaryText)
                Text(L("未安排日期"))
                    .font(Style.font(17, bold: true))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 8)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("calendar-unscheduled-toggle")
        .accessibilityLabel(LF("未安排日期，%ld 项任务", taskCount))
        .accessibilityValue(L(showUnscheduled ? "已展开" : "已折叠"))
        .accessibilityHint(L(showUnscheduled ? "折叠未安排日期的任务" : "展开全部未安排日期的任务"))
    }

    private var addUnscheduledButton: some View {
        MobileChromeButton(title: L("添加任务")) {
            showUnscheduled = true
            onAddTask(nil, nil)
        }
        .accessibilityIdentifier("calendar-add-unscheduled")
        .accessibilityLabel(L("新建未安排日期的任务"))
    }

    private func taskRows(_ tasks: [Todo]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(tasks) { task in
                MobileTaskRow(task: task, onOpen: { onOpenTask(task.id) })
            }
        }
    }

    private func summary(_ tasks: [Todo]) -> some View {
        Text(taskSummary(tasks))
            .font(Style.font(13))
            .foregroundStyle(Style.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func taskSummary(_ tasks: [Todo]) -> String {
        let completed = tasks.filter { $0.completedAt != nil }.count
        return LF("%ld 项任务 · 待完成 %ld · 已完成 %ld", tasks.count, tasks.count - completed, completed)
    }

    private func selectDay(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
    }

    private func movePeriod(by amount: Int) {
        selectDay(CalendarLayout.shift(selectedDate, by: amount, period: period, calendar: calendar))
    }

    private func periodTitle(days: [Date]) -> String {
        guard period == .week, let first = days.first, let last = days.last else {
            return dateText(selectedDate, format: L10n.dateFormat("yyyy年M月", "MMMM yyyy"))
        }
        let sameYear = calendar.isDate(first, equalTo: last, toGranularity: .year)
        let start = dateText(first, format: L10n.dateFormat("yyyy/M/d", "MMM d, yyyy"))
        let end = dateText(last, format: sameYear ? L10n.dateFormat("M/d", "MMM d") : L10n.dateFormat("yyyy/M/d", "MMM d, yyyy"))
        return LF("%@ – %@", start, end)
    }

    private func periodAccessibilityTitle(days: [Date]) -> String {
        guard period == .week, let first = days.first, let last = days.last else {
            return dateText(selectedDate, format: L10n.dateFormat("yyyy年M月", "MMMM yyyy"))
        }
        let format = L10n.dateFormat("yyyy年M月d日", "MMMM d, yyyy")
        return LF("%@至%@", dateText(first, format: format), dateText(last, format: format))
    }

    private func dateText(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
