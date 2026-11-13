import Foundation
import XCTest

final class OnePageUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor func testEmptyLocalStoreCreateEditCompleteAndRelaunchPersistence() throws {
        let app = try launch(storeID: UUID())
        defer { app.terminate() }
        XCTAssertEqual(elements(withPrefix: "open-task-", in: app).count, 0)
        try tap("tab-lists", in: app)
        XCTAssertEqual(elements(withPrefix: "group-", in: app).count, 0)
        try tap("add-group", in: app)
        try replaceText("group-name-field", with: "阅读清单", in: app)
        try tap("save-group", in: app)
        try requireExists(element("group-阅读清单", in: app))

        try tap("tab-tasks", in: app)
        try tap("add-task", in: app)
        try replaceText("task-title-field", with: "整理书架", in: app)
        try tap("task-group-picker", in: app)
        let groupChoice = app.buttons.matching(NSPredicate(format: "label == %@", "阅读清单")).firstMatch
        try reveal(groupChoice, in: app)
        groupChoice.tap()
        try replaceText("task-notes-field", with: "先读两页", in: app)
        try tap("save-task", in: app)
        try assertValue("detail-title-field", equals: "整理书架", in: app)
        try assertValue("detail-notes-field", equals: "先读两页", in: app)

        try replaceText("detail-title-field", with: "整理书桌", in: app)
        try replaceText("detail-notes-field", with: "再读三页", in: app)
        try tap("back-button", in: app)
        try requireExists(element("open-task-整理书桌", in: app))
        XCTAssertFalse(element("open-task-整理书架", in: app).exists)
        try tap("tab-lists", in: app)
        try tap("group-阅读清单", in: app)
        try tap("open-task-整理书桌", in: app)
        try assertValue("detail-notes-field", equals: "再读三页", in: app)
        try assertCompletion("未完成", in: app)
        try tap("detail-completion", in: app)
        try assertCompletion("已完成", in: app)
        try tap("back-button", in: app)

