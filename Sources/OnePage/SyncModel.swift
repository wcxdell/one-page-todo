import Foundation

// Shared wire format for macOS and iOS. Keep record names, field keys and date encoding stable.
enum SyncKind: String, Codable, Sendable { case task, group }

// Due dates are calendar days, not instants: travelling must not move a task to yesterday.
enum SyncDay {
    static func key(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    static func date(_ key: String, timeZone: TimeZone = .current) -> Date? {
        guard key.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              Self.key(date, timeZone: timeZone) == key else { return nil }
        return date
    }
}

enum SyncFailure: LocalizedError {
    case invalidData
    case newerSchema
    case accountChanged
    case storageUnavailable
    case permanentlyRemoved

    var errorDescription: String? {
        switch self {
        case .invalidData: "同步数据格式不正确，已保留本地数据并停止同步。"
        case .newerSchema: "云端数据来自更新版本，请升级应用后再同步。"
        case .accountChanged: "iCloud 账号或同步空间已更换。为保护原数据，已暂停同步，请切回原账号和空间。"
        case .storageUnavailable: "本地数据暂时无法安全保存，已暂停云同步。"
        case .permanentlyRemoved: "这条记录已在云端被永久移除，不能用旧记录覆盖。其他本地数据已保留。"
        }
    }
}

struct SyncVersion: Codable, Equatable, Comparable, Sendable {
    var time: Date
    var counter: UInt64
    var deviceID: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.deviceID < rhs.deviceID
    }

    static let legacy = SyncVersion(time: Date(timeIntervalSince1970: 0), counter: 0, deviceID: "legacy")
}

enum SyncValue: Codable, Equatable, Sendable {
    case string(String), date(Date), bool(Bool), null

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var date: Date? { if case .date(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
}

struct SyncField: Codable, Equatable, Sendable {
    var value: SyncValue
    var version: SyncVersion
}

struct SyncEntity: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var id: UUID
    var kind: SyncKind
    var fields: [String: SyncField]

    var recordName: String { kind.rawValue + ":" + id.uuidString.lowercased() }
    var isDeleted: Bool { fields["deleted"]?.value.bool == true || fields["serverDeleted"]?.value.bool == true }

    func validate() throws {
        guard schemaVersion == 1 else { throw SyncFailure.newerSchema }
        guard fields["deleted"]?.value.bool != nil else { throw SyncFailure.invalidData }
        if let permanent = fields["serverDeleted"], permanent.value != .bool(true) { throw SyncFailure.invalidData }
        for field in fields.values {
            guard field.version.time.timeIntervalSinceReferenceDate.isFinite,
                  !field.version.deviceID.isEmpty, field.version.counter < UInt64.max else { throw SyncFailure.invalidData }
            if let date = field.value.date, !date.timeIntervalSinceReferenceDate.isFinite { throw SyncFailure.invalidData }
        }
        // A durable tombstone can arrive before its original record.
        if isDeleted { return }
        guard fields["createdAt"]?.value.date != nil else { throw SyncFailure.invalidData }
        switch kind {
        case .group:
            guard fields["name"]?.value.string != nil else { throw SyncFailure.invalidData }
        case .task:
            guard fields["title"]?.value.string != nil else { throw SyncFailure.invalidData }
            guard let day = fields["date"]?.value,
                  day == .null || day.string.flatMap({ SyncDay.date($0) }) != nil,
                  let completed = fields["completedAt"]?.value,
                  completed == .null || completed.date != nil else { throw SyncFailure.invalidData }
            guard let details = fields["details"]?.value, details == .null || details.string != nil,
                  let group = fields["groupID"]?.value,
                  group == .null || group.string.flatMap(UUID.init(uuidString:)) != nil else { throw SyncFailure.invalidData }
        }
    }

    func merged(with remote: Self) throws -> Self {
        try validate()
        try remote.validate()
        guard id == remote.id, kind == remote.kind else { throw SyncFailure.invalidData }
        var result = self
        for (key, incoming) in remote.fields {
            if let current = result.fields[key] {
                // Equal versions must describe the same edit; otherwise do not silently destroy either version.
                guard incoming.version != current.version || incoming.value == current.value else { throw SyncFailure.invalidData }
                if current.version < incoming.version { result.fields[key] = incoming }
            } else {
                result.fields[key] = incoming
            }
        }
        try result.validate()
        return result
    }

    static func tombstone(recordName: String, version: SyncVersion) throws -> Self {
        let parts = recordName.split(separator: ":")
        guard parts.count == 2, let kind = SyncKind(rawValue: String(parts[0])),
              let id = UUID(uuidString: String(parts[1])) else { throw SyncFailure.invalidData }
        // Server-side hard removals have no comparable client timestamp. Keep an irreversible marker;
        // ordinary app deletes use the separate, undoable `deleted` field instead.
        let removed = SyncField(value: .bool(true), version: version)
        let entity = Self(id: id, kind: kind, fields: ["deleted": removed, "serverDeleted": removed])
        guard entity.recordName == recordName else { throw SyncFailure.invalidData }
        return entity
    }
}

struct SyncMetadata: Codable, Equatable, Sendable {
    var schemaVersion = 1
    var deviceID = UUID().uuidString
    var sequence: UInt64 = 0
    var entities: [String: SyncEntity] = [:]
    var dirty: Set<String> = []
    var recordSystemFields: [String: Data] = [:]
    var engineState: Data?
    var accountScope: String?
    var blockedReason: String?
    var zoneInitializationPending = false
    var localTimeZoneIdentifier = TimeZone.current.identifier

