import Foundation
import CoreFoundation
import CloudKit
#if os(macOS)
import Security
#endif

enum CloudSyncStatus: Equatable, Sendable {
    case notConfigured
    case localOnly
    case checkingAccount
    case signedOut
    case syncing
    case synced(Date)
    case waiting(String)
    case blocked(String)
    case failed(String)

    var title: String {
        switch self {
        case .notConfigured: return L("仅本地 · 未配置 iCloud")
        case .localOnly: return L("仅本地")
        case .checkingAccount: return L("正在检查 iCloud")
        case .signedOut: return L("未登录 iCloud")
        case .syncing: return L("正在同步")
        case .synced: return L("已同步")
        case .waiting: return L("等待同步")
        case .blocked: return L("同步已暂停")
        case .failed: return L("同步未完成")
        }
    }

    var detail: String {
        switch self {
        case .notConfigured:
            return L("需要有效的 Apple Developer 会员资格，为 Mac 与 iPhone 配置同一个 CloudKit 容器，并在应用签名中启用 iCloud 与推送能力。还需在系统中登录 iCloud。当前仅在本机保存，本地数据未上传。")
        case .localOnly:
            return L("当前使用本地数据，尚未完成云端同步。")
        case .checkingAccount:
            return L("正在检查账户是否可用及是否与本地数据原先绑定的账户一致。")
        case .signedOut:
            return L("iCloud 账户不可用，已保留本地数据。登录原账户后可点击同步重试。")
        case .syncing:
            return L("正在与 iCloud 交换更改；尚未确认本轮同步完成。")
        case .synced(let date):
            let formatted = date.formatted(.dateTime.year().month(.abbreviated).day().hour().minute().locale(L10n.locale))
            return LF("最近一次完整同步：%@。其他设备仍需联网同步才能收到更改。", formatted)
        case .waiting(let message), .blocked(let message), .failed(let message):
            return L(message)
        }
    }

    var isSyncing: Bool {
        switch self {
        case .checkingAccount, .syncing: return true
        default: return false
        }
    }
}

@available(iOS 17.0, macOS 14.0, *)
@MainActor
final class CloudSync: CKSyncEngineDelegate {
    private weak var store: Store?
    private var engine: CKSyncEngine?
    private var container: CKContainer?
    private var accountObserver: AccountObserver?
    private var operation: Task<Void, Never>?
    private var cancellation: Task<Void, Never>?
    private var generation = UUID()
    private var attemptedStart = false
    private var persistenceHalted = false
    private var boundUserID: CKRecord.ID?
    private var boundScope: String?
    private var zoneReady = false
    private var needsInitialZone = false
    private var uploadsAllowed = false
    private var fetching = false
    private var sending = false
    private var issueRevision: UInt64 = 0
    private var lastIssue: CloudSyncStatus?
    private var conflicts: [String: Int] = [:]

    private let zoneID = CKRecordZone.ID(zoneName: "OnePage", ownerName: CKCurrentUserDefaultName)
    private static let recordType = "OnePageItemV1"
    private static let payloadKey = "payload"
    private static let maximumPayloadBytes = 900_000
    private static let maximumBatchBytes = 1_000_000
    private static let persistenceMessage = "同步数据未能安全保存到本地，已停止云端同步且不再推进检查点。请检查磁盘空间、文件权限及本地数据格式；现有数据不会被自动删除。"

    var hasCloudConnection: Bool { engine != nil }

    init(store: Store) {
        self.store = store
        switch Self.readConfiguration() {
        case .success:
            store.setSyncStatus(.localOnly)
        case .failure(let issue):
            store.setSyncStatus(issue.status)
        }
    }

    deinit {
        operation?.cancel()
        let previousEngine = engine
        let previousCancellation = cancellation
        Task {
            await previousCancellation?.value
            await previousEngine?.cancelOperations()
        }
    }

    func start() async {
        guard !attemptedStart else {
            await operation?.value
            return
        }
        attemptedStart = true
        await runCoalescedSync()
    }

    func syncNow() async {
        attemptedStart = true
        await runCoalescedSync()
    }

    func localChangesDidCommit() {
        guard let engine, usable(engine) else { return }
        guard uploadsAllowed, zoneReady else { return }
        enqueueDirty(in: engine)
        guard isCurrent(engine) else { return }
        if fetching || sending {
            publish(.syncing)
        } else {
            publish(lastIssue ?? .waiting("本地更改已保存，等待 iCloud 确认。"))
        }
    }

