//
//  OursPrivacyPersistence.swift
//  OursPrivacy
//
//  Copyright © 2026 Ours Wellness Inc. All rights reserved.
//

import Foundation

enum PersistenceType: String, CaseIterable {
    case events
}

/// Identity persisted across app launches. `visitorId` is a stable
/// per-install UUID the SDK uses as the `visitor_id` field on every
/// canonical event item. `isManuallySetId` flips to true only when the
/// host app calls ``OursPrivacy/setVisitorId(_:)``.
struct OursPrivacyIdentity {
    let visitorId: String
    let isManuallySetId: Bool
}

struct OursPrivacyUserDefaultsKeys {
    static let suiteName = "OursPrivacy"
    static let prefix = "oursprivacy"
    static let optOutStatus = "OptOutStatus"
    static let visitorId = "OPVisitorId"
    static let isManuallySetId = "OPIsManuallySetId"
    static let eventQueue = "OPEventQueue"

    // Legacy keys (pre-canonical) — read once on first canonical launch so
    // they can be cleaned up, then never written again.
    static let legacyDistinctID = "OPDistinctID"
    static let legacyPeopleDistinctID = "OPPeopleDistinctID"
    static let legacyAnonymousId = "OPAnonymousId"
    static let legacyUserID = "OPUserId"
    static let legacyAlias = "OPAlias"
    static let legacyHadPersistedDistinctId = "OPHadPersistedDistinctId"
    static let legacyTimedEvents = "timedEvents"
    static let legacySuperProperties = "superProperties"
    static let legacyCleanupDone = "OPLegacyCleanupDone"
}

/// Events queue + identity persistence.
///
/// The queue is held in memory and written through to a single
/// ``UserDefaults`` blob on every change. The blob survives app restart,
/// so events queued before the host terminates flush on the next launch.
/// Identity (``OursPrivacyIdentity``) and the opt-out flag are stored
/// separately under their own ``UserDefaults`` keys.
class OursPrivacyPersistence {

    let instanceName: String

    private let queueLock = ReadWriteLock(label: "com.oursprivacy.persistence.queue")
    private var inMemoryQueue: [InternalProperties] = []
    private var nextId: Int32 = 1

    init(instanceName: String) {
        self.instanceName = instanceName
        loadQueueFromDefaults()
    }

    deinit {}

    /// Retained for source compatibility with the previous SQLite-backed
    /// implementation. The in-memory queue has no connection to close.
    func closeDB() {}

    func saveEntity(_ entity: InternalProperties, type: PersistenceType, flag: Bool = false) {
        guard type == .events else { return }
        queueLock.write {
            var item = entity
            item["id"] = nextId
            nextId &+= 1
            inMemoryQueue.append(item)
        }
        persistQueueToDefaults()
    }

    func saveEntities(_ entities: Queue, type: PersistenceType, flag: Bool = false) {
        for entity in entities {
            saveEntity(entity, type: type)
        }
    }

    func loadEntitiesInBatch(type: PersistenceType,
                             batchSize: Int = Int.max,
                             flag: Bool = false,
                             excludeAutomaticEvents: Bool = false) -> [InternalProperties] {
        guard type == .events else { return [] }
        var snapshot: [InternalProperties] = []
        queueLock.read { snapshot = inMemoryQueue }
        if excludeAutomaticEvents {
            snapshot = snapshot.filter { !(($0["event"] as? String) ?? "").hasPrefix("$ae_") }
        }
        if batchSize == Int.max { return snapshot }
        return Array(snapshot.prefix(batchSize))
    }

    func removeEntitiesInBatch(type: PersistenceType, ids: [Int32]) {
        guard type == .events else { return }
        let toRemove = Set(ids)
        queueLock.write {
            inMemoryQueue.removeAll { item in
                guard let id = (item["id"] as? Int32) ?? (item["id"] as? NSNumber)?.int32Value else {
                    return false
                }
                return toRemove.contains(id)
            }
        }
        persistQueueToDefaults()
    }

    func resetEntities() {
        queueLock.write {
            inMemoryQueue.removeAll()
            nextId = 1
        }
        persistQueueToDefaults()
    }

    // MARK: - Queue (de)serialization

    private func queueKey() -> String {
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        return "\(prefix)\(OursPrivacyUserDefaultsKeys.eventQueue)"
    }

