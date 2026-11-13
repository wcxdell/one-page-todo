import Foundation
import Combine

struct Todo: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var details: String?
    var date: Date?
    var groupID: UUID?
    var completedAt: Date?
    var createdAt = Date()
    var displayTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("未命名任务") : title }
}

struct TaskGroup: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
}

struct SavedData: Codable, Equatable, Sendable {
    var tasks: [Todo] = []
    var groups: [TaskGroup] = []
}

@MainActor
final class Store: ObservableObject {
    @Published private(set) var data = SavedData()
    @Published var error: String?
    @Published private(set) var undoLabel: String?
    @Published private(set) var syncStatus: CloudSyncStatus = .notConfigured
    private(set) var synchronization = SyncMetadata()
    private var undoSnapshot: StoreUndo?
    private let fileURL: URL
    private let allowsCloudSync: Bool
    private var canWrite = true
    private var needsMigrationBackup = false
    private var cloudSync: CloudSync?

    var cloudPersistenceAvailable: Bool { canWrite }
    var hasCloudConnection: Bool { cloudSync?.hasCloudConnection == true }

    init(fileURL: URL? = nil) {
        allowsCloudSync = fileURL == nil
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnePage/tasks.json")
        do {
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let document = try JSONDecoder().decode(SyncDocument.self, from: Data(contentsOf: self.fileURL))
                data = document.data
                synchronization = document.metadata
                needsMigrationBackup = document.migratedLegacy
            }
        } catch {
            canWrite = false
            self.error = "无法读取任务文件，已保留原文件。请检查 \(self.fileURL.path)\n\(error.localizedDescription)"
        }
    }

    func startSync() async {
        guard allowsCloudSync, canWrite else { return }
        if cloudSync == nil { cloudSync = CloudSync(store: self) }
        await cloudSync?.start()
    }

    func syncNow() async {
        guard allowsCloudSync, canWrite else { return }
        if cloudSync == nil { cloudSync = CloudSync(store: self) }
        await cloudSync?.syncNow()
    }

    func setSyncStatus(_ status: CloudSyncStatus) { syncStatus = status }

    private func persist(_ candidate: SavedData, metadata: SyncMetadata) throws {
        guard canWrite else { throw SyncFailure.storageUnavailable }
        var metadata = metadata
        metadata.localTimeZoneIdentifier = TimeZone.current.identifier
        try metadata.validate()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if needsMigrationBackup {
            let backup = fileURL.appendingPathExtension("before-icloud-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: fileURL, to: backup)
            needsMigrationBackup = false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(SyncDocument(data: candidate, metadata: metadata)).write(to: fileURL, options: .atomic)
        synchronization = metadata
        if data != candidate { data = candidate }
    }

    private func change(_ label: String? = nil, _ body: (inout SavedData) -> Void) {
        guard canWrite else { return }
        let previous = data
        var candidate = previous
        body(&candidate)
        guard candidate != previous else { return }
        do {
            var metadata = synchronization
            try metadata.captureChanges(from: previous, to: candidate)
            try persist(candidate, metadata: metadata)
            undoSnapshot = label == nil ? nil : StoreUndo(before: previous, after: candidate)
            undoLabel = label
            cloudSync?.localChangesDidCommit()
        } catch {
            self.error = "保存失败，请检查磁盘空间和文件权限。\n\(error.localizedDescription)"
        }
    }

    func bindCloudAccount(_ scope: String, preparingZone: Bool = false) throws {
        if let previous = synchronization.accountScope, previous != scope { throw SyncFailure.accountChanged }
        var metadata = synchronization
        metadata.accountScope = scope
        metadata.blockedReason = nil
        metadata.zoneInitializationPending = preparingZone
        try persist(data, metadata: metadata)
    }

    func markCloudZoneReady() throws {
        var metadata = synchronization
        metadata.zoneInitializationPending = false
        try persist(data, metadata: metadata)
    }

    func pauseCloudSync(reason: String) throws {
        var metadata = synchronization
        metadata.blockedReason = reason
        try persist(data, metadata: metadata)
    }

    func setCloudEngineState(_ state: Data) throws {
        var metadata = synchronization
        metadata.engineState = state
        try persist(data, metadata: metadata)
    }

    func applyCloudRecords(_ incoming: [SyncEntity], systemFields: [String: Data], deletedRecordNames: [String]) throws {
        guard canWrite else { throw SyncFailure.storageUnavailable }
        var metadata = synchronization
        for remote in incoming {
            try remote.validate()
            let name = remote.recordName
            let merged = try metadata.entities[name]?.merged(with: remote) ?? remote
            metadata.entities[name] = merged
            if merged == remote { metadata.dirty.remove(name) }
            else { metadata.dirty.insert(name) }
        }
        for (name, fields) in systemFields {
            guard metadata.entities[name] != nil else { throw SyncFailure.invalidData }
            metadata.recordSystemFields[name] = fields
        }
        for name in deletedRecordNames {
            let version = try metadata.nextVersion()
            let tombstone = try SyncEntity.tombstone(recordName: name, version: version)
            metadata.entities[name] = try metadata.entities[name]?.merged(with: tombstone) ?? tombstone
            metadata.recordSystemFields[name] = nil
            metadata.dirty.insert(name)
        }
        let candidate = try metadata.materializedData()
        try persist(candidate, metadata: metadata)
    }

    @discardableResult
    func addTask(title: String, date: Date?, groupID: UUID?) -> UUID? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let task = Todo(title: title, date: date.map { Calendar.current.startOfDay(for: $0) }, groupID: groupID)
        change { $0.tasks.append(task) }
        return data.tasks.contains(where: { $0.id == task.id }) ? task.id : nil
    }

    func update(_ id: UUID, _ edit: (inout Todo) -> Void) {
        guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        change { edit(&$0.tasks[index]) }
    }

    func toggle(_ id: UUID) {
        update(id) { $0.completedAt = $0.completedAt == nil ? Date() : nil }
    }

    func move(_ id: UUID, to groupID: UUID?) {
        guard groupID == nil || data.groups.contains(where: { $0.id == groupID }) else { return }
        guard let index = data.tasks.firstIndex(where: { $0.id == id }) else { return }
        change("已移动任务") { $0.tasks[index].groupID = groupID }
    }

    func deleteTask(_ id: UUID) {
        change("已删除任务") { $0.tasks.removeAll { $0.id == id } }
    }

    @discardableResult
    func addGroup(_ name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let group = TaskGroup(name: name)
        change { $0.groups.append(group) }
        return data.groups.contains(where: { $0.id == group.id }) ? group.id : nil
    }

    func renameGroup(_ id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = data.groups.firstIndex(where: { $0.id == id }) else { return }
        change { $0.groups[index].name = name }
    }

    func deleteGroup(_ id: UUID) {
        change("已删除分组，任务已移至未分组") { data in
            data.groups.removeAll { $0.id == id }
            for index in data.tasks.indices where data.tasks[index].groupID == id {
                data.tasks[index].groupID = nil
            }
        }
    }

    func undo() {
        guard let snapshot = undoSnapshot else { return }
        let restored = snapshot.applying(to: data)
        change { $0 = restored }
        if restored == data { undoSnapshot = nil; undoLabel = nil }
    }

    func groupName(_ id: UUID?) -> String {
        data.groups.first(where: { $0.id == id })?.name ?? L("未分组")
    }
}
