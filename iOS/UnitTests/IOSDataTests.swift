import CoreFoundation
import Foundation
import XCTest
@testable import OnePage

final class IOSDataTests: XCTestCase {
    func testHostBundleIsIPhoneOnlyAndExplicitlyCloudDisabled() throws {
        let bundle = Bundle.main
        XCTAssertEqual(bundle.bundleIdentifier, "com.onepage.todo.ios")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String, "OnePageiOS")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "一页待办")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String, "APPL")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "UIDeviceFamily") as? [Int], [1])
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "MinimumOSVersion") as? String, "17.0")
        let enabled = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "OnePageCloudKitEnabled") as? NSNumber)
        XCTAssertEqual(CFGetTypeID(enabled), CFBooleanGetTypeID())
        XCTAssertFalse(enabled.boolValue)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "OnePageCloudKitContainerIdentifier") as? String, "")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "OnePageCloudKitEnvironment") as? String, "")
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String], ["remote-notification"])
        let launchScreen = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "UILaunchScreen") as? [String: Any])
        XCTAssertTrue(launchScreen.isEmpty)
        XCTAssertEqual(bundle.object(forInfoDictionaryKey: "UISupportedInterfaceOrientations") as? [String],
                       ["UIInterfaceOrientationPortrait"])
        XCTAssertNil(bundle.object(forInfoDictionaryKey: "UIDesignRequiresCompatibility"))
    }

    func testHostedTestsUseAnIsolatedStoreWithoutPreviewSeeding() throws {
        let arguments = ProcessInfo.processInfo.arguments
        let flagIndex = try XCTUnwrap(arguments.firstIndex(of: "--test-store"))
        let valueIndex = arguments.index(after: flagIndex)
        XCTAssertLessThan(valueIndex, arguments.endIndex)
        guard valueIndex < arguments.endIndex else { return }
        XCTAssertNotNil(UUID(uuidString: arguments[valueIndex]))
        XCTAssertFalse(arguments.contains("--preview-data"))
    }

    func testSyntheticMacFormatRoundTripsEntirelyInMemory() throws {
        let raw = Data("""
        {
          "tasks": [{
            "id": "D976ED91-7459-4E95-AF1A-8A7EEA461533",
            "title": "示例任务",
            "details": "示例备注",
            "date": null,
            "groupID": "F344CE10-0C46-4A82-9F33-6B12BF60C8EF",
            "completedAt": null,
            "createdAt": 0
          }],
          "groups": [{
            "id": "F344CE10-0C46-4A82-9F33-6B12BF60C8EF",
            "name": "示例清单"
          }]
        }
        """.utf8)
        let legacy = try JSONDecoder().decode(SavedData.self, from: raw)
        let document = try JSONDecoder().decode(SyncDocument.self, from: raw)
        XCTAssertTrue(document.migratedLegacy)
        XCTAssertEqual(document.data, legacy)
        XCTAssertEqual(document.data.tasks.count, 1)
        XCTAssertEqual(document.data.groups.count, 1)
        let task = try XCTUnwrap(document.data.tasks.first)
        let group = try XCTUnwrap(document.data.groups.first)
        XCTAssertEqual(task.title, "示例任务")
        XCTAssertEqual(task.details, "示例备注")
        XCTAssertEqual(task.createdAt, Date(timeIntervalSinceReferenceDate: 0))
        XCTAssertEqual(task.groupID, group.id)
        XCTAssertNil(task.date)
        XCTAssertNil(task.completedAt)
        let recordName = "task:" + task.id.uuidString.lowercased()
        XCTAssertEqual(document.metadata.entities[recordName]?.fields["details"]?.value, .string("示例备注"))
        let persisted = try JSONEncoder().encode(document)
        XCTAssertEqual(try JSONDecoder().decode(SavedData.self, from: persisted), legacy)
        let restored = try JSONDecoder().decode(SyncDocument.self, from: persisted)
        XCTAssertFalse(restored.migratedLegacy)
        XCTAssertEqual(restored.metadata, document.metadata)
        XCTAssertEqual(restored.data, legacy)
    }
}
