//
//  OursPrivacyPersistence.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//

import Foundation

enum PersistenceType: String, CaseIterable {
    case events
}

/// Identity persisted across app launches. `visitorId` is a stable per-install UUID
/// the SDK uses as the `visitor_id` field on every canonical event item.
/// `isManuallySetId` flips to true only when the host app calls `setVisitorId(...)`
/// (Pass B); otherwise it stays false.
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

    // Legacy keys (Mixpanel/super-properties era) — read once on first
    // canonical launch so we can clean them up, then never written again.
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

class OursPrivacyPersistence {

    let instanceName: String
    let opdb: OPDB

    init(instanceName: String) {
        self.instanceName = instanceName
        opdb = OPDB.init(token: instanceName)
    }

    deinit {
        opdb.close()
    }

    func closeDB() {
        opdb.close()
    }

    func saveEntity(_ entity: InternalProperties, type: PersistenceType, flag: Bool = false) {
        if let data = JSONHandler.serializeJSONObject(entity) {
            opdb.insertRow(type, data: data, flag: flag)
        }
    }

    func saveEntities(_ entities: Queue, type: PersistenceType, flag: Bool = false) {
        for entity in entities {
            saveEntity(entity, type: type)
        }
    }

    func loadEntitiesInBatch(type: PersistenceType, batchSize: Int = Int.max, flag: Bool = false, excludeAutomaticEvents: Bool = false) -> [InternalProperties] {
        var entities = opdb.readRows(type, numRows: batchSize, flag: flag)
        if excludeAutomaticEvents && type == .events {
            entities = entities.filter { !(($0["event"] as? String) ?? "").hasPrefix("$ae_") }
        }
        return entities
    }

    func removeEntitiesInBatch(type: PersistenceType, ids: [Int32]) {
        opdb.deleteRows(type, ids: ids)
    }

    func resetEntities() {
        for pType in PersistenceType.allCases {
            opdb.deleteRows(pType, isDeleteAll: true)
        }
    }

    /// One-shot cleanup of state written by the pre-canonical SDK. Runs once per
    /// install: clears the SQLite events queue (rows were in the legacy Mixpanel
    /// shape the server can't read) and removes legacy UserDefaults identity /
    /// super-properties / timed-events keys.
    func wipeLegacyStateIfNeeded() {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        let doneKey = "\(prefix)\(OursPrivacyUserDefaultsKeys.legacyCleanupDone)"
        if defaults.bool(forKey: doneKey) {
            return
        }

        opdb.deleteRows(.events, isDeleteAll: true)

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
        defaults.synchronize()
    }
}
