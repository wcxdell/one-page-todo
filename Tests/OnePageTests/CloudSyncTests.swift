import Foundation
import XCTest
@testable import OnePage

final class CloudSyncTests: XCTestCase {
    @MainActor func testLegacyLoadPreservesTasksGroupsAndRawFile() throws {
        let original = try seedData()
        let raw = Data(" \n".utf8) + (try JSONEncoder().encode(original)) + Data("\n".utf8)
        let fixture = try makeFixture(raw)
        let store = fixture.store

        XCTAssertNil(store.error)
        XCTAssertTrue(store.cloudPersistenceAvailable)
        XCTAssertEqual(store.data, original)
        XCTAssertEqual(try Data(contentsOf: fixture.url), raw)
        XCTAssertEqual(try fixtureFiles(fixture.url), [fixture.url])
        XCTAssertEqual(store.synchronization.schemaVersion, 1)
        XCTAssertEqual(store.synchronization.dirty, Set(store.synchronization.entities.keys))
        let record = try entity(store, original.tasks[0].id)
        XCTAssertEqual(record.schemaVersion, 1)
        XCTAssertEqual(record.fields["title"]?.value, .string(original.tasks[0].title))
        XCTAssertEqual(record.fields["details"]?.value, .string("第一行\n第二行"))
        XCTAssertEqual(record.fields["date"]?.value, .string("2024-03-10"))
        XCTAssertEqual(record.fields["completedAt"]?.value, original.tasks[0].completedAt.map(SyncValue.date))
        XCTAssertEqual(record.fields["deleted"]?.value, .bool(false))
        let undated = try entity(store, original.tasks[1].id)
        for key in ["details", "date", "groupID", "completedAt"] {
            XCTAssertEqual(undated.fields[key]?.value, .null, key)
        }
    }

    @MainActor func testFirstChangedSaveBacksUpExactLegacyBytesAndRemainsSavedDataCompatible() throws {
        let original = try seedData()
        let raw = Data("\n".utf8) + (try JSONEncoder().encode(original))
        let fixture = try makeFixture(raw)
        let store = fixture.store
        let id = original.tasks[0].id

        store.update(id) { $0.title = original.tasks[0].title }
        XCTAssertEqual(try fixtureFiles(fixture.url), [fixture.url])
        XCTAssertEqual(try Data(contentsOf: fixture.url), raw)
        store.update(id) { $0.title = "已修改标题" }
        XCTAssertNil(store.error)
        let backups = try fixtureFiles(fixture.url).filter { $0.pathExtension.hasPrefix("before-icloud-") }
        XCTAssertEqual(backups.count, 1)
        let backup = try XCTUnwrap(backups.first)
        XCTAssertEqual(try Data(contentsOf: backup), raw)
        let persisted = try Data(contentsOf: fixture.url)
        XCTAssertNotEqual(persisted, raw)
        XCTAssertEqual(try JSONDecoder().decode(SavedData.self, from: persisted), store.data)
        let document = try JSONDecoder().decode(SyncDocument.self, from: persisted)
        XCTAssertFalse(document.migratedLegacy)
        XCTAssertEqual(document.metadata, store.synchronization)
        store.update(id) { $0.details = "第二次修改" }
        XCTAssertEqual(try fixtureFiles(fixture.url).count, 2)
        XCTAssertEqual(try Data(contentsOf: backup), raw)
        XCTAssertEqual(Store(fileURL: fixture.url).data, store.data)
    }

