import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@main
struct OnePageApp: App {
    @NSApplicationDelegateAdaptor(OnePageAppDelegate.self) private var appDelegate
    @StateObject private var store = Store()
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        Window(L("一页待办"), id: "main") {
            ContentView()
                .background(MainWindowRegistration(appDelegate: appDelegate, background: Style.background).frame(width: 0, height: 0))
                .environmentObject(store)
                .environment(\.locale, language.locale)
                .preferredColorScheme(.light)
                .task {
                    language.refreshSystemLanguage()
                    await store.startSync()
                    if store.hasCloudConnection { NSApp.registerForRemoteNotifications() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        language.refreshSystemLanguage()
                        Task {
                            await store.syncNow()
                            if store.hasCloudConnection { NSApp.registerForRemoteNotifications() }
                        }
                    }
                }
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appTermination) {}
            CommandGroup(replacing: .newItem) {
                Button(L("新建任务")) { NotificationCenter.default.post(name: .newTask, object: nil) }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .undoRedo) {
                Button(L("撤销上次操作")) { store.undo() }
                    .disabled(store.undoLabel == nil)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}

private struct MainWindowRegistration: NSViewRepresentable {
    let appDelegate: OnePageAppDelegate
    let background: Color

    func makeNSView(context: Context) -> RegistrationView {
        let view = RegistrationView()
        view.appDelegate = appDelegate
        return view
    }

    func updateNSView(_ view: RegistrationView, context: Context) {
        view.window?.backgroundColor = NSColor(background)
    }

    final class RegistrationView: NSView {
        weak var appDelegate: OnePageAppDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Install after SwiftUI finishes attaching its own window delegate.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window else { return }
                appDelegate?.registerMainWindow(window)
            }
        }
    }
}

private final class MainWindowCloseHandler: NSObject, NSWindowDelegate {
    weak var originalDelegate: (any NSWindowDelegate)?

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if let originalDelegate, originalDelegate.responds(to: selector) { return originalDelegate }
        return super.forwardingTarget(for: selector)
    }
}

