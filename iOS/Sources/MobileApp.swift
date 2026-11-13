import SwiftUI
import UIKit

@main
struct OnePageMobileApp: App {
    @StateObject private var store: Store
    @ObservedObject private var language = LanguageSettings.shared
    @Environment(\.scenePhase) private var scenePhase
    private let appearance: MobileAppearance

    init() {
        var selectedStore: Store?
        var selectedAppearance = MobileAppearance.current
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--test-store"), arguments.indices.contains(index + 1),
           let id = UUID(uuidString: arguments[index + 1]) {
            let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("UITests", isDirectory: true).appendingPathComponent(id.uuidString + ".json")
            let isolated = Store(fileURL: url)
            if arguments.contains("--preview-data"), isolated.data.tasks.isEmpty, isolated.data.groups.isEmpty {
                Self.seedPreview(isolated)
            }
            selectedStore = isolated
        }
        if arguments.contains("--legacy-ui") { selectedAppearance = MobileAppearance(usesGlass: false) }
        #endif
        _store = StateObject(wrappedValue: selectedStore ?? Store())
        appearance = selectedAppearance
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(store)
                .environment(\.mobileAppearance, appearance)
                .environment(\.locale, language.locale)
                .preferredColorScheme(.light)
                .tint(Style.accent)
                .task {
                    await store.startSync()
                    if store.hasCloudConnection { UIApplication.shared.registerForRemoteNotifications() }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        language.refreshSystemLanguage()
                        Task {
                            await store.syncNow()
                            if store.hasCloudConnection { UIApplication.shared.registerForRemoteNotifications() }
                        }
                    }
                }
        }
    }

    #if DEBUG
    @MainActor private static func seedPreview(_ store: Store) {
        let work = store.addGroup("工作"), life = store.addGroup("生活")
        let study = store.addGroup("学习"), sport = store.addGroup("运动")
        let today = Calendar.current.startOfDay(for: .now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)
        _ = store.addTask(title: "整理待处理事项", date: yesterday, groupID: work)
        _ = store.addTask(title: "预约车辆保养", date: yesterday, groupID: life)
        if let id = store.addTask(title: "梳理本周工作计划", date: today, groupID: work) {
            store.update(id) { $0.details = "明确优先级，留出专注时间。\n上午处理重要事项，下午集中沟通。\n每天只安排三件真正重要的事。" }
        }
        _ = store.addTask(title: "英语口语练习 20 分钟", date: today, groupID: study)
        _ = store.addTask(title: "羽毛球训练", date: today, groupID: sport)
        _ = store.addTask(title: "整理读书笔记", date: today, groupID: study)
        for (title, group) in [("阅读 20 分钟", study), ("整理桌面", life)] {
            if let id = store.addTask(title: title, date: today, groupID: group) { store.toggle(id) }
        }
        _ = store.addTask(title: "待安排的旅行计划", date: nil, groupID: life)
    }
    #endif
}