    @MainActor func testInvalidFilesAndNewerSchemasBlockEditsWithoutOverwriting() throws {
        let original = try seedData()
        var newerMetadata = SyncMetadata.migrating(original)
        newerMetadata.schemaVersion = 2
        var newerEntity = SyncMetadata.migrating(original)
        let name = "task:" + original.tasks[0].id.uuidString.lowercased()
        newerEntity.entities[name]?.schemaVersion = 2
        var invalidDay = SyncMetadata.migrating(original)
        invalidDay.entities[name]?.fields["date"]?.value = .date(Date(timeIntervalSinceReferenceDate: 0))
        let cases = try [
            Data("not JSON".utf8),
            JSONEncoder().encode(SyncDocument(data: original, metadata: newerMetadata)),
            JSONEncoder().encode(SyncDocument(data: original, metadata: newerEntity)),
            JSONEncoder().encode(SyncDocument(data: original, metadata: invalidDay))
        ]

        for raw in cases {
            let fixture = try makeFixture(raw)
            let store = fixture.store
            let before = store.data
            let metadata = store.synchronization
            XCTAssertNotNil(store.error)
            XCTAssertFalse(store.cloudPersistenceAvailable)
            XCTAssertNil(store.addTask(title: "不得写入", date: nil, groupID: nil))
            XCTAssertNil(store.addGroup("不得写入"))
            store.update(original.tasks[0].id) { $0.title = "不得覆盖" }
            store.deleteTask(original.tasks[0].id)
            store.deleteGroup(original.groups[0].id)
            store.undo()
            XCTAssertThrowsError(try store.applyCloudRecords([], systemFields: [:], deletedRecordNames: []))
            XCTAssertThrowsError(try store.bindCloudAccount("fixture-scope"))
            XCTAssertEqual(store.data, before)
            XCTAssertEqual(store.synchronization, metadata)
            XCTAssertEqual(try Data(contentsOf: fixture.url), raw)
            XCTAssertEqual(try fixtureFiles(fixture.url), [fixture.url])
        }
    }

    @MainActor func testOfflineTitleAndNotesMergeConvergesAndIsIdempotent() throws {
        let (first, second) = try makePair()
        let id = try XCTUnwrap(first.store.data.tasks.first?.id)
        let untouched = first.store.data.tasks.dropFirst()
        first.store.update(id) { $0.title = "设备一的标题" }
        second.store.update(id) { $0.details = "设备二的备注\n保留两行" }

        try exchange(first.store, second.store)
        XCTAssertEqual(try task(first.store, id).title, "设备一的标题")
        XCTAssertEqual(try task(first.store, id).details, "设备二的备注\n保留两行")
        XCTAssertEqual(first.store.data.tasks.dropFirst(), untouched)
        XCTAssertEqual(first.store.data, second.store.data)
        XCTAssertEqual(first.store.synchronization.entities, second.store.synchronization.entities)
        let name = try entity(first.store, id).recordName
        XCTAssertTrue(first.store.synchronization.dirty.contains(name))
        XCTAssertTrue(second.store.synchronization.dirty.contains(name))
        try exchange(first.store, second.store)
        XCTAssertTrue(first.store.synchronization.dirty.isEmpty)
        XCTAssertTrue(second.store.synchronization.dirty.isEmpty)
        let firstMetadata = first.store.synchronization
        let secondMetadata = second.store.synchronization
        try exchange(first.store, second.store)
        XCTAssertEqual(first.store.synchronization, firstMetadata)
        XCTAssertEqual(second.store.synchronization, secondMetadata)
        XCTAssertEqual(Store(fileURL: first.url).synchronization, firstMetadata)
        XCTAssertEqual(Store(fileURL: second.url).data, first.store.data)
    }

    @MainActor func testSimultaneousSameFieldVersionsResolveDeterministically() throws {
        let (first, second) = try makePair()
        let id = try XCTUnwrap(first.store.data.tasks.first?.id)
        first.store.update(id) { $0.title = "来自设备一" }
        second.store.update(id) { $0.title = "来自设备二" }
        var left = try entity(first.store, id)
        var right = try entity(second.store, id)
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        left.fields["title"]?.version = SyncVersion(time: time, counter: 7, deviceID: first.store.synchronization.deviceID)
        right.fields["title"]?.version = SyncVersion(time: time, counter: 7, deviceID: second.store.synchronization.deviceID)
        let winner = first.store.synchronization.deviceID < second.store.synchronization.deviceID ? right : left

        let forward = try left.merged(with: right)
        let reverse = try right.merged(with: left)
        XCTAssertEqual(forward, winner)
        XCTAssertEqual(reverse, winner)
        XCTAssertEqual(try forward.merged(with: left), winner)
        XCTAssertEqual(try forward.merged(with: right), winner)
        var conflicting = winner
        conflicting.fields["title"]?.value = .string("相同版本却内容不同")
        XCTAssertThrowsError(try winner.merged(with: conflicting)) { error in
            XCTAssertEqual(error.localizedDescription, SyncFailure.invalidData.localizedDescription)
        }
    }

