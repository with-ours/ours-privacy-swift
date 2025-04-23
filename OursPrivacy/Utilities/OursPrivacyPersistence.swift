//
//  OursPrivacyPersistence.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by ZIHE JIA on 7/9/21.
//  Copyright © 2021 OursPrivacy. All rights reserved.
//

import Foundation

enum LegacyArchiveType: String {
    case events
//    case people
//    case groups
    case properties
    case optOutStatus
}

enum PersistenceType: String, CaseIterable {
    case events
//    case people
//    case groups
}

struct PersistenceConstant {
    static let unIdentifiedFlag = true
}

struct OursPrivacyIdentity {
    let distinctID: String
//    let peopleDistinctID: String?
    let anonymousId: String?
    let userId: String?
    let alias: String?
    let hadPersistedDistinctId: Bool?
}

struct OursPrivacyUserDefaultsKeys {
    static let suiteName = "OursPrivacy"
    static let prefix = "oursprivacy"
    static let optOutStatus = "OptOutStatus"
    static let timedEvents = "timedEvents"
    static let superProperties = "superProperties"
    static let distinctID = "OPDistinctID"
    static let peopleDistinctID = "OPPeopleDistinctID"
    static let anonymousId = "OPAnonymousId"
    static let userID = "OPUserId"
    static let alias = "OPAlias"
    static let hadPersistedDistinctId = "OPHadPersistedDistinctId"
}

class OursPrivacyPersistence {
    
    let instanceName: String
    let opdb: OPDB
    private static let archivedClasses = [NSArray.self, NSDictionary.self, NSSet.self, NSString.self, NSDate.self, NSURL.self, NSNumber.self, NSNull.self]
    
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
            entities = entities.filter { !($0["event"] as! String).hasPrefix("$ae_") }
        }
//        if type == PersistenceType.people {
//            let distinctId = OursPrivacyPersistence.loadIdentity(instanceName: instanceName).distinctID
//            return entities.map { entityWithDistinctId($0, distinctId: distinctId) }
//        }
        return entities
    }
    
    private func entityWithDistinctId(_ entity: InternalProperties, distinctId: String) -> InternalProperties {
        var result = entity;
        result["$distinct_id"] = distinctId
        return result
    }
    
    func removeEntitiesInBatch(type: PersistenceType, ids: [Int32]) {
        opdb.deleteRows(type, ids: ids)
    }
    
