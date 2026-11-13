import SwiftUI

private struct CalendarScrollPosition: Equatable {
    let period: CalendarPeriod
    let days: [Date]
    let request: Int
}

@MainActor
struct TaskCalendarView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @EnvironmentObject var store: Store
    @Binding var selectedDate: Date
    @Binding var selectedTaskID: UUID?
    @Binding var period: CalendarPeriod
    let addTask: (Date?) -> Void

    @Environment(\.calendar) private var calendar
    @State private var showUnscheduled = true
    @State private var scrollRequest = 0
    @State private var showAgendaOnScroll = false

    private var selectedTaskDate: Date? {
        store.data.tasks.first { $0.id == selectedTaskID }?.date
    }

    var body: some View {
        let tasks = store.data.tasks
        let grouped = CalendarLayout.tasksByDay(tasks, calendar: calendar)
        let days = CalendarLayout.days(containing: selectedDate, period: period, calendar: calendar)
        let selectedDay = calendar.startOfDay(for: selectedDate)
        let scrollPosition = CalendarScrollPosition(period: period, days: days, request: scrollRequest)
        return GeometryReader { geometry in
            let weeks = max(1, days.count / 7)
            let cellHeight: CGFloat = period == .month
                ? max(54, min(82, (geometry.size.height - 420) / CGFloat(weeks))) : 280
            VStack(alignment: .leading, spacing: 16) {
                header
                periodControls(days: days)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            calendarGrid(days: days, grouped: grouped, cellHeight: cellHeight)
                                .id("task-calendar-grid")
                            agenda(tasks: grouped[selectedDay, default: []])
                                .id("task-calendar-agenda")
                            unscheduled(tasks: CalendarLayout.undated(tasks))
                        }
                        .padding(.bottom, 28)
                    }
                    .onChange(of: scrollPosition) { previous, current in
                        let target = previous.request != current.request && showAgendaOnScroll
                            ? "task-calendar-agenda" : "task-calendar-grid"
                        withAnimation { proxy.scrollTo(target, anchor: .top) }
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 52)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Style.background)
        .foregroundStyle(Style.ink)
        .font(Style.font(12))
        .tint(Style.accent)
        .environment(\.locale, language.locale)
        .onChange(of: selectedTaskDate) { _, date in
            guard selectedTaskID != nil else { return }
            if let date {
                selectedDate = calendar.startOfDay(for: date)
            } else {
                showUnscheduled = true
            }
        }
    }

    private var header: some View {
        HStack {
            Text(L("日历")).font(Style.font(28, bold: true)).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 16)
            Button { addTask(selectedDate) } label: {
                Label(L("新建任务"), systemImage: "plus")
                    .font(Style.font(12, bold: true))
                    .foregroundStyle(Style.background)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Style.accent, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).fixedSize()
            .help(L("在所选日期新建任务"))
        }
    }

    private func periodControls(days: [Date]) -> some View {
        HStack(spacing: 12) {
            Text(periodTitle(days: days))
                .font(Style.font(17, bold: true))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            Picker(L("日历显示范围"), selection: $period) {
                ForEach(CalendarPeriod.allCases, id: \.self) { value in
                    Text(L(value == .month ? "月" : "周")).tag(value)
                }
            }
            .pickerStyle(.segmented).labelsHidden()
            .frame(width: language.effectiveLanguage == .english ? 126 : 90)
            HStack(spacing: 4) {
                Button { movePeriod(by: -1) } label: {
                    Image(systemName: "chevron.left").frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .help(L(period == .month ? "上个月" : "上一周"))
                .accessibilityLabel(L(period == .month ? "上个月" : "上一周"))
                Button { selectDay(Date()) } label: {
                    Text(L("今天")).padding(.horizontal, 10).frame(height: 28)
                        .background(Style.buttonFill, in: RoundedRectangle(cornerRadius: 6))
                }
                .help(L("返回今天"))
                Button { movePeriod(by: 1) } label: {
                    Image(systemName: "chevron.right").frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .help(L(period == .month ? "下个月" : "下一周"))
                .accessibilityLabel(L(period == .month ? "下个月" : "下一周"))
            }
            .buttonStyle(.plain).foregroundStyle(Style.ink).fixedSize()
        }
    }

    private func calendarGrid(days: [Date], grouped: [Date: [Todo]], cellHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(["周一", "周二", "周三", "周四", "周五", "周六", "周日"], id: \.self) { name in
                    Text(L(name)).font(Style.font(12)).foregroundStyle(Style.secondaryText)
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                }
            }
            Style.separator.frame(height: 1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 7), spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element) { index, date in
                    dayCell(date, tasks: grouped[date, default: []], cellHeight: cellHeight)
                        .overlay(alignment: .bottom) { Style.separator.frame(height: 1) }
                        .overlay(alignment: .trailing) {
                            if index % 7 != 6 { Style.separator.frame(width: 1) }
                        }
                }
            }
            Text(L("点击日期查看当天全部任务"))
                .font(Style.font(11)).foregroundStyle(Style.mutedText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
        }
    }

    private func dayCell(_ date: Date, tasks: [Todo], cellHeight: CGFloat) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
        let today = calendar.isDateInToday(date)
        let inMonth = calendar.isDate(date, equalTo: selectedDate, toGranularity: .month)
        let previewLimit = period == .month ? (cellHeight >= 82 ? 2 : (cellHeight >= 58 ? 1 : 0)) : 5
        let previewCount = min(tasks.count, previewLimit)
        let previewHeight = CGFloat(previewCount) * (period == .month ? 18 : 40) + CGFloat(max(0, previewCount - 1)) * 2
        let contentHeight: CGFloat = 36 + (previewCount > 0 ? previewHeight + 4 : 0)
        let showOverflow = tasks.count > previewCount && cellHeight >= contentHeight + 22
        let label = dateText(date, format: "yyyy年M月d日 EEEE", english: "EEEE, MMM d, yyyy")
        return VStack(alignment: .leading, spacing: 0) {
            Button { selectDay(date, showAgenda: true) } label: {
                HStack(spacing: 2) {
                    Text(period == .month ? calendar.component(.day, from: date).formatted(.number.locale(language.locale)) : dateText(date, format: "M/d", english: "M/d"))
                        .font(Style.font(12, bold: selected || today))
                        .foregroundStyle(selected ? Style.detail : (today ? Style.accent : (inMonth || period == .week ? Style.ink : Style.mutedText)))
                        .padding(.horizontal, 5).frame(minWidth: 26).frame(height: 24)
                        .background(selected ? Style.accent : .clear, in: RoundedRectangle(cornerRadius: period == .month ? 12 : 6))
                    Spacer(minLength: 0)
                    if !tasks.isEmpty {
                        Text(tasks.count, format: .number).font(Style.font(9)).monospacedDigit()
                            .foregroundStyle(Style.mutedText).lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                .frame(height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(LF("%@，共 %ld 项任务", label, tasks.count))
            .accessibilityLabel(LF("%@，共 %ld 项任务", label, tasks.count))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(L("选择日期，查看当天全部任务"))
            .contextMenu {
                Button(L("在这天新建任务")) { selectDay(date); addTask(date) }
            }
            if previewCount > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(tasks.prefix(previewCount))) { task in taskPreview(task) }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
            if showOverflow {
                Button { selectDay(date, showAgenda: true) } label: {
                    Text(LF("+%ld 项", tasks.count - previewCount))
                        .font(Style.font(10)).foregroundStyle(Style.accentInk)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.top, 4)
                .help(LF("查看这一天的全部 %ld 项任务", tasks.count))
                .accessibilityLabel(LF("%@，另有 %ld 项，查看全部 %ld 项任务", label, tasks.count - previewCount, tasks.count))
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: cellHeight, alignment: .topLeading)
        .background(selected ? Style.selection.opacity(0.55) : (calendar.isDateInWeekend(date) ? Style.sidebar.opacity(0.4) : .clear))
        .overlay {
            if selected { Rectangle().strokeBorder(Style.accent.opacity(0.55), lineWidth: 1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text(L("选择日期"))) { selectDay(date, showAgenda: true) }
    }

    private func taskPreview(_ task: Todo) -> some View {
        Button { select(task) } label: {
            Text(task.displayTitle)
                .font(Style.font(11)).strikethrough(task.completedAt != nil)
                .foregroundStyle(task.completedAt == nil ? Style.ink : Style.mutedText)
                .multilineTextAlignment(.leading).lineLimit(period == .month ? 1 : 2)
                .padding(.horizontal, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: period == .month ? 18 : 40, alignment: .leading)
                .background(selectedTaskID == task.id ? Style.selection : Style.sidebar.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(selectedTaskID == task.id ? Style.accent : Style.mutedText.opacity(0.5))
                        .frame(width: 2).padding(.vertical, 3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(task.displayTitle)
        .accessibilityLabel(LF("%@，%@", task.displayTitle, L(task.completedAt == nil ? "未完成" : "已完成")))
        .accessibilityHint(L("查看任务详情"))
        .accessibilityAddTraits(selectedTaskID == task.id ? .isSelected : [])
        .contextMenu {
            Button(L(task.completedAt == nil ? "完成任务" : "恢复任务")) { store.toggle(task.id) }
        }
    }

    private func agenda(tasks: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(dateText(selectedDate, format: "yyyy年M月d日 EEEE", english: "EEEE, MMM d, yyyy"))
                        .font(Style.font(15, bold: true))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(LF("%ld 项任务 · 含已完成任务", tasks.count))
                        .font(Style.font(11)).foregroundStyle(Style.secondaryText)
                }
                Spacer(minLength: 12)
                Button { addTask(selectedDate) } label: {
                    Label(L("添加任务"), systemImage: "plus").padding(.vertical, 4)
                }
                .buttonStyle(.plain).foregroundStyle(Style.accentInk).fixedSize()
            }
            if tasks.isEmpty {
                Text(L("这一天没有安排任务"))
                    .foregroundStyle(Style.mutedText).padding(.vertical, 18)
            } else {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(tasks) { task in agendaRow(task) }
                }
            }
        }
    }

    private func unscheduled(tasks: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Style.separator.frame(height: 1).padding(.bottom, 4)
            HStack(spacing: 12) {
                Button { showUnscheduled.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: showUnscheduled ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .medium)).frame(width: 12)
                        Text(L("未安排日期")).font(Style.font(13, bold: true))
                        Text(tasks.count, format: .number).foregroundStyle(Style.secondaryText).monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 5).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LF("未安排日期，%ld 项任务", tasks.count))
                .accessibilityValue(L(showUnscheduled ? "已展开" : "已折叠"))
                Button { showUnscheduled = true; addTask(nil) } label: {
                    Label(L("添加任务"), systemImage: "plus").padding(.vertical, 4)
                }
                .buttonStyle(.plain).foregroundStyle(Style.accentInk).fixedSize()
                .help(L("新建未安排日期的任务")).accessibilityLabel(L("新建未安排日期的任务"))
            }
            if showUnscheduled {
                if tasks.isEmpty {
                    Text(L("未安排日期的任务会显示在这里"))
                        .foregroundStyle(Style.mutedText).padding(.vertical, 12)
                } else {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(tasks) { task in agendaRow(task) }
                    }
                }
            }
        }
    }

    private func agendaRow(_ task: Todo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(task.completedAt == nil ? Style.mutedText : Style.accent)
                    .frame(width: 24, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.top, 2)
            .accessibilityLabel(task.completedAt == nil ? LF("完成 %@", task.displayTitle) : LF("恢复 %@", task.displayTitle))
            Button { select(task) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.displayTitle).font(Style.font(15))
                        .strikethrough(task.completedAt != nil)
                        .foregroundStyle(task.completedAt == nil ? Style.ink : Style.secondaryText)
                        .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    if task.groupID != nil {
                        Text(store.groupName(task.groupID)).font(Style.font(12))
                            .foregroundStyle(Style.secondaryText)
                            .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(task.displayTitle)
            .accessibilityHint(L("查看任务详情"))
            .accessibilityAddTraits(selectedTaskID == task.id ? .isSelected : [])
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(selectedTaskID == task.id ? Style.selection : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }

    private func select(_ task: Todo) {
        selectedTaskID = task.id
        if let date = task.date { selectedDate = calendar.startOfDay(for: date) }
        else { showUnscheduled = true }
    }

    private func selectDay(_ date: Date, showAgenda: Bool = false) {
        selectedTaskID = nil
        selectedDate = calendar.startOfDay(for: date)
        showAgendaOnScroll = showAgenda
        scrollRequest += 1
    }

    private func movePeriod(by amount: Int) {
        selectDay(CalendarLayout.shift(selectedDate, by: amount, period: period, calendar: calendar))
    }

    private func periodTitle(days: [Date]) -> String {
        guard period == .week, let first = days.first, let last = days.last else {
            return dateText(selectedDate, format: "yyyy年M月", english: "MMMM yyyy")
        }
        let sameYear = calendar.isDate(first, equalTo: last, toGranularity: .year)
        return dateText(first, format: "yyyy年M月d日", english: "MMM d, yyyy") + " – "
            + dateText(last, format: sameYear ? "M月d日" : "yyyy年M月d日", english: sameYear ? "MMM d" : "MMM d, yyyy")
    }

    private func dateText(_ date: Date, format chinese: String, english: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = L10n.dateFormat(chinese, english)
        return formatter.string(from: date)
    }
}
