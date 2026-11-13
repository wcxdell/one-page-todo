import AppKit
import SwiftUI
import XCTest
@testable import OnePage

final class AppearanceTests: XCTestCase {
    private static let scratchRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("qwenwork", isDirectory: true)
    private let sizes = [NSSize(width: 1360, height: 860), NSSize(width: 1060, height: 640)]

    @MainActor func testWarmIvoryAndSagePalette() throws {
        let background = try resolved(Style.background)
        let accent = try resolved(Style.accent)
        for (color, expected) in [(background, [250.0, 249.0, 246.0]), (accent, [108.0, 130.0, 111.0])] {
            for (component, value) in zip([color.redComponent, color.greenComponent, color.blueComponent], expected) {
                XCTAssertEqual(component, CGFloat(value / 255), accuracy: 0.5 / 255)
            }
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.001)
        }

        let rail = try resolved(Style.toolRail)
        let sidebar = try resolved(Style.sidebar)
        let difference = zip(
            [rail.redComponent, rail.greenComponent, rail.blueComponent],
            [sidebar.redComponent, sidebar.greenComponent, sidebar.blueComponent]
        ).map { abs($0.0 - $0.1) }.max() ?? 0
        XCTAssertGreaterThan(difference, 0.5 / 255, "The reserved rail must differ from the sidebar.")

        for (name, token) in [
            ("background", Style.background), ("sidebar", Style.sidebar), ("toolRail", Style.toolRail),
            ("detail", Style.detail), ("accent", Style.accent), ("selection", Style.selection),
            ("ink", Style.ink), ("secondaryText", Style.secondaryText), ("separator", Style.separator)
        ] {
            let color = try resolved(token)
            XCTAssertTrue(
                [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
                    .allSatisfy { $0.isFinite && (0...1).contains($0) },
                "Invalid sRGB components for Style.\(name)"
            )
        }
    }

    @MainActor func testTaskLifecycleUndoAndIsolatedPersistence() throws {
        let url = try newStoreURL()
        let unrelatedURL = try newStoreURL()
        let unrelated = Store(fileURL: unrelatedURL)
        _ = try XCTUnwrap(unrelated.addTask(title: "Unrelated fixture", date: nil, groupID: nil))
        let unrelatedBytes = try Data(contentsOf: unrelatedURL)

        let store = Store(fileURL: url)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.data, SavedData())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let firstGroup = try XCTUnwrap(store.addGroup("示例项目"))
        let secondGroup = try XCTUnwrap(store.addGroup("日常安排"))
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let id = try XCTUnwrap(store.addTask(title: "  示例任务 \n", date: date, groupID: firstGroup))
        XCTAssertEqual(store.data.tasks.count, 1)
        XCTAssertEqual(store.data.tasks.first?.title, "示例任务")
        XCTAssertEqual(store.data.tasks.first?.date, Calendar.current.startOfDay(for: date))
        XCTAssertEqual(store.data.tasks.first?.groupID, firstGroup)
        assertPersisted(store, at: url)

        let revisedDate = Calendar.current.startOfDay(for: date.addingTimeInterval(172_800))
        let notes = "检查示例清单\n记录下一步安排"
        store.update(id) {
            $0.title = "更新后的示例任务"
            $0.details = notes
            $0.date = revisedDate
        }
        XCTAssertEqual(store.data.tasks.first?.title, "更新后的示例任务")
        XCTAssertEqual(store.data.tasks.first?.details, notes)
        XCTAssertEqual(store.data.tasks.first?.date, revisedDate)
        assertPersisted(store, at: url)

        store.renameGroup(secondGroup, name: "  示例归档  ")
        XCTAssertEqual(store.groupName(secondGroup), "示例归档")
        assertPersisted(store, at: url)
        store.move(id, to: secondGroup)
        XCTAssertEqual(store.data.tasks.first?.groupID, secondGroup)
        assertPersisted(store, at: url)
        store.move(id, to: nil)
        XCTAssertNil(store.data.tasks.first?.groupID)
        assertPersisted(store, at: url)
        store.move(id, to: secondGroup)
        XCTAssertEqual(store.data.tasks.first?.groupID, secondGroup)
        assertPersisted(store, at: url)

        store.toggle(id)
        XCTAssertNotNil(store.data.tasks.first?.completedAt)
        assertPersisted(store, at: url)
        store.toggle(id)
        XCTAssertNil(store.data.tasks.first?.completedAt)
        assertPersisted(store, at: url)

        let beforeGroupDeletion = store.data
        store.deleteGroup(secondGroup)
        XCTAssertFalse(store.data.groups.contains { $0.id == secondGroup })
        XCTAssertEqual(store.data.tasks.count, 1)
        XCTAssertNil(store.data.tasks.first?.groupID)
        assertPersisted(store, at: url)
        store.undo()
        XCTAssertEqual(store.data, beforeGroupDeletion)
        assertPersisted(store, at: url)

        let beforeDeletion = store.data
        store.deleteTask(id)
        XCTAssertTrue(store.data.tasks.isEmpty)
        XCTAssertNotNil(store.undoLabel)
        assertPersisted(store, at: url)
        store.undo()
        XCTAssertEqual(store.data, beforeDeletion)
        XCTAssertNil(store.undoLabel)
        assertPersisted(store, at: url)