@MainActor
private final class OnePageAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private let closeHandler = MainWindowCloseHandler()
    private var quitRequested = false
    private var languageSubscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let icon = AppArtwork.loadIcon() ?? NSImage(
            systemSymbolName: "checkmark.rectangle.portrait", accessibilityDescription: L("一页待办")
        )
        icon?.size = NSSize(width: 22, height: 22)
        item.button?.image = icon
        item.button?.target = self
        item.button?.action = #selector(handleStatusClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.isVisible = true
        statusItem = item
        updateLocalizedStatusItem()
        languageSubscription = LanguageSettings.shared.$effectiveLanguage
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateLocalizedStatusItem() }
    }

    private func updateLocalizedStatusItem() {
        statusItem?.button?.setAccessibilityLabel(L("一页待办"))
        statusItem?.button?.toolTip = L("一页待办")
        mainWindow?.title = L("一页待办")
    }

    func registerMainWindow(_ window: NSWindow) {
        mainWindow = window
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Style.background)
        guard window.delegate !== closeHandler else { return }
        closeHandler.originalDelegate = window.delegate
        window.delegate = closeHandler
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard mainWindow != nil else { return true }
        showMainWindow()
        return false
    }

    @objc private func handleStatusClick(_ button: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            let quit = menu.addItem(withTitle: L("退出一页待办"), action: #selector(requestQuit), keyEquivalent: "")
            quit.target = self
            let bottom = button.isFlipped ? button.bounds.maxY : button.bounds.minY
            quitRequested = false
            menu.popUp(positioning: nil, at: NSPoint(x: button.bounds.minX, y: bottom), in: button)
            if quitRequested {
                statusItem?.isVisible = false
                // Keep the icon drawable while the system removes its menu bar slot.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { NSApp.terminate(nil) }
            }
        } else {
            showMainWindow()
        }
    }

    @objc private func requestQuit() {
        quitRequested = true
    }

    private func showMainWindow() {
        guard let window = mainWindow else { return }
        if NSApp.isHidden { NSApp.unhide(nil) }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

private enum AppArtwork {
    static func loadIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

extension Notification.Name {
    static let newTask = Notification.Name("OnePage.newTask")
}

enum AppMode: Hashable {
    case tasks, calendar
}

enum Destination: Hashable {
    case today, all, ungrouped, group(UUID)
}

struct ContentView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @EnvironmentObject private var store: Store
    @State private var destination = Destination.today
    @State private var selectedID: UUID?
    @State private var addingTask = false
    @State private var editingGroup = false
    @State private var groupID: UUID?
    @State private var groupName = ""
    @State private var showCompleted = true
    @State private var hoveredTaskID: UUID?
    @State private var hoveredDestination: Destination?
    @State private var mode: AppMode
    @State private var hoveredMode: AppMode?
    @State private var calendarDate = Calendar.current.startOfDay(for: .now)
    @State private var calendarPeriod: CalendarPeriod
    @State private var newTaskDate: Date?
    @State private var showingCloudStatus = false
    @State private var showingSettings = false

    init(selectedID: UUID? = nil, mode: AppMode = .tasks, calendarPeriod: CalendarPeriod = .month) {
        _selectedID = State(initialValue: selectedID)
        _mode = State(initialValue: mode)
        _calendarPeriod = State(initialValue: calendarPeriod)
    }

    private var selectedTask: Todo? { store.data.tasks.first { $0.id == selectedID } }
    private var title: String {
        switch destination {
        case .today: L("今天")
        case .all: L("全部")
        case .ungrouped: L("未分组")
        case .group(let id): store.groupName(id)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                toolRail.frame(width: 68)
                Style.separator.frame(width: 1)
                if mode == .tasks {
                    sidebar.frame(width: 204)
                    Style.separator.frame(width: 1)
                }
                Group {
                    if mode == .tasks {
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            taskList(now: context.date)
                        }
                    } else {
                        TaskCalendarView(
                            selectedDate: $calendarDate, selectedTaskID: $selectedID,
                            period: $calendarPeriod, addTask: presentNewTask
                        )
                    }
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                Style.separator.frame(width: 1)
                Group {
                    if let task = selectedTask {
                        TaskDetail(task: task) { selectedID = nil }
                            .id(task.id)
                    } else {
                        emptyDetail
                    }
                }
                .frame(width: min(380, max(300, geometry.size.width * 0.265)))
                .frame(maxHeight: .infinity)
                .background(Style.detail)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Style.background)
        .foregroundStyle(Style.ink)
        .font(Style.font(14))
        .tint(Style.accent)
        .frame(minWidth: 1060, minHeight: 640)
        .environment(\.locale, language.locale)
        .sheet(isPresented: $addingTask) {
            NewTaskSheet(defaultDate: newTaskDate, defaultGroup: mode == .tasks ? currentGroup : nil) { id in
                selectedID = id
                if mode == .calendar, let date = store.data.tasks.first(where: { $0.id == id })?.date {
                    calendarDate = date
                }
            }
            .environmentObject(store)
            .environment(\.locale, language.locale)
        }
        .sheet(isPresented: $editingGroup) {
            GroupEditorSheet(groupID: groupID, initialName: groupName)
                .environmentObject(store)
                .environment(\.locale, language.locale)
        }
        .sheet(isPresented: $showingCloudStatus) {
            CloudSyncSheet()
                .environmentObject(store)
                .environment(\.locale, language.locale)
        }
        .sheet(isPresented: $showingSettings) {
            MacSettingsView()
                .environmentObject(store)
                .environment(\.locale, language.locale)
        }
        .alert(L("数据操作失败"), isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button(L("好")) { store.error = nil }
        } message: { Text(L(store.error ?? "")) }
        .overlay(alignment: .bottom) {
            if let label = store.undoLabel {
                HStack(spacing: 16) {
                    Text(L(label))
                    Button(L("撤销")) { store.undo() }.foregroundStyle(Style.accentInk)
                }
                .font(Style.font(12)).buttonStyle(.plain)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule()).shadow(color: .black.opacity(0.06), radius: 10)
                .padding(.bottom, 20)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTask)) { _ in
            presentNewTask(date: defaultTaskDate)
        }
    }

    private var defaultTaskDate: Date? {
        mode == .calendar ? calendarDate : (destination == .today ? .now : nil)
    }

    private func presentNewTask(date: Date?) {
        guard !editingGroup, !addingTask, !showingCloudStatus, !showingSettings else { return }
        newTaskDate = date
        addingTask = true
    }

    private var toolRail: some View {
        VStack(spacing: 12) {
            modeButton(L("任务列表"), symbol: "checkmark.square", target: .tasks)
            modeButton(L("日历"), symbol: "calendar", target: .calendar)
            Spacer()
            Button { showingCloudStatus = true } label: {
                VStack(spacing: 6) {
                    Image(systemName: "icloud").font(.system(size: 20, weight: .regular))
                    Text(L("同步")).font(Style.font(10))
                }
                .foregroundStyle(Style.secondaryText)
                .frame(width: 44, height: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(store.syncStatus.title)
            .accessibilityLabel(LF("iCloud 同步状态：%@", store.syncStatus.title))
            Button { showingSettings = true } label: {
                VStack(spacing: 6) {
                    Image(systemName: "gearshape").font(.system(size: 20, weight: .regular))
                    Text(L("设置")).font(Style.font(10)).lineLimit(1)
                }
                .foregroundStyle(Style.secondaryText)
                .frame(width: 56, height: 52).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(L("设置")).accessibilityLabel(L("设置"))
            .accessibilityIdentifier("settings-button")
        }
        .padding(.top, 62).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Style.toolRail)
    }

    private func modeButton(_ title: String, symbol: String, target: AppMode) -> some View {
        Button {
            guard mode != target else { return }
            mode = target
            selectedID = nil
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(mode == target ? Style.accent : Style.secondaryText)
                .frame(width: 44, height: 44)
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(mode == target ? Style.selection : (hoveredMode == target ? Style.detail.opacity(0.6) : .clear))
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
        .accessibilityAddTraits(mode == target ? .isSelected : [])
        .onHover { hoveredMode = $0 ? target : nil }
    }

    private var currentGroup: UUID? {
        if case .group(let id) = destination { return id }
        return nil
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.rectangle.portrait")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Style.brand)
                Text(L("一页待办")).font(Style.font(16, bold: true))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 28)

            navigation(L("今天"), icon: "calendar", target: .today)
            navigation(L("全部"), icon: "square.stack", target: .all)
            HStack {
                Text(L("分组")).font(Style.font(12)).foregroundStyle(Style.secondaryText)
                Spacer()
                Button { groupID = nil; groupName = ""; editingGroup = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Style.secondaryText)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L("新建分组")).accessibilityLabel(L("新建分组"))
            }
            .padding(.leading, 26).padding(.trailing, 18)
            .padding(.top, 24).padding(.bottom, 8)
            navigation(L("未分组"), icon: "tray", target: .ungrouped).onDrop(of: [UTType.text], isTargeted: nil) { providers in
                receiveTask(providers) { _ = drop($0, group: nil) }
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(store.data.groups) { group in
                        GroupNavigation(name: group.name, selected: destination == .group(group.id), select: {
                            destination = .group(group.id); selectedID = nil
                        }, drop: { drop($0, group: group.id) })
                        .contextMenu {
                            Button(L("重命名")) { groupID = group.id; groupName = group.name; editingGroup = true }
                            Button(L("删除分组"), role: .destructive) {
                                store.deleteGroup(group.id)
                                if destination == .group(group.id) { destination = .ungrouped }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 12)
            Button { presentNewTask(date: defaultTaskDate) } label: {
                HStack {
                    Image(systemName: "plus").font(.system(size: 11))
                    Text(L("新建任务"))
                    Spacer()
                    Text("⌘N").font(.system(size: 11))
                }
                .font(Style.font(11)).foregroundStyle(Style.secondaryText)
                .padding(.horizontal, 25).padding(.vertical, 12)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(.top, 58).padding(.bottom, 16)
        .frame(maxHeight: .infinity)
        .background(Style.sidebar)
    }

    private var emptyDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("任务详情")).font(Style.font(12)).foregroundStyle(Style.secondaryText)
            Spacer()
            VStack(spacing: 13) {
                Image(systemName: "text.alignleft")
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(Style.accent.opacity(0.6))
                Text(L("选择一个任务")).font(Style.font(14)).foregroundStyle(Style.secondaryText)
                Text(L("在这里查看和编辑详情")).font(Style.font(12)).foregroundStyle(Style.mutedText)
            }.frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(.horizontal, 30).padding(.top, 60).padding(.bottom, 50)
    }

    private func navigation(_ name: String, icon: String, target: Destination) -> some View {
        Button { destination = target; selectedID = nil } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .regular)).frame(width: 19)
                    .foregroundStyle(destination == target ? Style.accentInk : Style.secondaryText)
                Text(name).font(Style.font(14, bold: destination == target)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Style.ink)
            .padding(.horizontal, 14).frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(destination == target ? Style.selection : (hoveredDestination == target ? Style.selection.opacity(0.5) : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 12)
        .onHover { hoveredDestination = $0 ? target : nil }
        .accessibilityAddTraits(destination == target ? .isSelected : [])
    }

    private func drop(_ items: [String], group: UUID?) -> Bool {
        guard let item = items.first, let id = UUID(uuidString: item), store.data.tasks.contains(where: { $0.id == id }) else { return false }
        store.move(id, to: group)
        return true
    }

    private func tasks(now: Date) -> [Todo] {
        let calendar = Calendar.current
        return store.data.tasks.filter { task in
            switch destination {
            case .today:
                if let completion = task.completedAt { return calendar.isDate(completion, inSameDayAs: now) }
                return task.date.map { $0 < calendar.startOfDay(for: now) || calendar.isDate($0, inSameDayAs: now) } ?? false
            case .all: return true
            case .ungrouped: return task.groupID == nil
            case .group(let id): return task.groupID == id
            }
        }.sorted {
            let lhs = $0.date ?? .distantFuture, rhs = $1.date ?? .distantFuture
            return lhs == rhs ? $0.createdAt < $1.createdAt : lhs < rhs
        }
    }

    private func taskList(now: Date) -> some View {
        let visible = tasks(now: now)
        let pending = visible.filter { $0.completedAt == nil }
        let completed = visible.filter { $0.completedAt != nil }
        let overdue = pending.filter { ($0.date ?? .distantFuture) < Calendar.current.startOfDay(for: now) }
        let upcoming = pending.filter { !overdue.contains($0) }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(title).font(Style.font(28, bold: true)).lineLimit(1).help(title)
                    Text(headerDate(now))
                        .font(Style.font(13)).foregroundStyle(Style.secondaryText)
                }
                Spacer(minLength: 16)
                Button { presentNewTask(date: defaultTaskDate) } label: {
                    Label(L("新建任务"), systemImage: "plus")
                        .font(Style.font(12, bold: true))
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(Style.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).fixedSize().help(L("新建任务 ⌘N"))
            }.padding(.bottom, 24)
            Style.separator.frame(height: 1).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !overdue.isEmpty {
                        section(L("逾期"), tasks: overdue, now: now)
                    }
                    if destination == .today {
                        if !upcoming.isEmpty { section(L("待办"), tasks: upcoming, now: now) }
                    } else {
                        ForEach(Array(Set(upcoming.compactMap(\.date))).sorted(), id: \.self) { date in
                            section(dateLabel(date), tasks: upcoming.filter { $0.date == date }, now: now)
                        }
                        let unscheduled = upcoming.filter { $0.date == nil }
                        if !unscheduled.isEmpty { section(L("待安排"), tasks: unscheduled, now: now) }
                    }
                    if pending.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "checkmark.circle")
                                .font(.system(size: 32, weight: .ultraLight)).foregroundStyle(Style.accent.opacity(0.6))
                            Text(L(destination == .today ? "今天没有待办" : "还没有待办")).foregroundStyle(Style.secondaryText)
                            Button(L("添加一个任务")) { presentNewTask(date: defaultTaskDate) }.buttonStyle(.plain).foregroundStyle(Style.accentInk)
                        }.frame(maxWidth: .infinity).padding(.vertical, 65)
                    }
                    if !completed.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Style.separator.frame(height: 1).padding(.bottom, 16)
                            Button { showCompleted.toggle() } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: showCompleted ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 9, weight: .medium)).frame(width: 10)
                                    Text(L("已完成")).font(Style.font(12, bold: true))
                                    Text(completed.count, format: .number).font(Style.font(12)).monospacedDigit()
                                    Spacer()
                                }
                                .foregroundStyle(Style.secondaryText)
                                .padding(.horizontal, 8).padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(LF("已完成 %ld", completed.count))
                            .accessibilityValue(L(showCompleted ? "已展开" : "已折叠"))
                            if showCompleted { ForEach(completed) { row($0, now: now) } }
                        }
                    }
                }.padding(.bottom, 32)
            }.scrollIndicators(.hidden)
        }.padding(.horizontal, 30).padding(.top, 52)
    }

    private func section(_ name: String, tasks: [Todo], now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(name).font(Style.font(12, bold: true))
                Text(tasks.count, format: .number).font(Style.font(12)).foregroundStyle(Style.secondaryText).monospacedDigit()
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(LF("%@，共 %ld 项任务", name, tasks.count))
            .accessibilityAddTraits(.isHeader)
            ForEach(tasks) { row($0, now: now) }
        }
    }

    private func row(_ task: Todo, now: Date) -> some View {
        HStack(spacing: 12) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.completedAt == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(task.completedAt == nil ? Style.mutedText : Style.accent)
                    .frame(width: 24, height: 32)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(task.completedAt == nil ? LF("完成 %@", task.displayTitle) : LF("恢复 %@", task.displayTitle))
            VStack(alignment: .leading, spacing: 5) {
                Text(task.displayTitle).font(Style.font(15))
                    .strikethrough(task.completedAt != nil).lineLimit(1)
                    .foregroundStyle(task.completedAt == nil ? Style.ink : Style.secondaryText)
                if task.completedAt == nil, let details = task.details?.trimmingCharacters(in: .whitespacesAndNewlines), !details.isEmpty {
                    Text(details.replacingOccurrences(of: "\n", with: " "))
                        .font(Style.font(12)).foregroundStyle(Style.secondaryText).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let date = task.date, date < Calendar.current.startOfDay(for: now), task.completedAt == nil {
                Text(date.formatted(.dateTime.month().day().locale(L10n.locale)))
                    .font(Style.font(12)).foregroundStyle(Style.overdue).fixedSize()
            } else if task.groupID != nil {
                Text(store.groupName(task.groupID)).font(Style.font(12)).foregroundStyle(Style.secondaryText)
                    .lineLimit(1).frame(maxWidth: 88, alignment: .trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(minHeight: 60)
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(selectedID == task.id ? Style.selection : (hoveredTaskID == task.id ? Style.sidebar : .clear))
        }
        .contentShape(Rectangle()).onTapGesture { selectedID = task.id }
        .onHover { hoveredTaskID = $0 ? task.id : nil }
        .help(task.displayTitle)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selectedID == task.id ? .isSelected : [])
        .accessibilityAction(named: Text(L("查看任务详情"))) { selectedID = task.id }
        .onDrag { NSItemProvider(object: task.id.uuidString as NSString) } preview: {
            Text(task.displayTitle).font(Style.font(14)).padding(10).background(Style.background)
        }
        .contextMenu {
            Button(L(task.completedAt == nil ? "完成任务" : "恢复任务")) { store.toggle(task.id) }
            Menu(L("移动到")) {
                Button(L("未分组")) { store.move(task.id, to: nil) }
                ForEach(store.data.groups) { group in Button(group.name) { store.move(task.id, to: group.id) } }
            }
            Button(L("删除任务"), role: .destructive) { store.deleteTask(task.id) }
        }
    }
}

func dateLabel(_ date: Date?) -> String {
    guard let date else { return L("未安排") }
    if Calendar.current.isDateInToday(date) { return L("今天") }
    if Calendar.current.isDateInTomorrow(date) { return L("明天") }
    return date.formatted(.dateTime.year().month().day().locale(L10n.locale))
}

func headerDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = L10n.locale
    formatter.dateFormat = L10n.dateFormat("M月d日 EEEE", "EEEE, MMM d")
    return formatter.string(from: date)
}