    static func migrating(_ data: SavedData) -> Self {
        var metadata = Self()
        for task in data.tasks {
            let entity = SyncEntity(id: task.id, kind: .task,
                                    fields: taskValues(task).mapValues { SyncField(value: $0, version: .legacy) })
            metadata.entities[entity.recordName] = entity
            metadata.dirty.insert(entity.recordName)
        }
        for (index, group) in data.groups.enumerated() {
            let values: [String: SyncValue] = ["name": .string(group.name), "deleted": .bool(false),
                                              "createdAt": .date(Date(timeIntervalSince1970: Double(index)))]
            let entity = SyncEntity(id: group.id, kind: .group,
                                    fields: values.mapValues { SyncField(value: $0, version: .legacy) })
            metadata.entities[entity.recordName] = entity
            metadata.dirty.insert(entity.recordName)
        }
        return metadata
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw SyncFailure.newerSchema }
        guard !deviceID.isEmpty, sequence < UInt64.max,
              dirty.isSubset(of: Set(entities.keys)) else { throw SyncFailure.invalidData }
        for (name, entity) in entities {
            guard name == entity.recordName else { throw SyncFailure.invalidData }
            try entity.validate()
        }
    }

    mutating func nextVersion(now: Date = .now) throws -> SyncVersion {
        let latest = entities.values.flatMap { $0.fields.values.map(\.version) }.max()
        let counter = max(sequence, latest?.counter ?? 0)
        guard counter < UInt64.max - 1 else { throw SyncFailure.invalidData }
        sequence = counter + 1
        return SyncVersion(time: max(now, latest?.time ?? now), counter: sequence, deviceID: deviceID)
    }

    mutating func captureChanges(from old: SavedData, to new: SavedData, now: Date = .now) throws {
        guard old != new else { return }
        let version = try nextVersion(now: now)
        for name in new.tasks.map({ "task:" + $0.id.uuidString.lowercased() }) + new.groups.map({ "group:" + $0.id.uuidString.lowercased() }) {
            if entities[name]?.fields["serverDeleted"]?.value.bool == true { throw SyncFailure.permanentlyRemoved }
        }
        let oldTasks = Dictionary(uniqueKeysWithValues: old.tasks.map { ($0.id, $0) })
        let newTasks = Dictionary(uniqueKeysWithValues: new.tasks.map { ($0.id, $0) })
        for task in new.tasks where oldTasks[task.id] != task {
            setValues(Self.taskValues(task), previous: oldTasks[task.id].map(Self.taskValues),
                      id: task.id, kind: .task, version: version)
        }
        for task in old.tasks where newTasks[task.id] == nil {
            setValues(["deleted": .bool(true)], previous: nil, id: task.id, kind: .task, version: version)
        }
        let oldGroups = Dictionary(uniqueKeysWithValues: old.groups.map { ($0.id, $0) })
        let newGroups = Dictionary(uniqueKeysWithValues: new.groups.map { ($0.id, $0) })
        for group in new.groups where oldGroups[group.id] != group {
            let name = "group:" + group.id.uuidString.lowercased()
            let values: [String: SyncValue] = ["name": .string(group.name), "deleted": .bool(false),
                "createdAt": entities[name]?.fields["createdAt"]?.value ?? .date(now)]
            var previous: [String: SyncValue]?
            if let oldGroup = oldGroups[group.id] {
                previous = ["name": .string(oldGroup.name), "deleted": .bool(false), "createdAt": values["createdAt"]!]
            }
            setValues(values, previous: previous, id: group.id, kind: .group, version: version)
        }
        for group in old.groups where newGroups[group.id] == nil {
            setValues(["deleted": .bool(true)], previous: nil, id: group.id, kind: .group, version: version)
        }
        try validate()
    }

    private mutating func setValues(_ values: [String: SyncValue], previous: [String: SyncValue]?,
                                    id: UUID, kind: SyncKind, version: SyncVersion) {
        var entity = entities[kind.rawValue + ":" + id.uuidString.lowercased()] ?? SyncEntity(id: id, kind: kind, fields: [:])
        for (key, value) in values where previous?[key] != value {
            entity.fields[key] = SyncField(value: value, version: version)
        }
        entities[entity.recordName] = entity
        dirty.insert(entity.recordName)
    }