        app.terminate()
        app.launch()
        try requireExists(element("tab-lists", in: app))
        try tap("tab-lists", in: app)
        try tap("group-阅读清单", in: app)
        try tap("open-task-整理书桌", in: app)
        try assertValue("detail-title-field", equals: "整理书桌", in: app)
        try assertValue("detail-notes-field", equals: "再读三页", in: app)
        try assertCompletion("已完成", in: app)
    }

    @MainActor func testDisabledICloudStatusRemainsLocalAfterRetry() throws {
        let app = try launch(storeID: UUID())
        defer { app.terminate() }
        try tap("open-sync", in: app)
        try assertCloudIsNotConfigured(in: app)
        let retry = element("sync-now", in: app)
        try requireExists(retry)
        if retry.isEnabled {
            try tap("sync-now", in: app)
        }
        try assertCloudIsNotConfigured(in: app)
        try tap("back-button", in: app)
        try requireExists(element("add-task", in: app))
        XCTAssertEqual(elements(withPrefix: "open-task-", in: app).count, 0)
    }

    @MainActor func testCalendarMonthWeekAndTodayNavigation() throws {
        let app = try launch(storeID: UUID())
        defer { app.terminate() }
        try tap("tab-calendar", in: app)
        if #available(iOS 26.0, *) { try requireExists(app.segmentedControls.firstMatch) }
        for mode in ["calendar-month", "calendar-week"] {
            try tap(mode, in: app)
            try tap("calendar-today", in: app)
            let heading = element("calendar-period-title", in: app)
            try requireExists(heading)
            let initialPeriod = heading.label
            XCTAssertFalse(initialPeriod.isEmpty)
            try requireExists(element(todayIdentifier(), in: app))
            try tap(todayIdentifier(), in: app)
            try tap("calendar-next", in: app)
            try expect(NSPredicate(format: "label != %@ AND label != ''", initialPeriod), on: heading)
            try tap("calendar-previous", in: app)
            try expect(NSPredicate(format: "label == %@", initialPeriod), on: heading)
            try tap("calendar-previous", in: app)
            try expect(NSPredicate(format: "label != %@ AND label != ''", initialPeriod), on: heading)
            try tap("calendar-today", in: app)
            try expect(NSPredicate(format: "label == %@", initialPeriod), on: heading)
            try requireExists(element(todayIdentifier(), in: app))
        }
    }

    @MainActor func testNativeSystemTabBarAndNavigationBars() throws {
        let app = try launch(storeID: UUID())
        defer { app.terminate() }
        for tab in ["tab-tasks", "tab-calendar", "tab-lists", "tab-settings"] {
            try tap(tab, in: app)
            if #available(iOS 26.0, *) {
                // Assert actual platform accessibility roles, not an identifier on a custom capsule.
                try requireExists(app.tabBars.firstMatch)
                try requireExists(app.navigationBars.firstMatch)
                XCTAssertEqual(app.tabBars.buttons.count, 4)
                XCTAssertFalse(element("tabbar-classic", in: app).exists)
                XCTAssertFalse(element("tabbar-glass", in: app).exists)
            } else {
                try requireExists(element("tabbar-classic", in: app))
            }
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "native-system-bars-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }

    @MainActor func testClassicOverrideSelectsClassicTabBar() throws {
        let app = try launch(storeID: UUID(), previewData: true, legacyUI: true)
        defer { app.terminate() }
        for tab in ["tab-tasks", "tab-calendar", "tab-lists", "tab-settings"] {
            try tap(tab, in: app)
            try requireExists(element("tabbar-classic", in: app))
            XCTAssertFalse(element("tabbar-glass", in: app).exists)
            XCTAssertEqual(app.tabBars.count, 0)
            if tab == "tab-tasks" { attachScreenshot("07-经典样式", from: app) }
        }
    }

    @MainActor func testPreviewDataSixScreenScreenshotAttachments() throws {
        let app = try launch(storeID: UUID(), previewData: true)
        defer { app.terminate() }
        try tap("tab-tasks", in: app)
        let firstTask = element("open-task-梳理本周工作计划", in: app)
        try requireExists(firstTask)
        attachScreenshot("01-任务", from: app)

        try reveal(firstTask, in: app)
        firstTask.tap()
        try requireExists(element("detail-title-field", in: app))
        try requireExists(element("detail-completion", in: app))
        attachScreenshot("02-任务详情", from: app)
        try tap("back-button", in: app)

        try tap("add-task", in: app)
        try requireExists(element("task-title-field", in: app))
        try requireExists(element("save-task", in: app))
        attachScreenshot("03-新建任务", from: app)
        try tap("cancel-editor", in: app)

        try tap("tab-calendar", in: app)
        try tap("calendar-month", in: app)
        try tap("calendar-today", in: app)
        try requireExists(element("calendar-period-title", in: app))
        try requireExists(element(todayIdentifier(), in: app))
        attachScreenshot("04-日历", from: app)
        try tap("open-task-梳理本周工作计划", in: app)
        try assertValue("detail-title-field", equals: "梳理本周工作计划", in: app)
        try tap("back-button", in: app)

        try tap("tab-lists", in: app)
        try requireExists(elements(withPrefix: "group-", in: app).firstMatch)
        try requireExists(element("add-group", in: app))
        attachScreenshot("05-清单", from: app)

        try tap("tab-tasks", in: app)
        try tap("open-sync", in: app)
        try assertCloudIsNotConfigured(in: app)
        attachScreenshot("06-本地同步状态", from: app)
    }

    @MainActor func testSettingsLanguageManualOverridePersistenceAndSystemDefault() throws {
        let app = try launch(storeID: UUID(), previewData: true)
        defer { app.terminate() }
        try tap("tab-settings", in: app)
        try expect(NSPredicate(format: "label == %@", "设置"), on: element("settings-title", in: app))
        XCTAssertGreaterThan(element("tab-settings", in: app).frame.minX, element("tab-lists", in: app).frame.minX)
        try requireExists(element("settings-version", in: app))
        attachScreenshot("08-设置-中文", from: app)

        try tap("language-en", in: app)
        try expect(NSPredicate(format: "label == %@", "Settings"), on: element("settings-title", in: app))
        try expect(NSPredicate(format: "label == %@", "Tasks"), on: element("tab-tasks", in: app))
        try expect(NSPredicate(format: "label == %@", "OnePage"), on: element("settings-app-name", in: app))
        attachScreenshot("09-设置-English", from: app)
        try tap("tab-tasks", in: app)
        try requireExists(app.staticTexts["Today"])
        try requireExists(element("open-task-梳理本周工作计划", in: app))
        attachScreenshot("10-任务-English", from: app)
        try tap("open-sync", in: app)
        try expect(NSPredicate(format: "label CONTAINS %@", "iCloud not configured"), on: element("sync-status", in: app))
        try tap("back-button", in: app)
        try tap("tab-calendar", in: app)
        try requireExists(element("calendar-period-title", in: app))
        XCTAssertFalse(element("calendar-period-title", in: app).label.contains("年"))
        XCTAssertFalse(element("calendar-period-title", in: app).label.contains("月"))
        attachScreenshot("11-日历-English", from: app)

        // Relaunch against the same isolated preference key: manual English wins over zh-Hans.
        app.terminate()
        app.launch()
        try expect(NSPredicate(format: "label == %@", "Tasks"), on: element("tab-tasks", in: app))
        try tap("tab-settings", in: app)
        try expect(NSPredicate(format: "label == %@", "Settings"), on: element("settings-title", in: app))
        try tap("language-system", in: app)
        try expect(NSPredicate(format: "label == %@", "设置"), on: element("settings-title", in: app))

        // A fresh launch with English device preferences must now follow the system.
        app.terminate()
        app.launchArguments = app.launchArguments.map { $0 == "(zh-Hans)" ? "(en)" : ($0 == "zh_CN" ? "en_US" : $0) }
        app.launch()
        try expect(NSPredicate(format: "label == %@", "Tasks"), on: element("tab-tasks", in: app))
        try tap("tab-settings", in: app)
        try tap("language-zh-Hans", in: app)
        try expect(NSPredicate(format: "label == %@", "设置"), on: element("settings-title", in: app))
        app.terminate()
        app.launch()
        try expect(NSPredicate(format: "label == %@", "任务"), on: element("tab-tasks", in: app))
        try requireExists(element("open-task-梳理本周工作计划", in: app))
    }

    @MainActor private func launch(storeID: UUID, previewData: Bool = false,
                                   legacyUI: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "com.onepage.todo.ios")
        app.launchArguments = ["--test-store", storeID.uuidString,
                               "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        if previewData { app.launchArguments.append("--preview-data") }
        if legacyUI { app.launchArguments.append("--legacy-ui") }
        app.launch()
        try requireExists(element("tab-tasks", in: app))
        return app
    }

    @MainActor private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        if #available(iOS 26.0, *), !app.launchArguments.contains("--legacy-ui") {
            let tabs = ["tab-tasks": ["任务", "Tasks"], "tab-calendar": ["日历", "Calendar"],
                        "tab-lists": ["清单", "Lists"], "tab-settings": ["设置", "Settings"]]
            if let labels = tabs[identifier] {
                return app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            }
            if identifier == "back-button" { return app.navigationBars.buttons.element(boundBy: 0) }
            if identifier == "settings-title" {
                return app.navigationBars.staticTexts.matching(NSPredicate(format: "label IN %@", ["设置", "Settings"])).firstMatch
            }
            if identifier == "calendar-month" || identifier == "calendar-week" {
                let labels = identifier == "calendar-month" ? ["月", "Month"] : ["周", "Week"]
                return app.segmentedControls.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
            }
        }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor private func elements(withPrefix prefix: String, in app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }

    @MainActor private func requireExists(_ element: XCUIElement, timeout: TimeInterval = 8,
                                          file: StaticString = #filePath, line: UInt = #line) throws {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("Missing accessibility element: \(element)", file: file, line: line)
            throw UIContractFailure.missingElement
        }
    }

    @MainActor private func expect(_ predicate: NSPredicate, on element: XCUIElement,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        try requireExists(element, file: file, line: line)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: 5) == .completed else {
            XCTFail("Accessibility expectation failed: \(predicate) on \(element)", file: file, line: line)
            throw UIContractFailure.unexpectedState
        }
    }

    @MainActor private func reveal(_ target: XCUIElement, in app: XCUIApplication,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        if target.waitForExistence(timeout: 2), target.isHittable { return }
        let containers = app.tables.allElementsBoundByIndex
            + app.collectionViews.allElementsBoundByIndex
            + app.scrollViews.allElementsBoundByIndex
        // Native bars and keyboard suggestions can expose their own small scroll containers.
        // Scroll the page, never the navigation/tab/keyboard chrome.
        let pages = containers.filter { $0.isHittable && $0.frame.height > 150 && $0.frame.width > app.frame.width * 0.6 }
        if let scrollView = pages.max(by: { $0.frame.height < $1.frame.height }) {
            for _ in 0..<6 {
                if target.exists, target.isHittable { return }
                scrollView.swipeUp()
            }
            for _ in 0..<6 {
                if target.exists, target.isHittable { return }
                scrollView.swipeDown()
            }
        }
        try expect(NSPredicate(format: "hittable == YES"), on: target, file: file, line: line)
    }

    @MainActor private func tap(_ identifier: String, in app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let target = element(identifier, in: app)
        try reveal(target, in: app, file: file, line: line)
        target.tap()
    }

    @MainActor private func replaceText(_ identifier: String, with text: String, in app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let field = element(identifier, in: app)
        try reveal(field, in: app, file: file, line: line)
        field.tap()
        if let previous = field.value as? String, previous != field.placeholderValue, !previous.isEmpty {
            // Tapping a multi-line SwiftUI field can put its caret at the beginning.
            // Select all explicitly rather than assuming backspace starts at the end.
            field.press(forDuration: 1.1)
            let selectAll = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label IN %@", ["全选", "Select All"]))
                .firstMatch
            try requireExists(selectAll)
            selectAll.tap()
        }
        field.typeText(text)
        try assertValue(identifier, equals: text, in: app, file: file, line: line)
    }

    @MainActor private func assertValue(_ identifier: String, equals text: String, in app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        try expect(NSPredicate(format: "value == %@", text), on: element(identifier, in: app), file: file, line: line)
    }

    @MainActor private func assertCompletion(_ state: String, in app: XCUIApplication,
                                             file: StaticString = #filePath, line: UInt = #line) throws {
        try expect(NSPredicate(format: "value == %@ OR label == %@", state, state),
                   on: element("detail-completion", in: app), file: file, line: line)
    }

    @MainActor private func assertCloudIsNotConfigured(in app: XCUIApplication,
                                                       file: StaticString = #filePath, line: UInt = #line) throws {
        try requireExists(element("sync-title", in: app), file: file, line: line)
        try requireExists(element("sync-status", in: app), file: file, line: line)
        for text in ["未配置 iCloud", "本地数据未上传"] {
            let statusText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            try requireExists(statusText, file: file, line: line)
        }
    }

    @MainActor private func todayIdentifier() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return "calendar-day-" + formatter.string(from: Date())
    }

    @MainActor private func attachScreenshot(_ name: String, from app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private enum UIContractFailure: Error {
        case missingElement
        case unexpectedState
    }
}