struct GroupNavigation: View {
    let name: String
    let selected: Bool
    let select: () -> Void
    let drop: ([String]) -> Bool
    @State private var targeted = false
    @State private var hovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.system(size: 16, weight: .regular)).frame(width: 19)
                    .foregroundStyle(selected || targeted ? Style.accentInk : Style.secondaryText)
                Text(name).font(Style.font(14, bold: selected)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Style.ink)
            .padding(.horizontal, 14).frame(height: 40)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected || targeted ? Style.selection : (hovered ? Style.selection.opacity(0.5) : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(targeted ? Style.accent : .clear, style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 12)
        .help(name).onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .onDrop(of: [UTType.text], isTargeted: $targeted) { providers in
            receiveTask(providers) { _ = drop($0) }
        }
    }
}

@MainActor
func receiveTask(_ providers: [NSItemProvider], action: @escaping @MainActor ([String]) -> Void) -> Bool {
    guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
    _ = provider.loadObject(ofClass: NSString.self) { object, _ in
        guard let value = object as? String else { return }
        Task { @MainActor in action([value]) }
    }
    return true
}

struct TaskDetail: View {
    @ObservedObject private var language = LanguageSettings.shared
    @EnvironmentObject private var store: Store
    let task: Todo
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("任务详情")).font(Style.font(12)).foregroundStyle(Style.secondaryText)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Style.secondaryText)
                        .frame(width: 26, height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(L("关闭详情")).accessibilityLabel(L("关闭详情"))
            }.padding(.bottom, 24)
            TextField(L("任务标题"), text: Binding(get: { task.title }, set: { value in store.update(task.id) { $0.title = value } }), axis: .vertical)
                .textFieldStyle(.plain).font(Style.font(22, bold: true)).lineLimit(1...5)
                .accessibilityLabel(L("任务标题"))
                .padding(.bottom, 24)
            VStack(spacing: 12) {
                DateControl(date: Binding(get: { task.date }, set: { value in store.update(task.id) { $0.date = value } }))
                GroupControl(groupID: Binding(get: { task.groupID }, set: { store.move(task.id, to: $0) }))
            }
            Style.separator.frame(height: 1).padding(.vertical, 24)
            Text(L("备注")).font(Style.font(12)).foregroundStyle(Style.secondaryText).padding(.bottom, 12)
            TextEditor(text: Binding(get: { task.details ?? "" }, set: { value in
                store.update(task.id) { $0.details = value.isEmpty ? nil : value }
            }))
            .font(Style.font(14)).lineSpacing(6)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)
            .accessibilityLabel(L("任务详情"))
            .overlay(alignment: .topLeading) {
                if task.details?.isEmpty != false {
                    Text(L("添加任务详情…"))
                        .font(Style.font(13)).foregroundStyle(Style.mutedText)
                        .padding(.leading, 5).padding(.top, 1)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            Button { store.deleteTask(task.id) } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .regular)).foregroundStyle(Style.secondaryText)
                    .frame(width: 32, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help(L("删除任务")).accessibilityLabel(L("删除任务"))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 14)
        }
        .padding(.horizontal, 30).padding(.top, 53).padding(.bottom, 22)
        .background(Style.detail)
    }
}

