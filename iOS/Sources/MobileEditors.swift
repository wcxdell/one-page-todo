import SwiftUI
import UIKit

struct MobileTaskEditor: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobileAppearance) private var appearance
    let saved: (UUID) -> Void
    @State private var title = ""
    @State private var notes = ""
    @State private var date: Date?
    @State private var groupID: UUID?
    @State private var choosingDate = false
    @FocusState private var focused: Bool

    init(draft: MobileTaskDraft, saved: @escaping (UUID) -> Void) {
        _date = State(initialValue: draft.date)
        _groupID = State(initialValue: draft.groupID)
        self.saved = saved
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *), appearance.usesGlass {
                nativeBody
            } else {
                classicBody
            }
        }
        .sheet(isPresented: $choosingDate) {
            MobileDateEditor(date: $date)
                .environment(\.locale, language.locale)
                .presentationDetents([.large]).modifier(MobileSheetStyle())
        }
        .onAppear { focused = true }
    }

    @available(iOS 26.0, *)
    private var nativeBody: some View {
        NavigationStack {
            content
                .contentMargins(.top, 16, for: .scrollContent)
                .foregroundStyle(Style.ink)
                .navigationTitle(L("新建任务"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("取消")) { dismiss() }
                            .font(Style.font(16)).tint(nil).foregroundStyle(Style.ink)
                            .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("cancel-editor")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("添加"), action: add)
                            .buttonStyle(.glassProminent).tint(Style.accent)
                            .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("save-task")
                    }
                }
        }
    }

    private var classicBody: some View {
        VStack(spacing: 0) {
            classicHeader
            content
        }
        .background(Style.detail).foregroundStyle(Style.ink)
    }

    private var classicHeader: some View {
        HStack {
            MobileChromeButton(title: L("取消")) { dismiss() }.accessibilityIdentifier("cancel-editor")
            Spacer()
            Text(L("新建任务")).font(Style.font(17, bold: true))
            Spacer()
            MobileChromeButton(title: L("添加"), prominent: true, action: add)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .accessibilityIdentifier("save-task")
        }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 24)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                TextField(L("准备做什么？"), text: $title, axis: .vertical)
                    .font(Style.font(20, bold: true)).focused($focused)
                    .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                    .accessibilityIdentifier("task-title-field")
                MobileMetadataFields(date: $date, groupID: $groupID, choosingDate: $choosingDate)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("备注")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                    TextEditor(text: $notes)
                        .font(Style.font(17)).lineSpacing(4).scrollContentBackground(.hidden)
                        .frame(minHeight: 160).accessibilityLabel(L("备注")).accessibilityIdentifier("task-notes-field")
                        .overlay(alignment: .topLeading) {
                            if notes.isEmpty {
                                Text(L("添加备注…")).font(Style.font(17)).foregroundStyle(Style.mutedText)
                                    .padding(.horizontal, 5).padding(.top, 8).allowsHitTesting(false).accessibilityHidden(true)
                            }
                        }
                }
                if let error = store.error { Text(L(error)).font(Style.font(13)).foregroundStyle(Style.overdue) }
            }.padding(.horizontal, 20).padding(.bottom, 24)
        }.scrollDismissesKeyboard(.interactively)
    }

    private func add() {
        guard let id = store.addTask(title: title, date: date, groupID: groupID) else { return }
        if !notes.isEmpty { store.update(id) { $0.details = notes } }
        if store.error == nil { saved(id) }
    }
}

struct MobileMetadataFields: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    @Binding var date: Date?
    @Binding var groupID: UUID?
    @Binding var choosingDate: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button { choosingDate = true } label: {
                metadataLabel(L("日期"), symbol: "calendar", value: mobileDateLabel(date))
            }.buttonStyle(.plain).accessibilityIdentifier("task-date-picker")
            Style.separator.frame(height: 1).padding(.leading, 36)
            Menu {
                Button(L("未分组")) { groupID = nil }
                ForEach(store.data.groups) { group in Button(group.name) { groupID = group.id } }
            } label: {
                metadataLabel(L("分组"), symbol: "folder", value: store.groupName(groupID))
            }.accessibilityIdentifier("task-group-picker")
        }
    }

    private func metadataLabel(_ title: String, symbol: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).frame(width: 24).foregroundStyle(Style.secondaryText)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                Text(value).font(Style.font(17)).foregroundStyle(Style.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Style.mutedText)
        }.padding(.vertical, 8).frame(minHeight: 64).contentShape(Rectangle())
    }
}