    private static func taskValues(_ task: Todo) -> [String: SyncValue] {
        ["title": .string(task.title), "details": task.details.map(SyncValue.string) ?? .null,
         "date": task.date.map { .string(SyncDay.key($0)) } ?? .null,
         "groupID": task.groupID.map { .string($0.uuidString.lowercased()) } ?? .null,
         "completedAt": task.completedAt.map(SyncValue.date) ?? .null,
         "createdAt": .date(task.createdAt), "deleted": .bool(false)]
    }

    func materializedData() throws -> SavedData {
        try validate()
        let live = entities.values.filter { !$0.isDeleted }
        let groups = live.filter { $0.kind == .group }.sorted {
            let lhs = $0.fields["createdAt"]!.value.date!, rhs = $1.fields["createdAt"]!.value.date!
            return lhs == rhs ? $0.recordName < $1.recordName : lhs < rhs
        }.map { TaskGroup(id: $0.id, name: $0.fields["name"]!.value.string!) }
        let groupIDs = Set(groups.map(\.id))
        var tasks: [Todo] = []
        for entity in live where entity.kind == .task {
            let groupText: String? = entity.fields["groupID"]?.value.string
            let groupID: UUID? = groupText.flatMap { UUID(uuidString: $0) }
            let resolvedGroup: UUID? = groupID.flatMap { groupIDs.contains($0) ? $0 : nil }
            let dayText: String? = entity.fields["date"]?.value.string
            let dueDate: Date? = dayText.flatMap { SyncDay.date($0) }
            let title = entity.fields["title"]!.value.string!
            let details: String? = entity.fields["details"]?.value.string
            let completion: Date? = entity.fields["completedAt"]?.value.date
            let createdAt = entity.fields["createdAt"]!.value.date!
            tasks.append(Todo(id: entity.id, title: title, details: details, date: dueDate,
                              groupID: resolvedGroup, completedAt: completion, createdAt: createdAt))
        }
        tasks.sort { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
        return SavedData(tasks: tasks, groups: groups)
    }
}

struct SyncDocument: Codable {
    var data: SavedData
    var metadata: SyncMetadata
    var migratedLegacy = false

    private enum CodingKeys: String, CodingKey { case syncMetadata }

    init(data: SavedData, metadata: SyncMetadata) {
        self.data = data
        self.metadata = metadata
    }

    init(from decoder: Decoder) throws {
        data = try SavedData(from: decoder)
        guard Set(data.tasks.map(\.id)).count == data.tasks.count,
              Set(data.groups.map(\.id)).count == data.groups.count else { throw SyncFailure.invalidData }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let existing = try container.decodeIfPresent(SyncMetadata.self, forKey: .syncMetadata) {
            metadata = existing
        } else {
            metadata = .migrating(data)
            migratedLegacy = true
        }
        try metadata.validate()
        let liveTasks = metadata.entities.values.filter { $0.kind == .task && !$0.isDeleted }
        let liveGroups = metadata.entities.values.filter { $0.kind == .group && !$0.isDeleted }
        guard Set(liveTasks.map(\.id)) == Set(data.tasks.map(\.id)),
              Set(liveGroups.map(\.id)) == Set(data.groups.map(\.id)) else { throw SyncFailure.invalidData }
        if !migratedLegacy, metadata.localTimeZoneIdentifier != TimeZone.current.identifier {
            for index in data.tasks.indices {
                let name = "task:" + data.tasks[index].id.uuidString.lowercased()
                if let day = metadata.entities[name]?.fields["date"]?.value.string {
                    data.tasks[index].date = SyncDay.date(day)
                }
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        try data.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .syncMetadata)
    }
}

// Undo only the last local operation's fields; unrelated remote edits must survive.
struct StoreUndo {
    let before: SavedData
    let after: SavedData

    func applying(to current: SavedData) -> SavedData {
        var result = current
        for (position, old) in before.tasks.enumerated() {
            guard let applied = after.tasks.first(where: { $0.id == old.id }) else {
                if !result.tasks.contains(where: { $0.id == old.id }) { result.tasks.insert(old, at: min(position, result.tasks.count)) }
                continue
            }
            guard let index = result.tasks.firstIndex(where: { $0.id == old.id }) else { continue }
            if old.title != applied.title, result.tasks[index].title == applied.title { result.tasks[index].title = old.title }
            if old.details != applied.details, result.tasks[index].details == applied.details { result.tasks[index].details = old.details }
            if old.date != applied.date, result.tasks[index].date == applied.date { result.tasks[index].date = old.date }
            if old.groupID != applied.groupID, result.tasks[index].groupID == applied.groupID { result.tasks[index].groupID = old.groupID }
            if old.completedAt != applied.completedAt, result.tasks[index].completedAt == applied.completedAt { result.tasks[index].completedAt = old.completedAt }
        }
        for (position, old) in before.groups.enumerated() {
            guard let applied = after.groups.first(where: { $0.id == old.id }) else {
                if !result.groups.contains(where: { $0.id == old.id }) { result.groups.insert(old, at: min(position, result.groups.count)) }
                continue
            }
            if let index = result.groups.firstIndex(where: { $0.id == old.id }), old.name != applied.name,
               result.groups[index].name == applied.name { result.groups[index].name = old.name }
        }
        return result
    }
}
