import SwiftUI

struct MonthCalendar: View {
    @ObservedObject private var language = LanguageSettings.shared
    @Binding var date: Date?
    let close: () -> Void

    @State private var month = Date()
    @State private var hoveredDay: Date?

    private var locale: Locale { language.locale }
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    private var today: Date { calendar.startOfDay(for: .now) }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: month)?.start ?? month }

    private var days: [Date] {
        let weekday = calendar.component(.weekday, from: monthStart)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: monthStart) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                Text(month.formatted(.dateTime.year().month(.wide).locale(locale)))
                    .font(Style.font(23, bold: true))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                monthButton(L("上个月"), symbol: "chevron.left", offset: -1)
                monthButton(L("下个月"), symbol: "chevron.right", offset: 1)
            }

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(weekdays, id: \.self) { weekday in
                    Text(L(weekday))
                        .font(Style.font(13, bold: true))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 26)
                }
                ForEach(days, id: \.self) { day in
                    dayButton(day)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button(L("今天")) { selectAndClose(today) }
                Button(L("明天")) { selectAndClose(calendar.date(byAdding: .day, value: 1, to: today)) }
                Spacer()
                Button(L("清除日期")) { selectAndClose(nil) }
                    .disabled(date == nil)
                Button(L("完成"), action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(20)
        .frame(width: 408)
        .background(Style.detail)
        .foregroundStyle(Style.ink)
        .font(Style.font(14))
        .tint(Style.accent)
        .environment(\.locale, language.locale)
        .onAppear { month = date ?? today }
    }

    private func monthButton(_ title: String, symbol: String, offset: Int) -> some View {
        Button {
            if let next = calendar.date(byAdding: .month, value: offset, to: monthStart) {
                month = next
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .help(title)
        .accessibilityLabel(title)
    }

    private func dayButton(_ day: Date) -> some View {
        let isSelected = date.map { calendar.isDate($0, inSameDayAs: day) } ?? false
        let isToday = calendar.isDate(day, inSameDayAs: today)
        let isInMonth = calendar.isDate(day, equalTo: month, toGranularity: .month)

        return Button {
            date = day
            if !isInMonth { month = day }
        } label: {
            Text(calendar.component(.day, from: day), format: .number)
                .font(Style.font(17, bold: isSelected || isToday))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Style.detail : (isToday ? Style.accent : (isInMonth ? Style.ink : Style.mutedText)))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isSelected ? Style.accent : (hoveredDay == day ? Style.selection : .clear))
                }
                .overlay(alignment: .bottom) {
                    if isToday {
                        Circle().fill(isSelected ? Style.detail : Style.accent).frame(width: 4, height: 4).padding(.bottom, 5)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered in hoveredDay = isHovered ? day : nil }
        .accessibilityLabel(day.formatted(.dateTime.year().month(.wide).day().weekday(.wide).locale(locale)))
        .accessibilityValue(isToday ? L("今天") : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectAndClose(_ selection: Date?) {
        date = selection
        close()
    }
}