private struct MobileDateEditor: View {
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobileAppearance) private var appearance
    @Binding var date: Date?
    @State private var selection: Date

    init(date: Binding<Date?>) {
        _date = date
        _selection = State(initialValue: date.wrappedValue ?? .now)
    }

    var body: some View {
        if #available(iOS 26.0, *), appearance.usesGlass {
            nativeBody
        } else {
            classicBody
        }
    }

    @available(iOS 26.0, *)
    private var nativeBody: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) { dateFields }.padding(20)
            }
            .foregroundStyle(Style.ink)
            .navigationTitle(L("设置日期"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                        .font(Style.font(16)).tint(nil).foregroundStyle(Style.ink)
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("cancel-editor")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("完成"), action: save)
                        .buttonStyle(.glassProminent).tint(Style.accent)
                        .accessibilityIdentifier("save-date")
                }
            }
        }
    }

    private var classicBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                classicHeader
                dateFields
            }.padding(20)
        }.background(Style.detail).foregroundStyle(Style.ink)
    }

    private var classicHeader: some View {
        HStack {
            MobileChromeButton(title: L("取消")) { dismiss() }
            Spacer()
            Text(L("设置日期")).font(Style.font(16, bold: true))
            Spacer()
            MobileChromeButton(title: L("完成"), prominent: true, action: save)
                .accessibilityIdentifier("save-date")
        }
    }

    @ViewBuilder private var dateFields: some View {
        DatePicker(L("日期"), selection: $selection, displayedComponents: .date)
            .datePickerStyle(.graphical).tint(Style.accent)
            .environment(\.locale, language.locale)
        if #available(iOS 26.0, *), appearance.usesGlass {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { quickDates }
                VStack(alignment: .leading, spacing: 8) { quickDates }
            }.font(Style.font(16)).foregroundStyle(Style.ink).buttonStyle(.glass).tint(nil)
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { quickDates }
                VStack(alignment: .leading, spacing: 8) { quickDates }
            }.font(Style.font(16)).foregroundStyle(Style.ink).buttonStyle(.bordered).tint(Style.secondaryText)
        }
    }

    @ViewBuilder private var quickDates: some View {
        Button { date = Calendar.current.startOfDay(for: .now); dismiss() } label: {
            quickDateLabel(L("今天"))
        }
        Button {
            date = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))
            dismiss()
        } label: {
            quickDateLabel(L("明天"))
        }
        Button { date = nil; dismiss() } label: {
            quickDateLabel(L("未安排日期"))
        }.accessibilityIdentifier("clear-date")
    }

    private func quickDateLabel(_ title: String) -> some View {
        Text(title).fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }

    private func save() {
        date = Calendar.current.startOfDay(for: selection)
        dismiss()
    }
}

