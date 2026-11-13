import SwiftUI

private enum MobileTab: String, CaseIterable {
    case tasks, calendar, lists, settings
    @MainActor var title: String { switch self { case .tasks: L("任务"); case .calendar: L("日历"); case .lists: L("清单"); case .settings: L("设置") } }
    var symbol: String { switch self { case .tasks: "checkmark.square"; case .calendar: "calendar"; case .lists: "folder"; case .settings: "gearshape" } }
}

enum MobileFilter: Hashable {
    case today, all, ungrouped, group(UUID)
    @MainActor func title(in store: Store) -> String {
        switch self { case .today: L("今天"); case .all: L("全部任务"); case .ungrouped: L("未分组"); case .group(let id): store.groupName(id) }
    }
}

private enum MobileRoute: Hashable { case task(UUID), list(MobileFilter), sync }

struct MobileTaskDraft: Identifiable {
    let id = UUID()
    var date: Date?
    var groupID: UUID?
}

struct MobileGroupDraft: Identifiable {
    let id = UUID()
    var groupID: UUID?
    var name = ""
}

struct MobileRootView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.mobileAppearance) private var appearance
    @State private var tab = MobileTab.tasks
    @State private var path: [MobileRoute] = []
    @State private var nativePaths: [MobileTab: [MobileRoute]] = [:]
    @State private var draft: MobileTaskDraft?
    @State private var draftTab = MobileTab.tasks

    private var usesNativeNavigation: Bool {
        if #available(iOS 26.0, *) { return appearance.usesGlass }
        return false
    }
    private var isAtRoot: Bool { usesNativeNavigation ? (nativePaths[tab]?.isEmpty ?? true) : path.isEmpty }

    var body: some View {
        Group {
            if #available(iOS 26.0, *), appearance.usesGlass {
                nativeTabs
            } else {
                NavigationStack(path: $path) {
                    rootContent(for: tab)
                        .navigationDestination(for: MobileRoute.self) { destination($0, in: tab) }
                        .toolbar(.hidden, for: .navigationBar)
                        .background(Style.background)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if path.isEmpty { ClassicMobileTabBar(selection: $tab) }
                }
                .background(Style.background.ignoresSafeArea())
            }
        }
        .environment(\.locale, language.locale)
        .onChange(of: tab) { _, _ in if !usesNativeNavigation { path = [] } }
        .sheet(item: $draft) { item in
            MobileTaskEditor(draft: item) { id in
                draft = nil
                append(.task(id), to: draftTab)
            }
            .environment(\.locale, language.locale)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .modifier(MobileSheetStyle())
        }
        .alert(L("数据操作失败"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L("好")) { store.error = nil }
        } message: { Text(L(store.error ?? "")) }
        .overlay(alignment: .bottom) {
            if let label = store.undoLabel {
                HStack(spacing: 12) {
                    Text(L(label)).fixedSize(horizontal: false, vertical: true)
                    Button { store.undo() } label: {
                        Text(L("撤销")).fontWeight(.semibold).foregroundStyle(Style.accentInk)
                            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                    }
                }
                .font(Style.font(13)).foregroundStyle(Style.ink)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Style.detail, in: Capsule())
                .padding(.horizontal, 20).padding(.bottom, isAtRoot ? 82 : 12)
            }
        }
    }

    @available(iOS 26.0, *)
    private var nativeTabs: some View {
        TabView(selection: $tab) {
            Tab(MobileTab.tasks.title, systemImage: MobileTab.tasks.symbol, value: MobileTab.tasks) { nativeStack(for: .tasks) }
            Tab(MobileTab.calendar.title, systemImage: MobileTab.calendar.symbol, value: MobileTab.calendar) { nativeStack(for: .calendar) }
            Tab(MobileTab.lists.title, systemImage: MobileTab.lists.symbol, value: MobileTab.lists) { nativeStack(for: .lists) }
            Tab(MobileTab.settings.title, systemImage: MobileTab.settings.symbol, value: MobileTab.settings) { nativeStack(for: .settings) }
        }
        .tint(Style.accent)
    }

    private func nativeStack(for sourceTab: MobileTab) -> some View {
        NavigationStack(path: Binding(get: { nativePaths[sourceTab] ?? [] }, set: { nativePaths[sourceTab] = $0 })) {
            rootContent(for: sourceTab)
                .toolbar(.visible, for: .tabBar)
                .navigationDestination(for: MobileRoute.self) { route in
                    destination(route, in: sourceTab).toolbar(.hidden, for: .tabBar)
                }
        }
        .tint(Style.ink)
    }

    @ViewBuilder private func rootContent(for sourceTab: MobileTab) -> some View {
        switch sourceTab {
        case .tasks:
            MobileTaskList(filter: .today, onOpen: { append(.task($0), to: sourceTab) },
                           onAdd: { addTask($0, $1, in: sourceTab) }, onSync: { append(.sync, to: sourceTab) })
        case .calendar:
            MobileCalendarView(onOpenTask: { append(.task($0), to: sourceTab) },
                               onAddTask: { addTask($0, $1, in: sourceTab) }, onOpenSync: { append(.sync, to: sourceTab) })
        case .lists:
            MobileListsView(onOpen: { append(.list($0), to: sourceTab) }, onSync: { append(.sync, to: sourceTab) })
        case .settings:
            MobileSettingsView()
        }
    }

    @ViewBuilder private func destination(_ route: MobileRoute, in sourceTab: MobileTab) -> some View {
        switch route {
        case .task(let id): MobileTaskDetail(taskID: id)
        case .list(let filter):
            MobileTaskList(filter: filter, showsBack: true, onOpen: { append(.task($0), to: sourceTab) },
                           onAdd: { addTask($0, $1, in: sourceTab) }, onSync: { append(.sync, to: sourceTab) })
        case .sync: MobileSyncView()
        }
    }

    private func append(_ route: MobileRoute, to sourceTab: MobileTab) {
        if usesNativeNavigation { nativePaths[sourceTab, default: []].append(route) }
        else { path.append(route) }
    }

    private func addTask(_ date: Date?, _ group: UUID?, in sourceTab: MobileTab) {
        draftTab = sourceTab
        draft = MobileTaskDraft(date: date, groupID: group)
    }
}