        store.update(id) { $0.details = nil; $0.date = nil }
        XCTAssertNil(store.data.tasks.first?.details)
        XCTAssertNil(store.data.tasks.first?.date)
        assertPersisted(store, at: url)
        XCTAssertEqual(try Data(contentsOf: unrelatedURL), unrelatedBytes)
        assertPersisted(unrelated, at: unrelatedURL)
    }

    @MainActor func testSelectedContentRendersAtBothSizes() throws {
        let fixture = try makeFixture()
        let notes = try XCTUnwrap(fixture.selected.details)
        for size in sizes {
            try render(
                ContentView(selectedID: fixture.selected.id), store: fixture.store, fileURL: fixture.url,
                size: size, name: "selected", expectedNotes: notes
            )
        }
    }

    @MainActor func testEmptySelectionRendersAtBothSizes() throws {
        let fixture = try makeFixture()
        for size in sizes {
            try render(
                ContentView(selectedID: nil), store: fixture.store, fileURL: fixture.url,
                size: size, name: "empty-selection"
            )
        }
    }

    @MainActor func testNewTaskSheetRenders() throws {
        let fixture = try makeFixture()
        let sheet = NewTaskSheet(defaultDate: fixture.selected.date, defaultGroup: fixture.selected.groupID) { _ in
            XCTFail("Rendering the sheet must not create a task.")
        }
        try render(
            sheet, store: fixture.store, fileURL: fixture.url,
            size: NSSize(width: 520, height: 440), name: "new-task-sheet"
        )
    }

    @MainActor func testCalendarContentRendersAtBothSizes() throws {
        let fixture = try makeFixture()
        let today = Calendar.current.startOfDay(for: .now)
        for (offset, title) in [(2, "整理周末计划"), (5, "阅读与记录"), (9, "准备项目资料"), (14, "月度回顾")] {
            let date = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: offset, to: today))
            _ = try XCTUnwrap(fixture.store.addTask(title: title, date: date, groupID: nil))
        }
        _ = try XCTUnwrap(fixture.store.addTask(title: "还未确定日期的安排", date: nil, groupID: nil))
        for period in CalendarPeriod.allCases {
            for size in sizes {
                try render(
                    ContentView(selectedID: fixture.selected.id, mode: .calendar, calendarPeriod: period),
                    store: fixture.store, fileURL: fixture.url, size: size,
                    name: "calendar-\(period.rawValue)", expectedNotes: fixture.selected.details
                )
            }
        }
    }

    @MainActor func testUnconfiguredCloudStatusSheetRendersWithoutWriting() throws {
        let fixture = try makeFixture()
        try render(
            CloudSyncSheet(), store: fixture.store, fileURL: fixture.url,
            size: NSSize(width: 540, height: 520), name: "icloud-status-unconfigured"
        )
        XCTAssertEqual(fixture.store.syncStatus, .notConfigured)
    }

    @MainActor func testSettingsSheetRendersWithoutChangingTasks() throws {
        let fixture = try makeFixture()
        try render(
            MacSettingsView(), store: fixture.store, fileURL: fixture.url,
            size: NSSize(width: 540, height: 560), name: "settings-language"
        )
    }

    @MainActor func testNewGroupSheetRendersWithoutSaving() throws {
        let fixture = try makeFixture()
        try render(
            GroupEditorSheet(), store: fixture.store, fileURL: fixture.url,
            size: NSSize(width: 520, height: 360), name: "new-group-sheet"
        )
    }

    @MainActor func testRenameGroupSheetRendersWithoutSaving() throws {
        let fixture = try makeFixture()
        let group = try XCTUnwrap(fixture.store.data.groups.first)
        try render(
            GroupEditorSheet(groupID: group.id, initialName: group.name),
            store: fixture.store, fileURL: fixture.url,
            size: NSSize(width: 520, height: 360), name: "rename-group-sheet"
        )
    }

    @MainActor func testGroupNameValidationAndRenamePreserveTasks() throws {
        let fixture = try makeFixture()
        let original = fixture.store.data
        XCTAssertNil(fixture.store.addGroup("  \n  "))
        let group = try XCTUnwrap(original.groups.first)
        fixture.store.renameGroup(group.id, name: "  \n  ")
        XCTAssertEqual(fixture.store.data, original)
        fixture.store.renameGroup(group.id, name: "  新的分组名称  ")
        XCTAssertEqual(fixture.store.groupName(group.id), "新的分组名称")
        XCTAssertEqual(fixture.store.data.tasks, original.tasks)
        assertPersisted(fixture.store, at: fixture.url)
    }

    private func newStoreURL() throws -> URL {
        try FileManager.default.createDirectory(at: Self.scratchRoot, withIntermediateDirectories: true)
        let directory = Self.scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory.appendingPathComponent("\(UUID().uuidString).json")
    }

    @MainActor private func assertPersisted(
        _ store: Store, at url: URL, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file: file, line: line)
        let reopened = Store(fileURL: url)
        XCTAssertNil(store.error, file: file, line: line)
        XCTAssertNil(reopened.error, file: file, line: line)
        XCTAssertEqual(reopened.data, store.data, file: file, line: line)
    }

    @MainActor private func resolved(_ color: Color) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(color).usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(result)
    }

    @MainActor private func makeFixture() throws -> (store: Store, url: URL, selected: Todo) {
        let group = TaskGroup(name: "工作")
        let life = TaskGroup(name: "生活")
        let study = TaskGroup(name: "学习")
        let sport = TaskGroup(name: "运动")
        let date = Calendar.current.startOfDay(for: .now)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: date))
        let selected = Todo(
            title: "梳理本周工作计划",
            details: "明确优先级，留出专注时间。\n上午处理重要事项，下午集中沟通。\n每天只安排三件真正重要的事。",
            date: date, groupID: group.id, createdAt: date
        )
        let data = SavedData(tasks: [
            Todo(title: "整理待处理事项", date: yesterday, groupID: group.id, createdAt: yesterday),
            Todo(title: "预约车辆保养", date: yesterday, groupID: life.id, createdAt: yesterday.addingTimeInterval(60)),
            selected,
            Todo(title: "英语口语练习 20 分钟", date: date, groupID: study.id, createdAt: date.addingTimeInterval(60)),
            Todo(title: "羽毛球训练", date: date, groupID: sport.id, createdAt: date.addingTimeInterval(120)),
            Todo(title: "整理读书笔记", date: date, groupID: study.id, createdAt: date.addingTimeInterval(180)),
            Todo(title: "阅读 20 分钟", date: date, completedAt: date, createdAt: date.addingTimeInterval(240)),
            Todo(title: "整理桌面", date: date, completedAt: date, createdAt: date.addingTimeInterval(300))
        ], groups: [group, life, study, sport])
        let url = try newStoreURL()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(data).write(to: url, options: .withoutOverwriting)
        let store = Store(fileURL: url)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.data, data)
        return (store, url, selected)
    }

    @MainActor private func textViews(in view: NSView) -> [NSTextView] {
        let own = (view as? NSTextView).map { [$0] } ?? []
        return own + view.subviews.flatMap { textViews(in: $0) }
    }

    @MainActor private func render<V: View>(
        _ view: V, store: Store, fileURL: URL, size: NSSize, name: String, expectedNotes: String? = nil
    ) throws {
        let originalData = store.data
        let originalBytes = try Data(contentsOf: fileURL)
        _ = NSApplication.shared
        let bounds = NSRect(origin: .zero, size: size)
        let hostingView = NSHostingView(rootView: view
            .environmentObject(store)
            .environment(\.locale, Locale(identifier: "zh_CN"))
            .environment(\.colorScheme, .light)
            .transaction { $0.disablesAnimations = true }
        )
        hostingView.sizingOptions = [.minSize, .intrinsicContentSize]
        hostingView.frame = bounds
        let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        window.contentView = hostingView
        window.setContentSize(size)
        defer {
            window.contentView = nil
            window.close()
        }
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        hostingView.layoutSubtreeIfNeeded()

        let minimum = hostingView.fittingSize
        XCTAssertTrue(minimum.width.isFinite && minimum.height.isFinite)
        XCTAssertGreaterThan(minimum.width, 0)
        XCTAssertGreaterThan(minimum.height, 0)
        XCTAssertLessThanOrEqual(minimum.width, size.width + 0.5, "\(name) minimum width: \(minimum)")
        XCTAssertLessThanOrEqual(minimum.height, size.height + 0.5, "\(name) minimum height: \(minimum)")
        XCTAssertEqual(hostingView.bounds.width, size.width, accuracy: 0.5)
        XCTAssertEqual(hostingView.bounds.height, size.height, accuracy: 0.5)
        if let expectedNotes {
            XCTAssertTrue(
                textViews(in: hostingView).contains { $0.string == expectedNotes },
                "The selected task's native TextEditor must be present, including its notes."
            )
        }

        let capture = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: capture)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        bitmap.size = size
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(bounds)
        capture.draw(in: bounds)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var samples = Set<NSColor>()
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) {
                if let color = bitmap.colorAt(x: x, y: y), color.alphaComponent > 0 {
                    samples.insert(color)
                }
            }
        }
        XCTAssertGreaterThan(samples.count, 1, "\(name) must not render a blank or uniform image.")
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertFalse(png.isEmpty)
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(decoded.pixelsWide, Int(size.width))
        XCTAssertEqual(decoded.pixelsHigh, Int(size.height))
        let directory = Self.scratchRoot.appendingPathComponent("onepage-appearance-check", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(
            "\(name)-\(Int(size.width))x\(Int(size.height))-\(UUID().uuidString).png"
        )
        try png.write(to: output, options: .withoutOverwriting)
        XCTAssertEqual(try Data(contentsOf: output), png)
        XCTAssertEqual(store.data, originalData, "Rendering must not mutate the fixture.")
        XCTAssertEqual(try Data(contentsOf: fileURL), originalBytes)
        assertPersisted(store, at: fileURL)
    }
}