struct DateControl: View {
    @ObservedObject private var language = LanguageSettings.shared
    @Binding var date: Date?
    @State private var calendarVisible = false
    var body: some View {
        HStack(spacing: 16) {
            Label(L("日期"), systemImage: "calendar").foregroundStyle(Style.secondaryText)
            Spacer(minLength: 0)
            Button { calendarVisible = true } label: {
                HStack(spacing: 8) {
                    Text(dateLabel(date)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9))
                }.foregroundStyle(Style.ink)
            }
            .buttonStyle(.plain).help(L("设置日期")).accessibilityLabel(L("设置日期"))
            .popover(isPresented: $calendarVisible) {
                MonthCalendar(date: $date) { calendarVisible = false }
                    .environment(\.locale, language.locale)
            }
        }.font(Style.font(13)).frame(minHeight: 32)
    }
}

struct GroupControl: View {
    @ObservedObject private var language = LanguageSettings.shared
    @EnvironmentObject private var store: Store
    @Binding var groupID: UUID?
    var body: some View {
        HStack(spacing: 16) {
            Label(L("分组"), systemImage: "folder").foregroundStyle(Style.secondaryText)
            Spacer(minLength: 0)
            Menu {
                Button(L("未分组")) { groupID = nil }
                ForEach(store.data.groups) { group in Button(group.name) { groupID = group.id } }
            } label: {
                Text(store.groupName(groupID)).foregroundStyle(Style.ink).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 130, alignment: .trailing)
            .help(store.groupName(groupID)).accessibilityLabel(L("选择分组"))
        }.font(Style.font(13)).frame(minHeight: 32)
    }
}