    @MainActor func testDeletionBeatsStaleOfflineEditAndUndoExplicitlyRestores() throws {
        let (first, second) = try makePair()
        let original = first.store.data
        let id = original.tasks[0].id
        first.store.deleteTask(id)
        second.store.update(id) { $0.title = "删除后才送达的离线修改" }
        let stale = try entity(second.store, id)

        try exchange(first.store, second.store)
        for store in [first.store, second.store] {
            XCTAssertFalse(store.data.tasks.contains { $0.id == id })
            XCTAssertTrue(try entity(store, id).isDeleted)
            XCTAssertEqual(store.data.tasks.count, original.tasks.count - 1)
        }
        first.store.undo()
        XCTAssertEqual(first.store.data, original)
        let restored = try entity(first.store, id)
        XCTAssertFalse(restored.isDeleted)
        XCTAssertNil(first.store.undoLabel)
        try second.store.applyCloudRecords([restored, stale], systemFields: [:], deletedRecordNames: [])
        XCTAssertEqual(second.store.data, original)
        XCTAssertFalse(try entity(second.store, id).isDeleted)
        XCTAssertEqual(Store(fileURL: second.url).data, original)
    }

    @MainActor func testHardDeletionBeforeUnseenRecordPersistsTombstoneAgainstResurrection() throws {
        let (receiver, sender) = try makePair()
        let original = receiver.store.data
        let id = try XCTUnwrap(sender.store.addTask(title: "尚未见过的记录", date: nil, groupID: nil))
        let stale = try entity(sender.store, id)
        XCTAssertNil(receiver.store.synchronization.entities[stale.recordName])
        try receiver.store.applyCloudRecords([], systemFields: [:], deletedRecordNames: [stale.recordName])
        let tombstone = try entity(receiver.store, id)
        XCTAssertTrue(tombstone.isDeleted)
        XCTAssertEqual(Set(tombstone.fields.keys), Set(["deleted", "serverDeleted"]))
        XCTAssertEqual(tombstone.fields["serverDeleted"]?.value, .bool(true))
        XCTAssertEqual(receiver.store.data, original)

        let reloaded = Store(fileURL: receiver.url)
        XCTAssertEqual(try entity(reloaded, id), tombstone)
        XCTAssertTrue(reloaded.synchronization.dirty.contains(stale.recordName))
        for _ in 0..<2 {
            try reloaded.applyCloudRecords([stale], systemFields: [:], deletedRecordNames: [])
            XCTAssertTrue(try entity(reloaded, id).isDeleted)
            XCTAssertTrue(reloaded.synchronization.dirty.contains(stale.recordName))
            XCTAssertEqual(reloaded.data, original)
        }
        let retained = Store(fileURL: receiver.url)
        XCTAssertEqual(retained.synchronization, reloaded.synchronization)
        XCTAssertEqual(retained.data, original)
    }

    @MainActor func testUnseenHardDeletionRejectsStaleCreationFromAheadDeviceClock() throws {
        let (receiver, sender) = try makePair()
        let original = receiver.store.data
        let id = try XCTUnwrap(sender.store.addTask(title: "时钟超前设备上的旧记录", date: nil, groupID: nil))
        var stale = try entity(sender.store, id)
        stale.fields = stale.fields.mapValues { field in
            var advanced = field
            advanced.version.time = .distantFuture
            return advanced
        }
        try stale.validate()
        try receiver.store.applyCloudRecords([], systemFields: [:], deletedRecordNames: [stale.recordName])
        let reloaded = Store(fileURL: receiver.url)
        try reloaded.applyCloudRecords([stale], systemFields: [:], deletedRecordNames: [])
        XCTAssertEqual(reloaded.data, original)
        XCTAssertTrue(try entity(reloaded, id).isDeleted)
        XCTAssertTrue(reloaded.synchronization.dirty.contains(stale.recordName))
        XCTAssertEqual(Store(fileURL: receiver.url).data, original)
    }