private struct ClassicMobileTabBar: View {
    @ObservedObject private var language = LanguageSettings.shared
    @Binding var selection: MobileTab

    private var items: some View {
        HStack(spacing: 4) {
            ForEach(MobileTab.allCases, id: \.self) { tab in
                Button { selection = tab } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.symbol).font(.system(size: 21, weight: .regular))
                        Text(tab.title).font(Style.font(13, bold: selection == tab))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(selection == tab ? Style.accentInk : Style.secondaryText)
                    .frame(minWidth: 44, maxWidth: .infinity, minHeight: 56)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain).accessibilityLabel(tab.title).accessibilityIdentifier("tab-\(tab.rawValue)")
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }.padding(4)
    }

    var body: some View {
        VStack(spacing: 0) {
            Style.separator.frame(height: 0.5)
            items.padding(.horizontal, 16)
        }
        .background(Style.detail)
        .accessibilityElement(children: .contain).accessibilityIdentifier("tabbar-classic")
    }
}

private struct MobileTaskList: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.mobileAppearance) private var appearance
    @Environment(\.dismiss) private var dismiss
    let filter: MobileFilter
    var showsBack = false
    let onOpen: (UUID) -> Void
    let onAdd: (Date?, UUID?) -> Void
    let onSync: () -> Void
    @State private var showCompleted = true

    private var usesNativeChrome: Bool {
        if #available(iOS 26.0, *) { return appearance.usesGlass }
        return false
    }

    private var tasks: [Todo] {
        let calendar = Calendar.current
        return store.data.tasks.filter { task in
            switch filter {
            case .today:
                if let completion = task.completedAt { return calendar.isDateInToday(completion) }
                return task.date.map { $0 < calendar.startOfDay(for: .now) || calendar.isDateInToday($0) } ?? false
            case .all: return true
            case .ungrouped: return task.groupID == nil
            case .group(let id): return task.groupID == id
            }
        }.sorted {
            let left = $0.date ?? .distantFuture, right = $1.date ?? .distantFuture
            return left == right ? $0.createdAt < $1.createdAt : left < right
        }
    }

    var body: some View {
        let pending = tasks.filter { $0.completedAt == nil }
        let overdue = pending.filter { ($0.date ?? .distantFuture) < Calendar.current.startOfDay(for: .now) }
        let upcoming = pending.filter { !overdue.contains($0) }
        let completed = tasks.filter { $0.completedAt != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if usesNativeChrome {
                    Text(Date().formatted(.dateTime.month().day().weekday(.wide).locale(L10n.locale)))
                        .font(Style.font(13)).foregroundStyle(Style.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    if showsBack {
                        MobileChromeButton(title: L("返回"), symbol: "chevron.left") { dismiss() }.accessibilityIdentifier("back-button")
                    }
                    MobilePageHeader(title: filter.title(in: store),
                                     subtitle: Date().formatted(.dateTime.month().day().weekday(.wide).locale(L10n.locale)),
                                     onAdd: add, onSync: onSync)
                }
                if !overdue.isEmpty { section(LF("逾期 %ld", overdue.count), tasks: overdue) }
                if !upcoming.isEmpty { section(filter == .today ? LF("待办 %ld", upcoming.count) : LF("任务 %ld", upcoming.count), tasks: upcoming) }
                if pending.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle").font(.system(size: 36, weight: .ultraLight)).foregroundStyle(Style.mutedText)
                        Text(L(filter == .today ? "今天没有待办" : "还没有任务")).font(Style.font(17))
                            .fixedSize(horizontal: false, vertical: true)
                        Button(L("添加一个任务"), action: add).font(Style.font(16)).foregroundStyle(Style.accentInk).frame(minHeight: 44)
                    }.foregroundStyle(Style.secondaryText).frame(maxWidth: .infinity).padding(.vertical, 48)
                }
                if !completed.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Style.separator.frame(height: 1).padding(.bottom, 8)
                        Button { showCompleted.toggle() } label: {
                            HStack(spacing: 8) {
                                Image(systemName: showCompleted ? "chevron.down" : "chevron.right").font(.system(size: 12))
                                Text(LF("已完成 %ld", completed.count)).font(Style.font(13, bold: true))
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer()
                            }.foregroundStyle(Style.secondaryText).padding(.vertical, 8).frame(minHeight: 44).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        if showCompleted {
                            ForEach(completed) { task in MobileTaskRow(task: task) { onOpen(task.id) } }
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden).background(Style.background)
        .navigationTitle(filter.title(in: store))
        .navigationBarTitleDisplayMode(showsBack ? .inline : .large)
        .toolbar(usesNativeChrome ? .automatic : .hidden, for: .navigationBar)
        .toolbar {
            if #available(iOS 26.0, *), appearance.usesGlass {
                MobilePageToolbar(addTitle: L("新建任务"), onAdd: add, onSync: onSync)
            }
        }
    }

    private func section(_ title: String, tasks: [Todo]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Style.font(13, bold: true)).foregroundStyle(Style.secondaryText)
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            ForEach(tasks) { task in MobileTaskRow(task: task) { onOpen(task.id) } }
        }
    }

    private func add() {
        var group: UUID?
        if case .group(let id) = filter { group = id }
        onAdd(filter == .today ? .now : nil, group)
    }
}

