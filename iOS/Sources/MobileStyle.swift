import SwiftUI

struct MobileAppearance: Sendable {
    var usesGlass: Bool
    static var current: Self {
        if #available(iOS 26.0, *) { return Self(usesGlass: true) }
        return Self(usesGlass: false)
    }
}

private struct MobileAppearanceKey: EnvironmentKey {
    static let defaultValue = MobileAppearance.current
}

extension EnvironmentValues {
    var mobileAppearance: MobileAppearance {
        get { self[MobileAppearanceKey.self] }
        set { self[MobileAppearanceKey.self] = newValue }
    }
}

// Preserve the original presentation only on older systems. Modern sheets use Apple's material.
struct MobileSheetStyle: ViewModifier {
    @Environment(\.mobileAppearance) private var appearance

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *), appearance.usesGlass {
            content
        } else {
            content.presentationBackground(Style.detail).presentationCornerRadius(26)
        }
    }
}

struct MobileChromeButton: View {
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.mobileAppearance) private var appearance
    let title: String
    var symbol: String? = nil
    var prominent = false
    let action: () -> Void

    private var systemButton: some View {
        Button(action: action) {
            Group {
                if let symbol { Label(title, systemImage: symbol).labelStyle(.iconOnly) }
                else { Text(title).fixedSize(horizontal: false, vertical: true) }
            }
            .font(Style.font(16, bold: prominent))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }.accessibilityLabel(title)
    }

    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *), appearance.usesGlass {
            if prominent {
                systemButton.buttonStyle(.glassProminent).tint(Style.accent)
                    .buttonBorderShape(symbol == nil ? .capsule : .circle)
            } else {
                systemButton.buttonStyle(.glass).tint(nil).foregroundStyle(Style.ink)
                    .buttonBorderShape(symbol == nil ? .capsule : .circle)
            }
        } else {
            Button(action: action) {
                Group {
                    if let symbol { Image(systemName: symbol).font(.system(size: 18, weight: .medium)) }
                    else {
                        Text(title).font(Style.font(16, bold: prominent))
                            .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
                    }
                }
                .foregroundStyle(prominent ? Style.detail : Style.ink)
                .frame(minWidth: 44, minHeight: 44).contentShape(Capsule())
                .background(prominent ? Style.accent : Color.clear, in: Capsule())
            }.buttonStyle(.plain).accessibilityLabel(title)
        }
    }
}

@available(iOS 26.0, *)
struct MobilePageToolbar: ToolbarContent {
    let addTitle: String
    let onAdd: (() -> Void)?
    let onSync: (() -> Void)?
    var addIdentifier = "add-task"

    var body: some ToolbarContent {
        if let onSync {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onSync) {
                    Label(L("同步"), systemImage: "icloud").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.glass).tint(nil).foregroundStyle(Style.secondaryText)
                .accessibilityLabel(L("同步")).accessibilityIdentifier("open-sync")
            }
        }
        if onSync != nil && onAdd != nil { ToolbarSpacer(.fixed, placement: .topBarTrailing) }
        if let onAdd {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onAdd) {
                    Label(addTitle, systemImage: "plus").frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.glassProminent).tint(Style.accent)
                .accessibilityLabel(addTitle).accessibilityIdentifier(addIdentifier)
            }
        }
    }
}

struct MobilePageHeader: View {
    @ObservedObject private var language = LanguageSettings.shared
    let title: String
    var subtitle: String? = nil
    var onAdd: (() -> Void)? = nil
    var onSync: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(Style.font(28, bold: true)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                if let onSync {
                    MobileChromeButton(title: L("同步"), symbol: "icloud", action: onSync).accessibilityIdentifier("open-sync")
                }
                if let onAdd {
                    MobileChromeButton(title: L("新建任务"), symbol: "plus", prominent: true, action: onAdd).accessibilityIdentifier("add-task")
                }
            }
        }.foregroundStyle(Style.ink)
    }
}

struct MobileTaskRow: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    let task: Todo
    let onOpen: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 21, weight: .light))
                    .foregroundStyle(task.completedAt == nil ? Style.mutedText : Style.accent)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .padding(.top, 8)
            .buttonStyle(.plain).accessibilityLabel(task.completedAt == nil ? LF("完成 %@", task.displayTitle) : LF("恢复 %@", task.displayTitle))
            .accessibilityValue(L(task.completedAt == nil ? "未完成" : "已完成"))
            .accessibilityIdentifier("toggle-task-\(task.displayTitle)")
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.displayTitle).font(Style.font(17))
                        .foregroundStyle(task.completedAt == nil ? Style.ink : Style.mutedText)
                        .strikethrough(task.completedAt != nil)
                        .fixedSize(horizontal: false, vertical: true)
                    if task.completedAt == nil, let notes = task.details, !notes.isEmpty {
                        Text(notes.replacingOccurrences(of: "\n", with: " "))
                            .font(Style.font(13)).foregroundStyle(Style.secondaryText)
                            .lineLimit(1)
                    }
                    if let date = task.date, task.completedAt == nil, date < Calendar.current.startOfDay(for: .now) {
                        Text(date.formatted(.dateTime.month().day().locale(L10n.locale)))
                            .font(Style.font(13)).foregroundStyle(Style.overdue)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if task.groupID != nil {
                        Text(store.groupName(task.groupID)).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8).frame(minHeight: 64).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel(task.displayTitle).accessibilityIdentifier("open-task-\(task.displayTitle)")
        }
    }
}

@MainActor func mobileDateLabel(_ date: Date?) -> String {
    guard let date else { return L("未安排") }
    if Calendar.current.isDateInToday(date) { return L("今天") }
    if Calendar.current.isDateInTomorrow(date) { return L("明天") }
    return date.formatted(.dateTime.year().month().day().locale(L10n.locale))
}