//    func identifyPeople(token: String) {
//        opdb.updateRowsFlag(.people, newFlag: !PersistenceConstant.unIdentifiedFlag)
//    }
    
    func resetEntities() {
        for pType in PersistenceType.allCases {
            opdb.deleteRows(pType, isDeleteAll: true)
        }
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
    
    static func saveTimedEvents(timedEvents: InternalProperties, instanceName: String) {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        do {
            let timedEventsData = try NSKeyedArchiver.archivedData(withRootObject: timedEvents, requiringSecureCoding: false)
            defaults.set(timedEventsData, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.timedEvents)")
            defaults.synchronize()
        } catch {
            OursPrivacyLogger.warn(message: "Failed to archive timed events")
        }
    }
    
    static func loadTimedEvents(instanceName: String) -> InternalProperties {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return InternalProperties()
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        guard let timedEventsData  = defaults.data(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.timedEvents)") else {
            return InternalProperties()
        }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClasses: archivedClasses, from: timedEventsData) as? InternalProperties ?? InternalProperties()
        } catch {
            OursPrivacyLogger.warn(message: "Failed to unarchive timed events")
            return InternalProperties()
        }
    }
    
    static func saveSuperProperties(superProperties: InternalProperties, instanceName: String) {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        do {
            let superPropertiesData = try NSKeyedArchiver.archivedData(withRootObject: superProperties, requiringSecureCoding: false)
            defaults.set(superPropertiesData, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.superProperties)")
            defaults.synchronize()
        } catch {
            OursPrivacyLogger.warn(message: "Failed to archive super properties")
        }
    }
    
    static func loadSuperProperties(instanceName: String) -> InternalProperties {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return InternalProperties()
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        guard let superPropertiesData  = defaults.data(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.superProperties)") else {
            return InternalProperties()
        }
        do {
            return try NSKeyedUnarchiver.unarchivedObject(ofClasses: archivedClasses, from: superPropertiesData) as? InternalProperties ?? InternalProperties()
        } catch {
            OursPrivacyLogger.warn(message: "Failed to unarchive super properties")
            return InternalProperties()
        }
    }
    
    static func saveIdentity(_ oursIdentity: OursPrivacyIdentity, instanceName: String) {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        defaults.set(oursIdentity.distinctID, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.distinctID)")
//        defaults.set(oursIdentity.peopleDistinctID, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.peopleDistinctID)")
        defaults.set(oursIdentity.anonymousId, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.anonymousId)")
        defaults.set(oursIdentity.userId, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.userID)")
        defaults.set(oursIdentity.alias, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.alias)")
        defaults.set(oursIdentity.hadPersistedDistinctId, forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.hadPersistedDistinctId)")
        defaults.synchronize()
    }
    
    static func loadIdentity(instanceName: String) -> OursPrivacyIdentity {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return OursPrivacyIdentity.init(distinctID: "",
//                                         peopleDistinctID: nil,
                                         anonymousId: nil,
                                         userId: nil,
                                         alias: nil,
                                         hadPersistedDistinctId: nil)
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        return OursPrivacyIdentity.init(
            distinctID: defaults.string(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.distinctID)") ?? "",
//            peopleDistinctID: defaults.string(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.peopleDistinctID)"),
            anonymousId: defaults.string(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.anonymousId)"),
            userId: defaults.string(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.userID)"),
            alias: defaults.string(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.alias)"),
            hadPersistedDistinctId: defaults.bool(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.hadPersistedDistinctId)"))
    }
    
    static func deleteMPUserDefaultsData(instanceName: String) {
        guard let defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName) else {
            return
        }
        let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.distinctID)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.peopleDistinctID)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.anonymousId)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.userID)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.alias)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.hadPersistedDistinctId)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.optOutStatus)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.timedEvents)")
        defaults.removeObject(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.superProperties)")
        defaults.synchronize()
    }
    
    // code for unarchiving from legacy archive files and migrating to SQLite / NSUserDefaults persistence
    func migrate() {
        if !needMigration() {
            return
        }
        let (eventsQueue,
//             peopleQueue,
//             groupsQueue,
             superProperties,
             timedEvents,
             distinctId,
             anonymousId,
             userId,
             alias,
             hadPersistedDistinctId,
//             peopleDistinctId,
//             peopleUnidentifiedQueue,
             optOutStatus) = unarchiveFromLegacy()
        saveEntities(eventsQueue, type: PersistenceType.events)
//        saveEntities(peopleUnidentifiedQueue, type: PersistenceType.people, flag: PersistenceConstant.unIdentifiedFlag)
//        saveEntities(peopleQueue, type: PersistenceType.people)
//        saveEntities(groupsQueue, type: PersistenceType.groups)
        OursPrivacyPersistence.saveSuperProperties(superProperties: superProperties, instanceName: instanceName)
        OursPrivacyPersistence.saveTimedEvents(timedEvents: timedEvents, instanceName: instanceName)
        OursPrivacyPersistence.saveIdentity(OursPrivacyIdentity.init(
            distinctID: distinctId,
//            peopleDistinctID: peopleDistinctId,
            anonymousId: anonymousId,
            userId: userId,
            alias: alias,
            hadPersistedDistinctId: hadPersistedDistinctId), instanceName: instanceName)
        if let optOutFlag = optOutStatus {
            OursPrivacyPersistence.saveOptOutStatusFlag(value: optOutFlag, instanceName: instanceName)
        }
        return
    }
    
    private func filePathWithType(_ type: String) -> String? {
        let filename = "oursprivacy-\(instanceName)-\(type)"
        let manager = FileManager.default
        
#if os(iOS)
        let url = manager.urls(for: .libraryDirectory, in: .userDomainMask).last
#else
        let url = manager.urls(for: .cachesDirectory, in: .userDomainMask).last
#endif // os(iOS)
        guard let urlUnwrapped = url?.appendingPathComponent(filename).path else {
            return nil
        }
        
        return urlUnwrapped
    }
    
    private func unarchiveFromLegacy() -> (eventsQueue: Queue,
//                                           peopleQueue: Queue,
//                                           groupsQueue: Queue,
                                           superProperties: InternalProperties,
                                           timedEvents: InternalProperties,
                                           distinctId: String,
                                           anonymousId: String?,
                                           userId: String?,
                                           alias: String?,
                                           hadPersistedDistinctId: Bool?,
//                                           peopleDistinctId: String?,
//                                           peopleUnidentifiedQueue: Queue,
                                           optOutStatus: Bool?) {
        let eventsQueue = unarchiveEvents()
//        let peopleQueue = unarchivePeople()
//        let groupsQueue = unarchiveGroups()
        let optOutStatus = unarchiveOptOutStatus()
        
        let (superProperties,
             timedEvents,
             distinctId,
             anonymousId,
             userId,
             alias,
             hadPersistedDistinctId
//             peopleDistinctId,
//             peopleUnidentifiedQueue
        ) = unarchiveProperties()
        
        if let eventsFile = filePathWithType(PersistenceType.events.rawValue) {
            removeArchivedFile(atPath: eventsFile)
        }
//        if let peopleFile = filePathWithType(PersistenceType.people.rawValue) {
//            removeArchivedFile(atPath: peopleFile)
//        }
//        if let groupsFile = filePathWithType(PersistenceType.groups.rawValue) {
//            removeArchivedFile(atPath: groupsFile)
//        }
        if let propsFile = filePathWithType("properties") {
            removeArchivedFile(atPath: propsFile)
        }
        if let optOutFile = filePathWithType("optOutStatus") {
            removeArchivedFile(atPath: optOutFile)
        }
        
        return (eventsQueue,
//                peopleQueue,
//                groupsQueue,
                superProperties,
                timedEvents,
                distinctId,
                anonymousId,
                userId,
                alias,
                hadPersistedDistinctId,
//                peopleDistinctId,
//                peopleUnidentifiedQueue,
                optOutStatus)
    }
    
    private func unarchiveWithFilePath(_ filePath: String) -> Any? {
        if #available(iOS 11.0, macOS 10.13, watchOS 4.0, tvOS 11.0, *) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)),
                  let unarchivedData = try? NSKeyedUnarchiver.unarchivedObject(ofClasses: OursPrivacyPersistence.archivedClasses, from: data) else {
                OursPrivacyLogger.info(message: "Unable to read file at path: \(filePath)")
                removeArchivedFile(atPath: filePath)
                return nil
            }
            return unarchivedData
        } else {
            guard let unarchivedData = NSKeyedUnarchiver.unarchiveObject(withFile: filePath) else {
                OursPrivacyLogger.info(message: "Unable to read file at path: \(filePath)")
                removeArchivedFile(atPath: filePath)
                return nil
            }
            return unarchivedData
        }
    }
    
    private func removeArchivedFile(atPath filePath: String) {
        do {
            try FileManager.default.removeItem(atPath: filePath)
        } catch let err {
            OursPrivacyLogger.info(message: "Unable to remove file at path: \(filePath), error: \(err)")
        }
    }
    
    private func unarchiveEvents() -> Queue {
        let data = unarchiveWithType(PersistenceType.events.rawValue)
        return data as? Queue ?? []
    }
    