struct MobileTaskDetail: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobileAppearance) private var appearance
    let taskID: UUID
    @State private var choosingDate = false
    @State private var confirmingDelete = false
    private var task: Todo? { store.data.tasks.first { $0.id == taskID } }

    var body: some View {
        Group {
            if #available(iOS 26.0, *), appearance.usesGlass {
                nativeBody
            } else {
                classicBody
            }
        }
        .onChange(of: task == nil) { _, deleted in if deleted { dismiss() } }
        .sheet(isPresented: $choosingDate) {
            MobileDateEditor(date: Binding(get: { task?.date }, set: { value in store.update(taskID) { $0.date = value } }))
                .environment(\.locale, language.locale)
                .presentationDetents([.large]).modifier(MobileSheetStyle())
        }
    }

    @available(iOS 26.0, *)
    private var nativeBody: some View {
        content
            .background(Style.detail).foregroundStyle(Style.ink)
            .navigationTitle(L("任务详情"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L("删除任务"), systemImage: "trash") { confirmingDelete = true }
                        .buttonStyle(.glass).tint(nil).foregroundStyle(Style.secondaryText)
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("delete-task")
                        .confirmationDialog(L("删除这个任务？"), isPresented: $confirmingDelete, titleVisibility: .visible) {
                            deleteActions
                        }
                }
            }
    }

    private var classicBody: some View {
        VStack(spacing: 0) {
            classicHeader
            content
        }
        .background(Style.detail).foregroundStyle(Style.ink).toolbar(.hidden, for: .navigationBar)
    }

    private var classicHeader: some View {
        HStack {
            MobileChromeButton(title: L("任务"), symbol: "chevron.left") { dismiss() }.accessibilityIdentifier("back-button")
            Spacer()
            Text(L("任务详情")).font(Style.font(16)).foregroundStyle(Style.secondaryText)
            Spacer()
            MobileChromeButton(title: L("删除任务"), symbol: "trash") { confirmingDelete = true }
                .accessibilityIdentifier("delete-task")
                .confirmationDialog(L("删除这个任务？"), isPresented: $confirmingDelete, titleVisibility: .visible) {
                    deleteActions
                }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }

    @ViewBuilder private var content: some View {
        if let task {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 8) {
                        Button { store.toggle(taskID) } label: {
                            Image(systemName: task.completedAt == nil ? "circle" : "checkmark.circle.fill")
                                .font(.system(size: 23, weight: .light))
                                .foregroundStyle(task.completedAt == nil ? Style.mutedText : Style.accent)
                                .frame(width: 44, height: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("detail-completion")
                        .accessibilityLabel(L(task.completedAt == nil ? "完成任务" : "恢复任务"))
                        .accessibilityValue(L(task.completedAt == nil ? "未完成" : "已完成"))
                        TextField(L("任务标题"), text: Binding(get: { self.task?.title ?? "" }, set: { value in store.update(taskID) { $0.title = value } }), axis: .vertical)
                            .font(Style.font(20, bold: true))
                            .foregroundStyle(task.completedAt == nil ? Style.ink : Style.mutedText)
                            .strikethrough(task.completedAt != nil)
                            .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                            .accessibilityIdentifier("detail-title-field")
                    }
                    MobileMetadataFields(
                        date: Binding(get: { self.task?.date }, set: { value in store.update(taskID) { $0.date = value } }),
                        groupID: Binding(get: { self.task?.groupID }, set: { store.move(taskID, to: $0) }),
                        choosingDate: $choosingDate
                    )
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("备注")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                        TextEditor(text: Binding(get: { self.task?.details ?? "" }, set: { value in store.update(taskID) { $0.details = value.isEmpty ? nil : value } }))
                            .font(Style.font(17)).lineSpacing(4).scrollContentBackground(.hidden)
                            .frame(minHeight: 160).accessibilityLabel(L("备注")).accessibilityIdentifier("detail-notes-field")
                    }
                    Text(L("更改自动保存")).font(Style.font(13)).foregroundStyle(Style.mutedText)
                }.padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 24)
            }.scrollDismissesKeyboard(.interactively)
        } else {
            ContentUnavailableView(L("任务已删除"), systemImage: "checkmark.circle")
        }
    }

    @ViewBuilder private var deleteActions: some View {
        Button(L("删除任务"), role: .destructive) { store.deleteTask(taskID) }.accessibilityIdentifier("confirm-delete-task")
        Button(L("取消"), role: .cancel) { confirmingDelete = false }
    }
}

struct MobileGroupEditor: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobileAppearance) private var appearance
    let draft: MobileGroupDraft
    @State private var name: String
    @FocusState private var focused: Bool

    init(draft: MobileGroupDraft) {
        self.draft = draft
        _name = State(initialValue: draft.name)
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *), appearance.usesGlass {
                nativeBody
            } else {
                classicBody
            }
        }
        .onAppear { focused = true }
    }

    @available(iOS 26.0, *)
    private var nativeBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) { groupFields }
                    .padding(20).padding(.top, 4)
            }
            .scrollDismissesKeyboard(.interactively)
            .foregroundStyle(Style.ink)
            .navigationTitle(L(draft.groupID == nil ? "新建分组" : "重命名分组"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消")) { dismiss() }
                        .font(Style.font(16)).tint(nil).foregroundStyle(Style.ink)
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("cancel-editor")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("保存"), action: save)
                        .buttonStyle(.glassProminent).tint(Style.accent)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("save-group")
                }
            }
        }
    }

    private var classicBody: some View {
        VStack(alignment: .leading, spacing: 24) {
            classicHeader
            groupFields
            Spacer(minLength: 0)
        }
        .padding(20).padding(.top, 4).background(Style.detail).foregroundStyle(Style.ink)
    }

    private var classicHeader: some View {
        HStack {
            MobileChromeButton(title: L("取消")) { dismiss() }.accessibilityIdentifier("cancel-editor")
            Spacer()
            Text(L(draft.groupID == nil ? "新建分组" : "重命名分组")).font(Style.font(17, bold: true))
            Spacer()
            MobileChromeButton(title: L("保存"), prominent: true, action: save)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                .accessibilityIdentifier("save-group")
        }
    }

    @ViewBuilder private var groupFields: some View {
        TextField(L("输入分组名称"), text: $name).font(Style.font(17))
            .frame(minHeight: 44)
            .focused($focused).onSubmit(save).accessibilityIdentifier("group-name-field")
        Text(L("把相关任务放在一起，让清单更有条理。"))
            .font(Style.font(13)).foregroundStyle(Style.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let id = draft.groupID {
            store.renameGroup(id, name: trimmed)
            if store.groupName(id) == trimmed { dismiss() }
        } else if store.addGroup(trimmed) != nil { dismiss() }
    }
}