private struct MobileListsView: View {
    @EnvironmentObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.mobileAppearance) private var appearance
    let onOpen: (MobileFilter) -> Void
    let onSync: () -> Void
    @State private var editor: MobileGroupDraft?
    @State private var deleting: UUID?

    private var usesNativeChrome: Bool {
        if #available(iOS 26.0, *) { return appearance.usesGlass }
        return false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if usesNativeChrome {
                    Text(L("把相关的事放在一起")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L("清单")).font(Style.font(28, bold: true)).accessibilityAddTraits(.isHeader)
                            Text(L("把相关的事放在一起")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        MobileChromeButton(title: L("新建分组"), symbol: "plus", prominent: true) { editor = MobileGroupDraft() }
                            .accessibilityIdentifier("add-group")
                    }
                }
                VStack(spacing: 0) {
                    listRow(L("全部任务"), symbol: "square.stack", count: store.data.tasks.count) { onOpen(.all) }
                    Style.separator.frame(height: 1).padding(.leading, 36)
                    listRow(L("未分组"), symbol: "tray", count: store.data.tasks.filter { $0.groupID == nil }.count) { onOpen(.ungrouped) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("我的分组")).font(Style.font(13)).foregroundStyle(Style.secondaryText)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(store.data.groups) { group in
                        listRow(group.name, symbol: "folder", count: store.data.tasks.filter { $0.groupID == group.id }.count) { onOpen(.group(group.id)) }
                            .accessibilityIdentifier("group-\(group.name)")
                            .contextMenu {
                                Button(L("重命名")) { editor = MobileGroupDraft(groupID: group.id, name: group.name) }
                                Button(L("删除分组"), role: .destructive) { deleting = group.id }
                            }
                    }
                    if store.data.groups.isEmpty {
                        Text(L("点击右上角 + 创建第一个分组"))
                            .font(Style.font(13)).foregroundStyle(Style.secondaryText)
                            .fixedSize(horizontal: false, vertical: true).padding(.vertical, 16)
                    } else {
                        Text(L("长按分组可重命名或删除")).font(Style.font(13)).foregroundStyle(Style.mutedText)
                            .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
                    }
                }
                if !usesNativeChrome {
                    Button(action: onSync) {
                        Label(store.syncStatus.title, systemImage: "icloud").font(Style.font(13)).foregroundStyle(Style.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12).frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("open-sync")
                }
            }.foregroundStyle(Style.ink).padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
        }
        .background(Style.background).scrollIndicators(.hidden)
        .navigationTitle(L("清单"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar(usesNativeChrome ? .automatic : .hidden, for: .navigationBar)
        .toolbar {
            if #available(iOS 26.0, *), appearance.usesGlass {
                MobilePageToolbar(addTitle: L("新建分组"), onAdd: { editor = MobileGroupDraft() },
                                  onSync: onSync, addIdentifier: "add-group")
            }
        }
        .sheet(item: $editor) { item in
            MobileGroupEditor(draft: item)
                .environment(\.locale, language.locale)
                .presentationDetents([.height(300), .large]).presentationDragIndicator(.visible)
                .modifier(MobileSheetStyle())
        }
        .confirmationDialog(L("删除分组？其中的任务会保留并移至未分组。"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("删除分组"), role: .destructive) {
                if let deleting { store.deleteGroup(deleting) }
                deleting = nil
            }.accessibilityIdentifier("confirm-delete-group")
            Button(L("取消"), role: .cancel) { deleting = nil }
        }
    }

    private func listRow(_ title: String, symbol: String, count: Int, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 18, weight: .regular)).foregroundStyle(Style.secondaryText).frame(width: 24)
                Text(title).font(Style.font(17)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(count.formatted(.number.locale(L10n.locale))).font(Style.font(13)).foregroundStyle(Style.secondaryText).fixedSize()
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(Style.mutedText)
            }.foregroundStyle(Style.ink).padding(.vertical, 8).frame(minHeight: 64).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