    private func runCoalescedSync() async {
        if let operation {
            await operation.value
            return
        }
        guard !Task.isCancelled else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performSync()
        }
        operation = task
        await task.value
        operation = nil
    }

    private func performSync() async {
        await cancellation?.value
        guard !Task.isCancelled, !persistenceHalted else { return }
        guard let current = await prepareEngine(), usable(current) else { return }
        let revision = issueRevision
        lastIssue = nil
        publish(.syncing)
        do {
            try await current.fetchChanges(.init(scope: .zoneIDs(zoneReady ? [zoneID] : [])))
            guard !Task.isCancelled, usable(current), issueRevision == revision else { return }
            uploadsAllowed = true
            if needsInitialZone {
                current.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
            }
            if zoneReady {
                enqueueDirty(in: current)
            }
            guard usable(current) else { return }
            try await current.sendChanges(.init(scope: .zoneIDs([zoneID])))
            guard !Task.isCancelled, usable(current), let store else { return }
            if issueRevision == revision,
               zoneReady,
               store.synchronization.dirty.isEmpty,
               current.state.pendingRecordZoneChanges.isEmpty,
               current.state.pendingDatabaseChanges.isEmpty,
               !current.state.hasPendingUntrackedChanges,
               !current.state.zoneIDsWithUnfetchedServerChanges.contains(zoneID),
               !fetching, !sending {
                lastIssue = nil
                publish(.synced(Date()))
            } else {
                publish(lastIssue ?? .waiting("仍有未确认的更改，尚未完成同步。"))
            }
        } catch {
            guard isCurrent(current) else { return }
            handleCloudError(error)
        }
    }

    private func prepareEngine() async -> CKSyncEngine? {
        if let engine {
            return usable(engine) ? engine : nil
        }
        guard let store, !persistenceHalted else { return nil }
        let configuration: Configuration
        switch Self.readConfiguration() {
        case .success(let value):
            configuration = value
        case .failure(let issue):
            publish(issue.status)
            return nil
        }
        guard store.cloudPersistenceAvailable else {
            publish(.localOnly)
            return nil
        }
        if let reason = store.synchronization.blockedReason, !Self.canRetry(reason) {
            publish(.blocked(Self.safePauseMessage(reason)))
            return nil
        }
        let metadata = store.synchronization
        guard metadata.accountScope != nil || (metadata.engineState == nil && metadata.recordSystemFields.isEmpty) else {
            pause(.invalidState)
            return nil
        }
        let serialization: CKSyncEngine.State.Serialization?
        do {
            serialization = try metadata.engineState.map {
                try JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
            }
        } catch {
            pause(.invalidState)
            return nil
        }
        let attempt = generation
        if accountObserver == nil {
            accountObserver = AccountObserver { [weak self] in
                Task { @MainActor [weak self] in
                    self?.accountMayHaveChanged()
                }
            }
        }
        let candidate = CKContainer(identifier: configuration.identifier)
        container = candidate
        publish(.checkingAccount)
        do {
            let accountStatus = try await candidate.accountStatus()
            guard attempt == generation, !Task.isCancelled else { return nil }
            switch accountStatus {
            case .available:
                break
            case .noAccount:
                pause(.accountUnavailable, status: .signedOut)
                return nil
            case .restricted:
                pause(.accountUnavailable, status: .blocked("系统限制了 iCloud 访问。请检查系统或设备管理设置；本地数据已保留。"))
                return nil
            case .temporarilyUnavailable, .couldNotDetermine:
                pause(.accountUnavailable, status: .waiting("暂时无法确认 iCloud 账户状态；本地数据已保留，可稍后重试。"))
                return nil
            @unknown default:
                pause(.accountUnavailable)
                return nil
            }
            let userID = try await candidate.userRecordID()
            guard attempt == generation, !Task.isCancelled else { return nil }
            guard !userID.recordName.isEmpty else {
                pause(.accountUnavailable)
                return nil
            }
            let scopeData = try JSONEncoder().encode([configuration.identifier, configuration.environment, userID.recordName])
            let scope = String(decoding: scopeData, as: UTF8.self)
            if let previous = store.synchronization.accountScope, previous != scope {
                pause(.accountMismatch)
                return nil
            }
            var initialZone = false
            do {
                _ = try await candidate.privateCloudDatabase.recordZone(for: zoneID)
            } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
                guard attempt == generation, !Task.isCancelled else { return nil }
                let current = store.synchronization
                let firstSetup = current.accountScope == nil && current.engineState == nil
                let interruptedSetup = current.accountScope == scope && current.zoneInitializationPending
                guard firstSetup || interruptedSetup,
                       current.recordSystemFields.isEmpty,
                       (error.userInfo[CKErrorUserDidResetEncryptedDataKey] as? NSNumber)?.boolValue != true else {
                    pause(.zoneRemoved)
                    return nil
                }
                initialZone = true
            }
            guard attempt == generation, !Task.isCancelled else { return nil }
            guard store.cloudPersistenceAvailable else {
                haltForPersistence()
                return nil
            }
            if let reason = store.synchronization.blockedReason, !Self.canRetry(reason) {
                publish(.blocked(Self.safePauseMessage(reason)))
                return nil
            }
            do {
                try store.bindCloudAccount(scope, preparingZone: initialZone)
            } catch {
                haltForPersistence()
                return nil
            }
            boundUserID = userID
            boundScope = scope
            zoneReady = !initialZone
            needsInitialZone = initialZone
            uploadsAllowed = false
            fetching = false
            sending = false
            conflicts = [:]
            var settings = CKSyncEngine.Configuration(
                database: candidate.privateCloudDatabase,
                stateSerialization: serialization,
                delegate: self
            )
            settings.automaticallySync = true
            let created = CKSyncEngine(settings)
            engine = created
            created.state.remove(pendingDatabaseChanges: created.state.pendingDatabaseChanges)
            created.state.remove(pendingRecordZoneChanges: created.state.pendingRecordZoneChanges)
            created.state.hasPendingUntrackedChanges = false
            return created
        } catch {
            guard attempt == generation else { return nil }
            handleCloudError(error)
            return nil
        }
    }

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard usable(syncEngine) else { return }
        switch event {
        case .stateUpdate(let update):
            guard let store else {
                detachEngine()
                return
            }
            do {
                let data = try JSONEncoder().encode(update.stateSerialization)
                try store.setCloudEngineState(data)
            } catch {
                haltForPersistence()
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn(let currentUser):
                if currentUser != boundUserID {
                    pause(.accountChanged)
                }
            case .signOut:
                pause(.accountUnavailable, status: .signedOut)
            case .switchAccounts:
                pause(.accountChanged)
            @unknown default:
                pause(.accountChanged)
            }
        case .fetchedDatabaseChanges(let changes):
            if changes.deletions.contains(where: { $0.zoneID == zoneID }) {
                pause(.zoneRemoved)
            }
        case .fetchedRecordZoneChanges(let changes):
            do {
                var names: [String] = []
                for deletion in changes.deletions where deletion.recordID.zoneID == zoneID && deletion.recordType == Self.recordType {
                    guard Self.validRecordName(deletion.recordID.recordName) else { throw ClientFailure.invalidRecord }
                    names.append(deletion.recordID.recordName)
                }
                try applyRecords(changes.modifications.map(\.record), deletedNames: names, in: syncEngine)
            } catch {
                handleClientFailure(error)
            }
        case .sentRecordZoneChanges(let changes):
            handleSentRecords(changes, in: syncEngine)
        case .sentDatabaseChanges(let changes):
            if changes.deletedZoneIDs.contains(zoneID) || !changes.failedZoneDeletes.isEmpty {
                pause(.invalidState)
                return
            }
            if changes.savedZones.contains(where: { $0.zoneID == zoneID }) {
                guard needsInitialZone else {
                    pause(.invalidState)
                    return
                }
                do {
                    guard let store else { detachEngine(); return }
                    try store.markCloudZoneReady()
                } catch {
                    haltForPersistence()
                    return
                }
                zoneReady = true
                needsInitialZone = false
                if uploadsAllowed {
                    enqueueDirty(in: syncEngine)
                }
            }
            for failure in changes.failedZoneSaves where failure.zone.zoneID == zoneID {
                guard isCurrent(syncEngine) else { return }
                handleCloudError(failure.error)
            }
        case .willFetchChanges:
            fetching = true
            publish(.syncing)
        case .willFetchRecordZoneChanges:
            break
        case .didFetchRecordZoneChanges(let result):
            if result.zoneID == zoneID, let error = result.error {
                handleCloudError(error)
            }
        case .didFetchChanges:
            fetching = false
            publishBackgroundOutcome()
        case .willSendChanges:
            sending = true
            publish(.syncing)
        case .didSendChanges:
            sending = false
            publishBackgroundOutcome()
        @unknown default:
            break
        }
    }

    func nextFetchChangesOptions(_ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.FetchChangesOptions {
        var options = context.options
        let includeZone = usable(syncEngine) && zoneReady && options.scope.contains(zoneID)
        options.scope = .zoneIDs(includeZone ? [zoneID] : [])
        options.prioritizedZoneIDs = includeZone ? [zoneID] : []
        return options
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard usable(syncEngine), uploadsAllowed, zoneReady else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges
        for change in pending {
            if case .deleteRecord = change {
                pause(.invalidState)
                return nil
            }
        }
        let changes = pending.filter { change in
            guard context.options.scope.contains(change) else { return false }
            if case .saveRecord(let id) = change { return id.zoneID == zoneID }
            return false
        }
        var selected: [CKSyncEngine.PendingRecordZoneChange] = []
        var prepared: [CKRecord.ID: CKRecord] = [:]
        var byteCount = 0
        for change in changes {
            if selected.count == 250 { break }
            guard case .saveRecord(let id) = change else { continue }
            guard let record = recordToSave(for: id, in: syncEngine) else {
                guard isCurrent(syncEngine) else { return nil }
                continue
            }
            let size = ((record[Self.payloadKey] as? Data)?.count ?? 0) + 2_048
            if !selected.isEmpty, byteCount + size > Self.maximumBatchBytes { break }
            selected.append(change)
            prepared[id] = record
            byteCount += size
        }
        guard !selected.isEmpty else { return nil }
        let records = prepared
        let batch = await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: selected) { id in
            records[id]
        }
        guard usable(syncEngine), uploadsAllowed, zoneReady else { return nil }
        return batch
    }

    private func recordToSave(for id: CKRecord.ID, in current: CKSyncEngine) -> CKRecord? {
        guard usable(current), uploadsAllowed, zoneReady, let store else { return nil }
        guard id.zoneID == zoneID else { return nil }
        guard store.synchronization.dirty.contains(id.recordName) else {
            current.state.remove(pendingRecordZoneChanges: [.saveRecord(id)])
            return nil
        }
        do {
            guard let entity = store.synchronization.entities[id.recordName] else { throw ClientFailure.invalidLocal }
            do {
                try entity.validate()
            } catch {
                throw ClientFailure.invalidLocal
            }
            guard entity.recordName == id.recordName, Self.validRecordName(id.recordName) else { throw ClientFailure.invalidLocal }
            let data = try JSONEncoder().encode(entity)
            guard data.count <= Self.maximumPayloadBytes else { throw ClientFailure.payloadTooLarge }
            let record: CKRecord
            if let systemFields = store.synchronization.recordSystemFields[id.recordName] {
                record = try restoreRecord(from: systemFields, expectedID: id)
            } else {
                record = CKRecord(recordType: Self.recordType, recordID: id)
            }
            record[Self.payloadKey] = data as NSData
            return record
        } catch {
            handleClientFailure(error)
            return nil
        }
    }

    private func applyRecords(_ records: [CKRecord], deletedNames: [String] = [], in current: CKSyncEngine) throws {
        guard usable(current), let store else { return }
        var entities: [SyncEntity] = []
        var fields: [String: Data] = [:]
        var names = Set(deletedNames)
        for record in records where record.recordID.zoneID == zoneID && record.recordType == Self.recordType {
            let entity = try decode(record)
            entities.append(entity)
            fields[entity.recordName] = try archiveSystemFields(record)
            names.insert(entity.recordName)
        }
        guard !names.isEmpty else { return }
        do {
            try store.applyCloudRecords(entities, systemFields: fields, deletedRecordNames: deletedNames)
        } catch {
            throw ClientFailure.persistence
        }
        reconcile(names, in: current)
    }

    private func handleSentRecords(_ changes: CKSyncEngine.Event.SentRecordZoneChanges, in current: CKSyncEngine) {
        guard changes.deletedRecordIDs.isEmpty, changes.failedRecordDeletes.isEmpty else {
            pause(.invalidState)
            return
        }
        for record in changes.savedRecords where record.recordID.zoneID == zoneID && record.recordType == Self.recordType {
            conflicts[record.recordID.recordName] = nil
        }
        var received = changes.savedRecords
        var deletedNames: [String] = []
        var failures: [CKError] = []
        var conflictLimitReached = false
        do {
            for failure in changes.failedRecordSaves where failure.record.recordID.zoneID == zoneID && failure.record.recordType == Self.recordType {
                let id = failure.record.recordID
                guard Self.validRecordName(id.recordName) else { throw ClientFailure.invalidRecord }
                switch failure.error.code {
                case .serverRecordChanged:
                    guard let serverRecord = failure.error.serverRecord,
                          serverRecord.recordID == id,
                          serverRecord.recordType == Self.recordType else { throw ClientFailure.invalidRecord }
                    received.append(serverRecord)
                    conflicts[id.recordName, default: 0] += 1
                    if conflicts[id.recordName, default: 0] >= 5 {
                        conflictLimitReached = true
                    }
                case .unknownItem:
                    guard store?.synchronization.recordSystemFields[id.recordName] != nil else { throw ClientFailure.invalidRecord }
                    deletedNames.append(id.recordName)
                default:
                    failures.append(failure.error)
                }
            }
            try applyRecords(received, deletedNames: deletedNames, in: current)
        } catch {
            handleClientFailure(error)
            return
        }
        guard isCurrent(current) else { return }
        if conflictLimitReached {
            pause(.conflictLimit)
            return
        }
        for error in failures {
            guard isCurrent(current) else { return }
            handleCloudError(error)
        }
    }

    private func reconcile(_ names: Set<String>, in current: CKSyncEngine) {
        guard usable(current), let store else { return }
        var saves: [CKSyncEngine.PendingRecordZoneChange] = []
        var removals: [CKSyncEngine.PendingRecordZoneChange] = []
        for name in names.sorted() {
            let change = CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: name, zoneID: zoneID))
            if store.synchronization.dirty.contains(name) {
                guard store.synchronization.entities[name] != nil else {
                    pause(.invalidLocal)
                    return
                }
                saves.append(change)
            } else {
                removals.append(change)
                conflicts[name] = nil
            }
        }
        if !removals.isEmpty {
            current.state.remove(pendingRecordZoneChanges: removals)
        }
        if uploadsAllowed, zoneReady, !saves.isEmpty {
            current.state.add(pendingRecordZoneChanges: saves)
        }
    }

    private func enqueueDirty(in current: CKSyncEngine) {
        guard usable(current), uploadsAllowed, zoneReady, let store else { return }
        let names = store.synchronization.dirty
        guard names.allSatisfy({ Self.validRecordName($0) && store.synchronization.entities[$0]?.recordName == $0 }) else {
            pause(.invalidLocal)
            return
        }
        let pending = Set(current.state.pendingRecordZoneChanges)
        let changes = names.sorted().map {
            CKSyncEngine.PendingRecordZoneChange.saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID))
        }.filter { !pending.contains($0) }
        if !changes.isEmpty {
            current.state.add(pendingRecordZoneChanges: changes)
        }
    }

    private func decode(_ record: CKRecord) throws -> SyncEntity {
        guard Self.validRecordName(record.recordID.recordName),
              let data = record[Self.payloadKey] as? Data,
              data.count <= Self.maximumPayloadBytes else { throw ClientFailure.invalidRecord }
        do {
            let entity = try JSONDecoder().decode(SyncEntity.self, from: data)
            try entity.validate()
            guard entity.recordName == record.recordID.recordName else { throw ClientFailure.invalidRecord }
            return entity
        } catch {
            throw ClientFailure.invalidRecord
        }
    }

    private func archiveSystemFields(_ record: CKRecord) throws -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        guard coder.error == nil, !coder.encodedData.isEmpty else { throw ClientFailure.invalidSystemFields }
        return coder.encodedData
    }

    private func restoreRecord(from data: Data, expectedID: CKRecord.ID) throws -> CKRecord {
        do {
            let coder = try NSKeyedUnarchiver(forReadingFrom: data)
            coder.requiresSecureCoding = true
            coder.decodingFailurePolicy = .setErrorAndReturn
            let record = CKRecord(coder: coder)
            coder.finishDecoding()
            guard coder.error == nil,
                  let record,
                  record.recordID == expectedID,
                  record.recordType == Self.recordType,
                  record.recordChangeTag != nil else { throw ClientFailure.invalidSystemFields }
            return record
        } catch {
            throw ClientFailure.invalidSystemFields
        }
    }

    private static func validRecordName(_ name: String) -> Bool {
        let components = name.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count == 2,
              let kind = SyncKind(rawValue: String(components[0])),
              let id = UUID(uuidString: String(components[1])) else { return false }
        return name == kind.rawValue + ":" + id.uuidString.lowercased()
    }

    private func isCurrent(_ candidate: CKSyncEngine) -> Bool {
        engine === candidate && !persistenceHalted
    }

    private func usable(_ candidate: CKSyncEngine) -> Bool {
        guard isCurrent(candidate) else { return false }
        guard let store else {
            detachEngine()
            return false
        }
        guard store.cloudPersistenceAvailable else {
            haltForPersistence()
            return false
        }
        guard let boundScope, store.synchronization.accountScope == boundScope else {
            pause(.accountMismatch)
            return false
        }
        if let reason = store.synchronization.blockedReason, !Self.canRetry(reason) {
            detachEngine()
            publish(.blocked(Self.safePauseMessage(reason)))
            return false
        }
        return true
    }

    private func accountMayHaveChanged() {
        guard !persistenceHalted, container != nil else { return }
        if let reason = store?.synchronization.blockedReason, !Self.canRetry(reason) { return }
        pause(.accountChanged, status: .waiting("iCloud 账户状态已变化，已停止同步并保留本地数据。点击同步重新验证原账户。"))
    }

    private func detachEngine() {
        generation = UUID()
        let previous = engine
        engine = nil
        container = nil
        boundUserID = nil
        boundScope = nil
        uploadsAllowed = false
        zoneReady = false
        needsInitialZone = false
        fetching = false
        sending = false
        operation?.cancel()
        if let previous {
            let pendingCancellation = cancellation
            cancellation = Task {
                await pendingCancellation?.value
                await previous.cancelOperations()
            }
        }
    }

    private func pause(_ reason: PauseReason, status: CloudSyncStatus? = nil) {
        detachEngine()
        guard let store else { return }
        do {
            try store.pauseCloudSync(reason: reason.rawValue)
            noteIssue(status ?? .blocked(reason.rawValue))
        } catch {
            haltForPersistence()
        }
    }

    private func haltForPersistence() {
        persistenceHalted = true
        detachEngine()
        noteIssue(.failed(Self.persistenceMessage))
    }

    private func handleClientFailure(_ error: any Error) {
        guard let failure = error as? ClientFailure else {
            haltForPersistence()
            return
        }
        switch failure {
        case .invalidRecord: pause(.invalidRecord)
        case .invalidLocal: pause(.invalidLocal)
        case .invalidSystemFields: pause(.invalidState)
        case .payloadTooLarge: pause(.payloadTooLarge)
        case .persistence: haltForPersistence()
        }
    }

    private func handleCloudError(_ error: any Error, depth: Int = 0) {
        guard let cloudError = error as? CKError else {
            detachEngine()
            noteIssue(.failed("无法完成 iCloud 请求。本地数据已保留，可稍后点击同步重试。"))
            return
        }
        let retryDetail = engine == nil || !uploadsAllowed
            ? "尚未开始上传，请稍后点击同步重试。"
            : "等待系统安排重试；本地更改已保留。"
        switch cloudError.code {
        case .partialFailure:
            if depth < 3, let errors = cloudError.partialErrorsByItemID, !errors.isEmpty {
                let attempt = generation
                for itemError in errors.values {
                    guard attempt == generation else { return }
                    handleCloudError(itemError, depth: depth + 1)
                }
            } else {
                noteIssue(.waiting("部分更改未获得云端确认，本地数据已保留。"))
            }
        case .notAuthenticated:
            pause(.accountUnavailable, status: .signedOut)
        case .accountTemporarilyUnavailable:
            noteIssue(.waiting("iCloud 账户暂时不可用。" + retryDetail))
        case .networkFailure, .networkUnavailable:
            noteIssue(.waiting("网络暂不可用。" + retryDetail))
        case .serviceUnavailable, .requestRateLimited, .zoneBusy:
            noteIssue(.waiting("iCloud 服务暂忙或请求受限。" + retryDetail))
        case .quotaExceeded:
            noteIssue(.waiting("iCloud 存储空间不足；本地更改已保留，请释放空间后重试。"))
        case .zoneNotFound, .userDeletedZone:
            pause(.zoneRemoved)
        case .missingEntitlement, .badContainer, .badDatabase:
            pause(.serviceConfiguration)
        case .permissionFailure, .managedAccountRestricted:
            pause(.accessRestricted)
        case .invalidArguments, .serverRejectedRequest, .incompatibleVersion, .constraintViolation:
            pause(.serviceConfiguration)
        case .serverRecordChanged:
            noteIssue(.waiting("检测到并发更改，仍需确认合并后的记录；本地数据已保留。"))
        case .batchRequestFailed:
            noteIssue(.waiting("本批更改未全部确认，需在相关问题解决后重试。"))
        case .operationCancelled:
            noteIssue(.waiting("本轮同步已取消，尚未确认全部更改。"))
        case .limitExceeded:
            pause(.requestTooLarge)
        default:
            detachEngine()
            noteIssue(.failed("iCloud 未能完成请求，已停止本轮同步并保留本地数据。可稍后点击同步重试。"))
        }
    }

    private func noteIssue(_ status: CloudSyncStatus) {
        issueRevision &+= 1
        lastIssue = status
        publish(status)
    }

    private func publish(_ status: CloudSyncStatus) {
        store?.setSyncStatus(status)
    }

    private func publishBackgroundOutcome() {
        guard engine != nil, !persistenceHalted else { return }
        if fetching || sending {
            publish(.syncing)
        } else if let lastIssue {
            publish(lastIssue)
        } else if store?.synchronization.dirty.isEmpty == false {
            publish(.waiting("本地仍有未确认的更改，等待后续同步。"))
        } else {
            publish(.waiting("后台本轮处理已结束；完整同步状态将在主动同步完成后确认。"))
        }
    }

    private enum ClientFailure: Error {
        case invalidRecord
        case invalidLocal
        case invalidSystemFields
        case payloadTooLarge
        case persistence
    }

    private enum PauseReason: String {
        case accountUnavailable = "iCloud 账户不可用，已暂停同步并保留本地数据。恢复原账户后可重试。"
        case accountChanged = "iCloud 账户发生变化，已暂停同步。重新验证原账户前不会上传本地数据。"
        case accountMismatch = "当前账户、容器或环境与原绑定不一致。不会将原有数据上传到另一账户或环境，请恢复原配置后重试。"
        case zoneRemoved = "云端同步区域已删除或无法确认其原有状态。已保留本地数据并停止同步，不会自动重建区域或重新上传旧数据。"
        case invalidRecord = "云端记录的格式、版本或标识不受支持。已停止同步且不推进检查点，请先修复记录或升级应用。"
        case invalidLocal = "本地同步记录未通过校验。已停止同步并保留数据，请先修复本地数据。"
        case invalidState = "本地同步检查点或记录元数据无效。已停止同步，不会自动清空检查点或重建云端数据。"
        case payloadTooLarge = "单条记录的同步内容超过 900 KB。已保留本地内容并暂停同步，请缩短内容后点击同步重试。"
        case serviceConfiguration = "CloudKit 容器、数据库结构或签名能力尚未正确配置。请完成配置和生产环境结构部署后重试；本地数据已保留。"
        case accessRestricted = "当前应用或账户没有所需的 CloudKit 访问权限。权限恢复后可重试；本地数据已保留。"
        case conflictLimit = "同一记录持续发生并发冲突，已停止本轮同步。请等待其他设备完成编辑后点击同步重试。"
        case requestTooLarge = "云端拒绝了过大的同步请求。已保留本地更改并暂停同步，需要调整记录或批次大小后再试。"
    }

    private static func canRetry(_ reason: String) -> Bool {
        guard let reason = PauseReason(rawValue: reason) else { return false }
        switch reason {
        case .accountUnavailable, .accountChanged, .accountMismatch, .payloadTooLarge,
             .serviceConfiguration, .accessRestricted, .conflictLimit, .requestTooLarge:
            return true
        default:
            return false
        }
    }

    private static func safePauseMessage(_ reason: String) -> String {
        PauseReason(rawValue: reason)?.rawValue ?? "同步已被本地数据存储暂停。数据已保留，请先解决存储或数据校验问题。"
    }

    private struct Configuration {
        var identifier: String
        var environment: String
    }

    private enum ConfigurationIssue: Error {
        case disabled
        case missingContainer
        case invalidSignature
        case missingCloudKit
        case unauthorizedContainer
        case missingEnvironment
        case missingIdentity
        case missingPush
        case missingIOSEnvironment
        case missingIOSBackgroundMode
        case unsupportedPlatform

        var status: CloudSyncStatus {
            switch self {
            case .disabled:
                return .notConfigured
            case .missingContainer:
                return .blocked("已声明启用云同步，但未配置有效的 CloudKit 容器标识。本地数据未上传。")
            case .invalidSignature:
                return .blocked("当前运行程序没有可验证的开发者签名，无法启用 iCloud。本地数据未上传。")
            case .missingCloudKit:
                return .blocked("当前进程签名未包含 CloudKit 服务能力。本地数据未上传。")
            case .unauthorizedContainer:
                return .blocked("请求的容器未包含在当前进程签名的 iCloud 容器授权中。本地数据未上传。")
            case .missingEnvironment:
                return .blocked("当前进程签名未指定有效的 CloudKit 开发或生产环境。本地数据未上传。")
            case .missingIdentity:
                return .blocked("当前进程签名缺少一致的开发团队与应用标识。本地数据未上传。")
            case .missingPush:
                return .blocked("当前进程签名缺少有效的远程推送能力。本地数据未上传。")
            case .missingIOSEnvironment:
                return .blocked("iOS 构建必须配置与签名一致的 OnePageCloudKitEnvironment，并签署 iCloud 与推送能力。当前未启动 CloudKit，本地数据未上传。")
            case .missingIOSBackgroundMode:
                return .blocked("iOS 构建尚未配置远程通知后台模式。还需签署 iCloud 与推送能力；本地数据未上传。")
            case .unsupportedPlatform:
                return .notConfigured
            }
        }
    }

    private static func readConfiguration() -> Result<Configuration, ConfigurationIssue> {
        let bundle = Bundle.main
        guard let enabled = bundle.object(forInfoDictionaryKey: "OnePageCloudKitEnabled") as? NSNumber,
              CFGetTypeID(enabled) == CFBooleanGetTypeID(), enabled.boolValue else {
            return .failure(.disabled)
        }
        guard let rawIdentifier = bundle.object(forInfoDictionaryKey: "OnePageCloudKitContainerIdentifier") as? String else {
            return .failure(.missingContainer)
        }
        let identifier = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard identifier.range(of: "^iCloud\\.[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*$", options: .regularExpression) != nil else {
            return .failure(.missingContainer)
        }
        #if os(macOS)
        var process: SecCode?
        let flags = SecCSFlags(rawValue: 0)
        guard SecCodeCopySelf(flags, &process) == errSecSuccess,
              let process,
              SecCodeCheckValidity(process, flags, nil) == errSecSuccess else {
            return .failure(.invalidSignature)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(process, flags, &staticCode) == errSecSuccess, let staticCode else {
            return .failure(.invalidSignature)
        }
        var result: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &result) == errSecSuccess,
              let information = result as? [String: Any],
              let cms = information[kSecCodeInfoCMS as String] as? Data, !cms.isEmpty,
              let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] else {
            return .failure(.invalidSignature)
        }
        guard let services = entitlements["com.apple.developer.icloud-services"] as? [String], services.contains("CloudKit") else {
            return .failure(.missingCloudKit)
        }
        guard let containers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String], containers.contains(identifier) else {
            return .failure(.unauthorizedContainer)
        }
        guard let environment = entitlements["com.apple.developer.icloud-container-environment"] as? String,
              ["Development", "Production"].contains(environment) else {
            return .failure(.missingEnvironment)
        }
        guard let team = entitlements["com.apple.developer.team-identifier"] as? String,
              team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              information[kSecCodeInfoTeamIdentifier as String] as? String == team,
              let bundleID = bundle.bundleIdentifier, !bundleID.isEmpty,
              information[kSecCodeInfoIdentifier as String] as? String == bundleID,
              let applicationID = entitlements["com.apple.application-identifier"] as? String,
              applicationID == team + "." + bundleID else {
            return .failure(.missingIdentity)
        }
        guard let pushEnvironment = entitlements["com.apple.developer.aps-environment"] as? String,
              ["development", "production"].contains(pushEnvironment) else {
            return .failure(.missingPush)
        }
        return .success(Configuration(identifier: identifier, environment: environment))
        #elseif os(iOS)
        guard let environment = bundle.object(forInfoDictionaryKey: "OnePageCloudKitEnvironment") as? String,
              ["Development", "Production"].contains(environment) else {
            return .failure(.missingIOSEnvironment)
        }
        guard let modes = bundle.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String], modes.contains("remote-notification") else {
            return .failure(.missingIOSBackgroundMode)
        }
        return .success(Configuration(identifier: identifier, environment: environment))
        #else
        return .failure(.unsupportedPlatform)
        #endif
    }

    private final class AccountObserver: @unchecked Sendable {
        private let token: any NSObjectProtocol

        init(onChange: @escaping @Sendable () -> Void) {
            token = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in
                onChange()
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(token)
        }
    }
}