//    private func unarchivePeople() -> Queue {
//        let data = unarchiveWithType(PersistenceType.people.rawValue)
//        return data as? Queue ?? []
//    }
//    
//    private func unarchiveGroups() -> Queue {
//        let data = unarchiveWithType(PersistenceType.groups.rawValue)
//        return data as? Queue ?? []
//    }
    
    private func unarchiveOptOutStatus() -> Bool? {
        return unarchiveWithType("optOutStatus") as? Bool
    }
    
    private func unarchiveProperties() -> (InternalProperties,
                                           InternalProperties,
                                           String,
                                           String?,
                                           String?,
                                           String?,
                                           Bool?
//                                           String?,
//                                           Queue
    ) {
        let properties = unarchiveWithType("properties") as? InternalProperties
        let superProperties =
        properties?["superProperties"] as? InternalProperties ?? InternalProperties()
        let timedEvents =
        properties?["timedEvents"] as? InternalProperties ?? InternalProperties()
        let distinctId =
        properties?["distinctId"] as? String ?? ""
        let anonymousId =
        properties?["anonymousId"] as? String ?? nil
        let userId =
        properties?["userId"] as? String ?? nil
        let alias =
        properties?["alias"] as? String ?? nil
        let hadPersistedDistinctId =
        properties?["hadPersistedDistinctId"] as? Bool ?? nil
//        let peopleDistinctId =
//        properties?["peopleDistinctId"] as? String ?? nil
//        let peopleUnidentifiedQueue =
//        properties?["peopleUnidentifiedQueue"] as? Queue ?? Queue()
        
        return (superProperties,
                timedEvents,
                distinctId,
                anonymousId,
                userId,
                alias,
                hadPersistedDistinctId)
//                peopleDistinctId,
//                peopleUnidentifiedQueue)
    }
    
    private func unarchiveWithType(_ type: String) -> Any? {
        let filePath = filePathWithType(type)
        guard let path = filePath else {
            OursPrivacyLogger.info(message: "bad file path, cant fetch file")
            return nil
        }
        
        guard let unarchivedData = unarchiveWithFilePath(path) else {
            OursPrivacyLogger.info(message: "can't unarchive file")
            return nil
        }
        
        return unarchivedData
    }
    
    private func needMigration() -> Bool {
        return fileExists(type: LegacyArchiveType.events.rawValue) ||
//        fileExists(type: LegacyArchiveType.people.rawValue) ||
//        fileExists(type: LegacyArchiveType.people.rawValue) ||
//        fileExists(type: LegacyArchiveType.groups.rawValue) ||
        fileExists(type: LegacyArchiveType.properties.rawValue) ||
        fileExists(type: LegacyArchiveType.optOutStatus.rawValue)
    }
    
    private func fileExists(type: String) -> Bool {
        return FileManager.default.fileExists(atPath: filePathWithType(type) ?? "")
    }
    
}