struct MacSettingsView: View {
    @ObservedObject private var language = LanguageSettings.shared
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    private let themes = ThemeSettings.shared
    @State private var pendingLanguage: AppLanguagePreference
    @State private var pendingTheme: AppTheme

    init() {
        _pendingLanguage = State(initialValue: LanguageSettings.shared.preference)
        _pendingTheme = State(initialValue: ThemeSettings.shared.current)
    }

    private var hasChanges: Bool {
        pendingLanguage != language.preference || pendingTheme != themes.current
    }

    private var applicationName: String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        if let name, !name.isEmpty, name != "OnePage", name != "一页待办" { return name }
        return L("一页待办")
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("未知")
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? L("未知")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(L("设置"), systemImage: "gearshape")
                .font(Style.font(20, bold: true)).foregroundStyle(Style.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("settings-title")
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(L("应用信息")).font(Style.font(12)).foregroundStyle(Style.secondaryText)
                        Text(applicationName).font(Style.font(20, bold: true))
                        Text(LF("版本 %@（构建 %@）", version, build))
                            .font(Style.font(12)).foregroundStyle(Style.secondaryText)
                        Text(L("任务保存在本机，可通过 iCloud 在设备间同步。"))
                            .font(Style.font(13)).foregroundStyle(Style.secondaryText)
                            .lineSpacing(6).fixedSize(horizontal: false, vertical: true)
                        Label(store.syncStatus.title, systemImage: store.hasCloudConnection ? "icloud" : "internaldrive")
                            .font(Style.font(13)).foregroundStyle(Style.secondaryText)
                    }
                    Style.separator.frame(height: 1)
                    ThemeSelectionView(selection: $pendingTheme, current: themes.current)
                    Style.separator.frame(height: 1)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(L("语言"))
                            Spacer()
                            Menu {
                                ForEach(AppLanguagePreference.allCases) { preference in
                                    Button { pendingLanguage = preference } label: {
                                        if pendingLanguage == preference {
                                            Label(preference.displayName, systemImage: "checkmark")
                                        } else {
                                            Text(preference.displayName)
                                        }
                                    }
                                    .accessibilityIdentifier("language-\(preference.rawValue)")
                                }
                            } label: {
                                Text(pendingLanguage.displayName)
                                    .frame(minWidth: 132, alignment: .leading)
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel(L("语言"))
                            .accessibilityValue(pendingLanguage.displayName)
                            .accessibilityIdentifier("settings-language-picker")
                        }
                        HStack(spacing: 8) {
                            Text(L("当前语言"))
                            Text(language.preference.displayName)
                            Spacer(minLength: 0)
                        }
                        .font(Style.font(12)).foregroundStyle(Style.secondaryText)
                        if pendingLanguage != language.preference {
                            Label(L("尚未确认"), systemImage: "circle.dotted")
                                .font(Style.font(12)).foregroundStyle(Style.accent)
                        }
                        Text(L("点击“确认”后生效；取消或关闭不会保存。"))
                            .font(Style.font(13)).foregroundStyle(Style.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.trailing, 8).padding(.bottom, 8)
            }
            .frame(height: 430)
            Style.separator.frame(height: 1)
            HStack {
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(.plain)
                    .foregroundStyle(Style.secondaryText)
                Spacer()
                Button {
                    themes.current = pendingTheme
                    language.preference = pendingLanguage
                    language.refreshSystemLanguage()
                    dismiss()
                } label: {
                    Text(L("确认"))
                        .font(Style.font(12, bold: true)).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Style.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.plain)
                .disabled(!hasChanges)
                .opacity(hasChanges ? 1 : 0.45)
                .accessibilityIdentifier("confirm-language")
            }
        }
        .font(Style.font(14)).foregroundStyle(Style.ink).tint(Style.accent)
        .padding(28).frame(width: 520).background(Style.detail)
        .environment(\.locale, language.locale)
        .onAppear {
            pendingLanguage = language.preference
            pendingTheme = themes.current
            language.refreshSystemLanguage()
        }
        .onDisappear {
            pendingLanguage = language.preference
            pendingTheme = themes.current
        }
    }
}