struct MobileSettingsView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    private let themes = ThemeSettings.shared
    @Environment(\.mobileAppearance) private var appearance
    @State private var pendingLanguage: AppLanguagePreference
    @State private var pendingTheme: AppTheme

    init() {
        _pendingLanguage = State(initialValue: LanguageSettings.shared.preference)
        _pendingTheme = State(initialValue: ThemeSettings.shared.current)
    }

    private var hasChanges: Bool {
        pendingLanguage != language.preference || pendingTheme != themes.current
    }

    private func confirmSettings() {
        themes.current = pendingTheme
        language.preference = pendingLanguage
        language.refreshSystemLanguage()
    }

    private func resetPendingSettings() {
        pendingLanguage = language.preference
        pendingTheme = themes.current
    }

    private var versionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("未知")
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? L("未知")
        return LF("版本 %@（构建 %@）", version, build)
    }

    var body: some View {
        Group {
            if #available(iOS 26.0, *), appearance.usesGlass {
                nativeBody
            } else {
                classicBody
            }
        }
        .onAppear { resetPendingSettings() }
        .onDisappear { resetPendingSettings() }
    }

    @available(iOS 26.0, *)
    private var nativeBody: some View {
        content(showClassicHeader: false)
            .background(Style.background).foregroundStyle(Style.ink)
            .navigationTitle(L("设置"))
            .navigationBarTitleDisplayMode(.large)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                if hasChanges {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("取消")) { resetPendingSettings() }
                            .font(Style.font(16)).tint(nil).foregroundStyle(Style.ink)
                            .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("cancel-language")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("确认"), action: confirmSettings)
                            .buttonStyle(.glassProminent).tint(Style.accent)
                            .accessibilityIdentifier("confirm-language")
                    }
                }
            }
    }

    private var classicBody: some View {
        content(showClassicHeader: true)
            .background(Style.background).foregroundStyle(Style.ink)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if hasChanges {
                    VStack(spacing: 0) {
                        Style.separator.frame(height: 1)
                        HStack {
                            MobileChromeButton(title: L("取消")) { resetPendingSettings() }
                                .accessibilityIdentifier("cancel-language")
                            Spacer()
                            MobileChromeButton(title: L("确认"), prominent: true, action: confirmSettings)
                                .accessibilityIdentifier("confirm-language")
                        }
                        .padding(.horizontal, 20).padding(.vertical, 8)
                    }
                    .background(Style.detail)
                }
            }
    }

    private func content(showClassicHeader: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showClassicHeader {
                    Text(L("设置"))
                        .font(Style.font(28, bold: true)).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("settings-title")
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("应用信息")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.square")
                            .font(.system(size: 28, weight: .light)).foregroundStyle(Style.brand)
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("一页待办")).font(Style.font(20, bold: true))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings-app-name")
                            Text(versionLabel).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("settings-version")
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Style.separator.frame(height: 1)
                ThemeSelectionView(selection: $pendingTheme, current: themes.current)
                Style.separator.frame(height: 1)
                VStack(alignment: .leading, spacing: 16) {
                    Text(L("语言")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("当前语言")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                        Text(languageName(language.preference)).font(Style.font(17))
                            .fixedSize(horizontal: false, vertical: true)
                        if language.preference == .system {
                            Text(language.effectiveLanguage == .chinese ? "简体中文" : "English")
                                .font(Style.font(13)).foregroundStyle(Style.secondaryText)
                        }
                    }
                    .accessibilityElement(children: .combine).accessibilityIdentifier("settings-current-language")
                    VStack(spacing: 0) {
                        ForEach(AppLanguagePreference.allCases) { preference in
                            languageRow(preference)
                        }
                    }
                    if pendingLanguage != language.preference {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("尚未确认")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                            Text(languageName(pendingLanguage)).font(Style.font(17))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine).accessibilityIdentifier("settings-pending-language")
                    }
                    Text(L("默认跟随设备语言。选择后点击“确认”才会保存并生效；取消或离开设置页不会保存。"))
                        .font(Style.font(13)).foregroundStyle(Style.secondaryText).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L("仅切换界面语言，不会更改任务、备注或分组名称。"))
                        .font(Style.font(13)).foregroundStyle(Style.mutedText).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Style.separator.frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("iCloud 同步")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    Label(store.syncStatus.title, systemImage: store.hasCloudConnection ? "icloud" : "internaldrive")
                        .font(Style.font(16)).foregroundStyle(Style.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(store.syncStatus.detail)
                        .font(Style.font(13)).foregroundStyle(Style.secondaryText).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func languageRow(_ preference: AppLanguagePreference) -> some View {
        let selected = pendingLanguage == preference
        return Button {
            pendingLanguage = preference
        } label: {
            HStack(spacing: 12) {
                Text(languageName(preference)).font(Style.font(17, bold: selected))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(selected ? Style.accent : Style.mutedText)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(languageName(preference))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("language-\(preference.rawValue)")
    }

    private func languageName(_ preference: AppLanguagePreference) -> String {
        switch preference {
        case .system: preference.displayName
        case .chinese: "简体中文"
        case .english: "English"
        }
    }
}

struct MobileSyncView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mobileAppearance) private var appearance

    var body: some View {
        if #available(iOS 26.0, *), appearance.usesGlass {
            nativeBody
        } else {
            classicBody
        }
    }

    @available(iOS 26.0, *)
    private var nativeBody: some View {
        content(showClassicChrome: false)
            .background(Style.background).foregroundStyle(Style.ink)
            .navigationTitle(L("同步"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }

    private var classicBody: some View {
        content(showClassicChrome: true)
            .background(Style.background).foregroundStyle(Style.ink).toolbar(.hidden, for: .navigationBar)
    }

    private var classicHeader: some View {
        HStack {
            MobileChromeButton(title: L("返回"), symbol: "chevron.left") { dismiss() }.accessibilityIdentifier("back-button")
            Spacer()
            Text(L("同步")).font(Style.font(16)).foregroundStyle(Style.secondaryText)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func content(showClassicChrome: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if showClassicChrome { classicHeader }
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "icloud").font(.system(size: 44, weight: .ultraLight)).foregroundStyle(Style.secondaryText)
                    Text(L("iCloud 同步")).font(Style.font(24, bold: true))
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("sync-title")
                    Text(store.syncStatus.title).font(Style.font(17, bold: true))
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("sync-status")
                    Text(store.syncStatus.detail).font(Style.font(13)).foregroundStyle(Style.secondaryText).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    deviceRow("Mac", symbol: "desktopcomputer", status: L("同一 Apple ID"))
                    Style.separator.frame(height: 1).padding(.leading, 36)
                    deviceRow("iPhone", symbol: "iphone", status: L(store.hasCloudConnection ? "iCloud 可用" : "本机保存"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("同步内容")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                    Text(L("任务与分组\n日期与完成状态\n任务备注")).font(Style.font(17)).lineSpacing(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
                syncButton
                Text(L("离线时仍可使用，数据保存在本机。"))
                    .font(Style.font(13)).foregroundStyle(Style.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }
    }

    private var syncButton: some View {
        Group {
            if #available(iOS 26.0, *), appearance.usesGlass {
                Button(action: syncNow) {
                    Text(L(store.syncStatus.isSyncing ? "同步中…" : "立即同步"))
                        .font(Style.font(17, bold: true)).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.glassProminent).tint(Style.accent)
            } else {
                Button(action: syncNow) {
                    Text(L(store.syncStatus.isSyncing ? "同步中…" : "立即同步"))
                        .font(Style.font(17, bold: true)).foregroundStyle(Style.detail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(Style.accent, in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
        }
        .disabled(store.syncStatus == .notConfigured || store.syncStatus.isSyncing)
        .opacity(store.syncStatus == .notConfigured || store.syncStatus.isSyncing ? 0.45 : 1)
        .accessibilityIdentifier("sync-now")
    }

    private func syncNow() {
        Task {
            await store.syncNow()
            if store.hasCloudConnection { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    private func deviceRow(_ title: String, symbol: String, status: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(Style.secondaryText).frame(width: 24)
            Text(title).font(Style.font(17)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(status).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 16)
    }
}
