import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import OnePage

final class StoreTests: XCTestCase {
    func testDragPayloadMatchesDropTarget() async throws {
        let id = UUID().uuidString
        let provider = NSItemProvider(object: id as NSString)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.text.identifier))
        XCTAssertTrue(provider.canLoadObject(ofClass: NSString.self))
        let loaded: String = try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: object as? String ?? "") }
            }
        }
        XCTAssertEqual(loaded, id)
    }

    @MainActor func testPersistenceAndGroupDeletionUndo() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tasks.json")
        let store = Store(fileURL: url)
        let group = try XCTUnwrap(store.addGroup("工作"))
        let id = try XCTUnwrap(store.addTask(title: "整理资料", date: Date(), groupID: nil))
        store.move(id, to: group)
        XCTAssertEqual(Store(fileURL: url).data.tasks.first?.groupID, group)
        store.deleteGroup(group)
        XCTAssertNil(store.data.tasks.first?.groupID)
        XCTAssertEqual(store.data.tasks.count, 1)
        store.undo()
        XCTAssertEqual(store.data.tasks.first?.groupID, group)
        store.toggle(id)
        XCTAssertNotNil(Store(fileURL: url).data.tasks.first?.completedAt)
        store.toggle(id)
        XCTAssertNil(store.data.tasks.first?.completedAt)
        store.deleteTask(id)
        store.undo()
        XCTAssertEqual(store.data.tasks.count, 1)
        XCTAssertEqual(store.data, Store(fileURL: url).data)
        XCTAssertNil(store.addTask(title: "  ", date: nil, groupID: nil))
    }

    @MainActor func testUnreadableDataIsPreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tasks.json")
        let original = Data("invalid".utf8)
        try original.write(to: url)
        let store = Store(fileURL: url)
        XCTAssertNotNil(store.error)
        XCTAssertNil(store.addTask(title: "任务", date: nil, groupID: nil))
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    @MainActor func testDetailsCanBeSavedForExistingTasks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("tasks.json")
        let id = UUID()
        let legacyData = """
        {"tasks":[{"id":"\(id.uuidString)","title":"整理资料","createdAt":0}],"groups":[]}
        """
        try Data(legacyData.utf8).write(to: url)

        let store = Store(fileURL: url)
        XCTAssertEqual(store.data.tasks.first?.id, id)
        XCTAssertNil(store.data.tasks.first?.details)
        let details = "整理会议纪要\n发给项目组"
        store.update(id) { $0.details = details }
        XCTAssertEqual(Store(fileURL: url).data.tasks.first?.details, details)
    }
}