    @MainActor func testOldSentAcknowledgmentKeepsNewerEditDirtyUntilMatchingAcknowledgment() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let id = try XCTUnwrap(store.data.tasks.first?.id)
        store.update(id) { $0.title = "已发送版本" }
        let sent = try entity(store, id)
        store.update(id) { $0.title = "发送后再次修改"; $0.details = "新备注" }
        let newer = try entity(store, id)
        try store.applyCloudRecords([sent], systemFields: [:], deletedRecordNames: [])

        XCTAssertEqual(try entity(store, id), newer)
        XCTAssertEqual(try task(store, id).title, "发送后再次修改")
        XCTAssertEqual(try task(store, id).details, "新备注")
        XCTAssertTrue(store.synchronization.dirty.contains(sent.recordName))
        let reloaded = Store(fileURL: fixture.url)
        XCTAssertEqual(try entity(reloaded, id), newer)
        XCTAssertTrue(reloaded.synchronization.dirty.contains(sent.recordName))
        try reloaded.applyCloudRecords([newer], systemFields: [:], deletedRecordNames: [])
        XCTAssertFalse(reloaded.synchronization.dirty.contains(sent.recordName))
        XCTAssertEqual(try entity(reloaded, id), newer)
        XCTAssertFalse(Store(fileURL: fixture.url).synchronization.dirty.contains(sent.recordName))
    }

    @MainActor func testNewerRemoteAcknowledgmentClearsDirtyWhenMergedRecordMatches() throws {
        let (first, second) = try makePair()
        let id = try XCTUnwrap(first.store.data.tasks.first?.id)
        first.store.update(id) { $0.title = "本地版本" }
        try second.store.applyCloudRecords(records(first.store), systemFields: [:], deletedRecordNames: [])
        second.store.update(id) { $0.title = "较新的远端版本" }
        let remote = try entity(second.store, id)
        XCTAssertTrue(first.store.synchronization.dirty.contains(remote.recordName))
        try first.store.applyCloudRecords([remote], systemFields: [:], deletedRecordNames: [])
        XCTAssertEqual(try entity(first.store, id), remote)
        XCTAssertEqual(try task(first.store, id).title, "较新的远端版本")
        XCTAssertFalse(first.store.synchronization.dirty.contains(remote.recordName))
        XCTAssertEqual(Store(fileURL: first.url).synchronization, first.store.synchronization)
    }

    @MainActor func testGroupDeletionReassignsWithoutDeletingTasksAndUndoRestores() throws {
        let (first, second) = try makePair()
        let original = first.store.data
        let groupID = original.groups[0].id
        first.store.deleteGroup(groupID)
        XCTAssertEqual(first.store.data.tasks.map(\.id), original.tasks.map(\.id))
        XCTAssertTrue(first.store.data.tasks.allSatisfy { $0.groupID != groupID })
        XCTAssertTrue(try entity(first.store, groupID, kind: .group).isDeleted)
        try second.store.applyCloudRecords(records(first.store), systemFields: [:], deletedRecordNames: [])
        XCTAssertEqual(second.store.data, first.store.data)
        XCTAssertEqual(second.store.data.tasks.count, original.tasks.count)

        first.store.undo()
        XCTAssertEqual(first.store.data, original)
        XCTAssertFalse(try entity(first.store, groupID, kind: .group).isDeleted)
        try second.store.applyCloudRecords(records(first.store), systemFields: [:], deletedRecordNames: [])
        XCTAssertEqual(second.store.data, original)
        XCTAssertEqual(Store(fileURL: second.url).data, original)
    }

    @MainActor func testUndoLocalMovePreservesRemoteTitleAndUnrelatedNewRecord() throws {
        let (first, second) = try makePair()
        let original = try XCTUnwrap(first.store.data.tasks.first)
        let destination = try XCTUnwrap(first.store.data.groups.last?.id)
        first.store.move(original.id, to: destination)
        second.store.update(original.id) { $0.title = "远端新标题" }
        let newID = try XCTUnwrap(second.store.addTask(title: "远端新增任务", date: nil, groupID: destination))
        let newRecord = try entity(second.store, newID)
        let remoteTitle = try entity(second.store, original.id).fields["title"]
        try first.store.applyCloudRecords(records(second.store), systemFields: [:], deletedRecordNames: [])
        XCTAssertEqual(try task(first.store, original.id).groupID, destination)

        first.store.undo()
        XCTAssertEqual(try task(first.store, original.id).groupID, original.groupID)
        XCTAssertEqual(try task(first.store, original.id).title, "远端新标题")
        XCTAssertEqual(try entity(first.store, original.id).fields["title"], remoteTitle)
        XCTAssertEqual(try entity(first.store, newID), newRecord)
        XCTAssertEqual(first.store.data.tasks.count, 3)
        XCTAssertNil(first.store.undoLabel)
        try second.store.applyCloudRecords(records(first.store), systemFields: [:], deletedRecordNames: [])
        XCTAssertEqual(second.store.data, first.store.data)
    }

    @MainActor func testAccountContainerAndEnvironmentChangesAreRefusedWithoutFileChanges() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        let original = store.data
        let scope = try accountScope()
        try store.bindCloudAccount(scope)
        XCTAssertEqual(store.data, original)
        let bytes = try Data(contentsOf: fixture.url)
        let metadata = store.synchronization
        let files = try fixtureFiles(fixture.url)
        let alternatives = try [
            accountScope(account: "fixture-user-b"),
            accountScope(container: "fixture-container-b"),
            accountScope(environment: "Production")
        ]
        for other in alternatives {
            XCTAssertThrowsError(try store.bindCloudAccount(other, preparingZone: true)) { error in
                XCTAssertEqual(error.localizedDescription, SyncFailure.accountChanged.localizedDescription)
            }
            XCTAssertEqual(store.data, original)
            XCTAssertEqual(store.synchronization, metadata)
            XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
            XCTAssertEqual(try fixtureFiles(fixture.url), files)
        }
        try store.bindCloudAccount(scope)
        XCTAssertEqual(Store(fileURL: fixture.url).data, original)
        XCTAssertEqual(store.synchronization.accountScope, scope)
    }

    @MainActor func testPendingZoneInitializationPersistsUntilExplicitlyReady() throws {
        let fixture = try makeFixture()
        let original = fixture.store.data
        let scope = try accountScope()
        try fixture.store.bindCloudAccount(scope, preparingZone: true)
        let pending = Store(fileURL: fixture.url)
        XCTAssertEqual(pending.synchronization.accountScope, scope)
        XCTAssertTrue(pending.synchronization.zoneInitializationPending)
        XCTAssertEqual(pending.data, original)
        let dirty = pending.synchronization.dirty
        try pending.markCloudZoneReady()
        let ready = Store(fileURL: fixture.url)
        XCTAssertFalse(ready.synchronization.zoneInitializationPending)
        XCTAssertEqual(ready.synchronization.accountScope, scope)
        XCTAssertEqual(ready.synchronization.dirty, dirty)
        XCTAssertEqual(ready.data, original)
    }

    @MainActor func testOpaqueStateSystemFieldsAndDirtyQueueSurviveReload() throws {
        let fixture = try makeFixture()
        let store = fixture.store
        try store.bindCloudAccount(accountScope())
        let id = try XCTUnwrap(store.data.tasks.first?.id)
        let acknowledged = try entity(store, id)
        try store.applyCloudRecords([acknowledged], systemFields: [:], deletedRecordNames: [])
        store.update(id) { $0.details = "必须保留的未上传修改" }
        let state = Data([0, 255, 17, 128, 42])
        let fields = Data([255, 0, 129, 33])
        try store.applyCloudRecords([], systemFields: [acknowledged.recordName: fields], deletedRecordNames: [])
        try store.setCloudEngineState(state)
        try store.pauseCloudSync(reason: "fixture pause")
        let reloaded = Store(fileURL: fixture.url)
        XCTAssertNil(reloaded.error)
        XCTAssertEqual(reloaded.data, store.data)
        XCTAssertEqual(reloaded.synchronization, store.synchronization)
        XCTAssertEqual(reloaded.synchronization.engineState, state)
        XCTAssertEqual(reloaded.synchronization.recordSystemFields[acknowledged.recordName], fields)
        XCTAssertTrue(reloaded.synchronization.dirty.contains(acknowledged.recordName))
        XCTAssertEqual(reloaded.synchronization.blockedReason, "fixture pause")
    }

    func testDueDayRoundTripsAcrossShanghaiLosAngelesAndDSTWithoutDayChanges() throws {
        let shanghai = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let keys = ["2024-02-29", "2024-03-09", "2024-03-10", "2024-03-11",
                    "2024-11-02", "2024-11-03", "2024-11-04", "2024-12-31"]
        for key in keys {
            for (source, destination) in [(shanghai, losAngeles), (losAngeles, shanghai)] {
                let original = try XCTUnwrap(SyncDay.date(key, timeZone: source))
                let wire = SyncValue.string(SyncDay.key(original, timeZone: source))
                let decoded = try JSONDecoder().decode(SyncValue.self, from: JSONEncoder().encode(wire))
                let day = try XCTUnwrap(decoded.string)
                let local = try XCTUnwrap(SyncDay.date(day, timeZone: destination))
                XCTAssertEqual(SyncDay.key(local, timeZone: destination), key)
                XCTAssertEqual(SyncDay.date(SyncDay.key(local, timeZone: destination), timeZone: source), original)
            }
        }
        for (day, next, hours) in [("2024-03-10", "2024-03-11", 23), ("2024-11-03", "2024-11-04", 25)] {
            let start = try XCTUnwrap(SyncDay.date(day, timeZone: losAngeles))
            let end = try XCTUnwrap(SyncDay.date(next, timeZone: losAngeles))
            XCTAssertEqual(end.timeIntervalSince(start), Double(hours * 3600))
        }
        for invalid in ["2024-02-30", "2023-02-29", "2024-13-01", "2024-3-10", "not-a-day"] {
            XCTAssertNil(SyncDay.date(invalid, timeZone: shanghai))
            XCTAssertNil(SyncDay.date(invalid, timeZone: losAngeles))
        }
    }

    @MainActor func testLoadingAfterTimezoneChangeUsesCalendarDayWithoutRewritingFile() throws {
        let target = try XCTUnwrap(SyncDay.date("2024-03-10"))
        var data = try seedData()
        data.tasks[0].date = target.addingTimeInterval(8 * 3600)
        var metadata = SyncMetadata.migrating(data)
        metadata.localTimeZoneIdentifier = TimeZone.current.identifier == "America/Los_Angeles" ? "Asia/Shanghai" : "America/Los_Angeles"
        let name = "task:" + data.tasks[0].id.uuidString.lowercased()
        metadata.entities[name]?.fields["date"]?.value = .string("2024-03-10")
        let raw = try JSONEncoder().encode(SyncDocument(data: data, metadata: metadata))
        let fixture = try makeFixture(raw)
        XCTAssertNil(fixture.store.error)
        XCTAssertEqual(fixture.store.data.tasks[0].date, target)
        XCTAssertEqual(try Data(contentsOf: fixture.url), raw)
    }

    @MainActor func testDisabledCloudConfigurationStaysLocalAndDoesNotTouchFixture() async throws {
        guard (Bundle.main.object(forInfoDictionaryKey: "OnePageCloudKitEnabled") as? NSNumber)?.boolValue != true else {
            XCTFail("This test requires CloudKit to be disabled; refusing to start it.")
            return
        }
        let fixture = try makeFixture()
        let original = fixture.store.data
        let metadata = fixture.store.synchronization
        let bytes = try Data(contentsOf: fixture.url)
        let sync = CloudSync(store: fixture.store)
        XCTAssertEqual(fixture.store.syncStatus, .notConfigured)
        await sync.start()
        await sync.start()
        XCTAssertEqual(fixture.store.syncStatus, .notConfigured)
        XCTAssertFalse(sync.hasCloudConnection)
        XCTAssertFalse(fixture.store.syncStatus.isSyncing)
        if L10n.currentLanguage == .chinese {
            XCTAssertTrue(fixture.store.syncStatus.title.contains("仅本地"))
            XCTAssertTrue(fixture.store.syncStatus.detail.contains("仅在本机保存"))
            XCTAssertTrue(fixture.store.syncStatus.detail.contains("本地数据未上传"))
        } else {
            XCTAssertTrue(fixture.store.syncStatus.title.contains("Local only"))
            XCTAssertTrue(fixture.store.syncStatus.detail.contains("only on this device"))
            XCTAssertTrue(fixture.store.syncStatus.detail.contains("has not been uploaded"))
        }
        XCTAssertEqual(fixture.store.data, original)
        XCTAssertEqual(fixture.store.synchronization, metadata)
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytes)
        XCTAssertEqual(try fixtureFiles(fixture.url), [fixture.url])
    }

    private typealias Fixture = (url: URL, store: Store)

    private func seedData() throws -> SavedData {
        let groups = [TaskGroup(name: "工作"), TaskGroup(name: "个人")]
        let due = try XCTUnwrap(SyncDay.date("2024-03-10"))
        return SavedData(tasks: [
            Todo(title: "整理资料", details: "第一行\n第二行", date: due, groupID: groups[0].id,
                 completedAt: Date(timeIntervalSinceReferenceDate: 3600), createdAt: Date(timeIntervalSinceReferenceDate: 0)),
            Todo(title: "未安排", createdAt: Date(timeIntervalSinceReferenceDate: 60))
        ], groups: groups)
    }

    @MainActor private func makeFixture() throws -> Fixture {
        try makeFixture(JSONEncoder().encode(seedData()))
    }

    @MainActor private func makeFixture(_ raw: Data) throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwenwork", isDirectory: true)
            .appendingPathComponent("CloudSyncTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.resolvingSymlinksInPath().appendingPathComponent("tasks.json")
        try raw.write(to: url)
        return (url, Store(fileURL: url))
    }

    @MainActor private func makePair() throws -> (Fixture, Fixture) {
        let raw = try JSONEncoder().encode(seedData())
        let first = try makeFixture(raw)
        let second = try makeFixture(raw)
        XCTAssertNil(first.store.error)
        XCTAssertNil(second.store.error)
        XCTAssertEqual(first.store.data, second.store.data)
        XCTAssertEqual(first.store.synchronization.entities, second.store.synchronization.entities)
        XCTAssertNotEqual(first.store.synchronization.deviceID, second.store.synchronization.deviceID)
        return (first, second)
    }

    private func fixtureFiles(_ url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .map { $0.resolvingSymlinksInPath() }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @MainActor private func entity(_ store: Store, _ id: UUID, kind: SyncKind = .task) throws -> SyncEntity {
        try XCTUnwrap(store.synchronization.entities[kind.rawValue + ":" + id.uuidString.lowercased()])
    }

    @MainActor private func task(_ store: Store, _ id: UUID) throws -> Todo {
        try XCTUnwrap(store.data.tasks.first { $0.id == id })
    }

    @MainActor private func records(_ store: Store) -> [SyncEntity] {
        store.synchronization.entities.values.sorted { $0.recordName < $1.recordName }
    }

    @MainActor private func exchange(_ first: Store, _ second: Store) throws {
        let firstRecords = records(first)
        let secondRecords = records(second)
        try first.applyCloudRecords(secondRecords, systemFields: [:], deletedRecordNames: [])
        try second.applyCloudRecords(firstRecords, systemFields: [:], deletedRecordNames: [])
    }

    private func accountScope(account: String = "fixture-user-a", container: String = "fixture-container-a",
                              environment: String = "Development") throws -> String {
        String(decoding: try JSONEncoder().encode([container, environment, account]), as: UTF8.self)
    }
}