struct CloudSyncSheet: View {
    @ObservedObject private var language = LanguageSettings.shared
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Label(L("iCloud 同步"), systemImage: "icloud")
                .font(Style.font(20, bold: true)).foregroundStyle(Style.ink)
            VStack(alignment: .leading, spacing: 12) {
                Text(store.syncStatus.title).font(Style.font(16, bold: true))
                Text(store.syncStatus.detail).font(Style.font(13))
                    .foregroundStyle(Style.secondaryText).lineSpacing(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("同步内容：任务、日期、分组、完成状态和备注。"))
                .font(Style.font(12)).foregroundStyle(Style.secondaryText)
            Style.separator.frame(height: 1)
            HStack {
                Button(L("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(.plain)
                    .foregroundStyle(Style.secondaryText)
                Spacer()
                Button {
                    Task {
                        await store.syncNow()
                        if store.hasCloudConnection { NSApp.registerForRemoteNotifications() }
                    }
                } label: {
                    Text(L(store.syncStatus.isSyncing ? "同步中…" : "立即同步"))
                        .font(Style.font(12, bold: true)).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Style.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(store.syncStatus.isSyncing || store.syncStatus == .notConfigured)
                .opacity(store.syncStatus.isSyncing || store.syncStatus == .notConfigured ? 0.45 : 1)
            }
        }
        .font(Style.font(14)).foregroundStyle(Style.ink)
        .padding(32).frame(width: 470).background(Style.detail)
        .environment(\.locale, language.locale)
    }
}

struct GroupEditorSheet: View {
    @ObservedObject private var language = LanguageSettings.shared
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool
    let groupID: UUID?

    init(groupID: UUID? = nil, initialName: String = "") {
        self.groupID = groupID
        _name = State(initialValue: initialName)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            HStack(spacing: 9) {
                Image(systemName: "folder").font(.system(size: 14)).foregroundStyle(Style.accent)
                Text(L(groupID == nil ? "新建分组" : "重命名分组"))
                    .font(Style.font(12)).foregroundStyle(Style.secondaryText)
            }
            TextField(L("输入分组名称"), text: $name)
                .textFieldStyle(.plain).font(Style.font(24, bold: true))
                .focused($focused).onSubmit(save).accessibilityLabel(L("分组名称"))
            Text(L("把相关任务放在一起，让清单更有条理。"))
                .font(Style.font(12)).foregroundStyle(Style.secondaryText)
            Style.separator.frame(height: 1)
            HStack {
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(.plain)
                    .foregroundStyle(Style.secondaryText).padding(.vertical, 10)
                Spacer()
                Button(action: save) {
                    Text(L(groupID == nil ? "创建分组" : "保存更改"))
                        .font(Style.font(12, bold: true)).foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Style.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.plain)
                .disabled(trimmedName.isEmpty).opacity(trimmedName.isEmpty ? 0.45 : 1)
            }
        }
        .font(Style.font(14)).foregroundStyle(Style.ink).tint(Style.accent)
        .padding(32).frame(width: 450).background(Style.detail)
        .environment(\.locale, language.locale)
        .onAppear { focused = true }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if let groupID {
            store.renameGroup(groupID, name: trimmedName)
            if store.data.groups.first(where: { $0.id == groupID })?.name == trimmedName { dismiss() }
        } else if store.addGroup(trimmedName) != nil {
            dismiss()
        }
    }
}

struct NewTaskSheet: View {
    @ObservedObject private var language = LanguageSettings.shared
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var date: Date?
    @State private var groupID: UUID?
    @FocusState private var focused: Bool
    let created: (UUID) -> Void