    private func loadQueueFromDefaults() {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        guard let data = defaults.data(forKey: queueKey()) else { return }
        guard let array = JSONHandler.deserializeData(data) as? [InternalProperties] else { return }

        queueLock.write {
            inMemoryQueue = array
            // Rebuild the id counter so newly appended items don't collide
            // with anything we just hydrated.
            let maxId = array.compactMap {
                ($0["id"] as? Int32) ?? ($0["id"] as? NSNumber)?.int32Value
            }.max() ?? 0
            nextId = maxId &+ 1
        }
    }

    private func persistQueueToDefaults() {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        var snapshot: [InternalProperties] = []
        queueLock.read { snapshot = inMemoryQueue }
        if snapshot.isEmpty {
            defaults.removeObject(forKey: queueKey())
            return
        }
        guard let data = JSONHandler.serializeJSONObject(snapshot) else {
            OursPrivacyLogger.warn(message: "failed to serialize event queue for persistence")
            return
        }
        defaults.set(data, forKey: queueKey())
    }

    // MARK: - One-shot legacy cleanup

    /// Runs once per install. Removes pre-canonical UserDefaults keys and
    /// the on-disk SQLite database file that earlier releases used as the
    /// events queue. Idempotent.
    func wipeLegacyStateIfNeeded() {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        let doneKey = "\(prefix)\(OursPrivacyUserDefaultsKeys.legacyCleanupDone)"
        if defaults.bool(forKey: doneKey) {
            return
        }

        OursPrivacyPersistence.wipeLegacySQLiteFileIfPresent(instanceName: instanceName)

        for key in [
            OursPrivacyUserDefaultsKeys.legacyDistinctID,
            OursPrivacyUserDefaultsKeys.legacyPeopleDistinctID,
            OursPrivacyUserDefaultsKeys.legacyAnonymousId,
            OursPrivacyUserDefaultsKeys.legacyUserID,
            OursPrivacyUserDefaultsKeys.legacyAlias,
            OursPrivacyUserDefaultsKeys.legacyHadPersistedDistinctId,
            OursPrivacyUserDefaultsKeys.legacyTimedEvents,
            OursPrivacyUserDefaultsKeys.legacySuperProperties,
        ] {
            defaults.removeObject(forKey: "\(prefix)\(key)")
        }
        defaults.set(true, forKey: doneKey)
        defaults.synchronize()
    }

    /// Deletes `<instance>_OPDB.sqlite` (and any companion WAL/SHM files)
    /// from the directory the earlier release wrote to. Public on the type
    /// so tests can verify the cleanup directly.
    static func wipeLegacySQLiteFileIfPresent(instanceName: String) {
        let sanitized = String(instanceName.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
        guard !sanitized.isEmpty else { return }
        let manager = FileManager.default
#if os(iOS)
        guard let directory = manager.urls(for: .libraryDirectory, in: .userDomainMask).last else { return }
#else
        guard let directory = manager.urls(for: .cachesDirectory, in: .userDomainMask).last else { return }
#endif
        let basePath = directory.appendingPathComponent("\(sanitized)_OPDB.sqlite").path
        for path in [basePath, basePath + "-wal", basePath + "-shm"] {
            if manager.fileExists(atPath: path) {
                try? manager.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Static identity + opt-out helpers (unchanged)

    static func saveOptOutStatusFlag(value: Bool, instanceName: String) {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        defaults.setValue(value, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.optOutStatus)")
        defaults.synchronize()
    }

    static func loadOptOutStatusFlag(instanceName: String) -> Bool? {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return nil
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        return defaults.object(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.optOutStatus)") as? Bool
    }

    static func saveIdentity(_ identity: OursPrivacyIdentity, instanceName: String) {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        defaults.set(identity.visitorId, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.visitorId)")
        defaults.set(identity.isManuallySetId, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.isManuallySetId)")
        defaults.synchronize()
    }

    static func loadIdentity(instanceName: String) -> OursPrivacyIdentity {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return OursPrivacyIdentity(visitorId: "", isManuallySetId: false)
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        let visitorId = defaults.string(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.visitorId)") ?? ""
        let isManuallySetId = defaults.bool(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.isManuallySetId)")
        return OursPrivacyIdentity(visitorId: visitorId, isManuallySetId: isManuallySetId)
    }

    static func deleteUserDefaultsData(instanceName: String) {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.visitorId)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.isManuallySetId)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.optOutStatus)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.eventQueue)")
        defaults.synchronize()
    }
}