    init(defaultDate: Date?, defaultGroup: UUID?, created: @escaping (UUID) -> Void) {
        _date = State(initialValue: defaultDate)
        _groupID = State(initialValue: defaultGroup)
        self.created = created
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 25) {
            Text(L("新建任务")).font(Style.font(12)).foregroundStyle(Style.secondaryText)
            TextField(L("准备做什么？"), text: $title).textFieldStyle(.plain).font(Style.font(24, bold: true)).focused($focused).onSubmit(add)
            DateControl(date: $date)
            GroupControl(groupID: $groupID)
            Style.separator.frame(height: 1)
            HStack {
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction).buttonStyle(.plain)
                    .foregroundStyle(Style.secondaryText).padding(.vertical, 10)
                Spacer()
                Button(action: add) {
                    Text(L("添加任务")).font(Style.font(12, bold: true))
                        .foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Style.accent, in: RoundedRectangle(cornerRadius: 8))
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.plain)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .opacity(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
            }
        }
        .font(Style.font(14)).foregroundStyle(Style.ink).tint(Style.accent)
        .padding(32).frame(width: 450).background(Style.detail)
        .environment(\.locale, language.locale)
        .onAppear { focused = true }
    }

    private func add() {
        if let id = store.addTask(title: title, date: date, groupID: groupID) { created(id); dismiss() }
    }
}
