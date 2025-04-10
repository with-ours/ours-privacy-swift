//
//  Groups.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Iris McLeary on 8/28/18.
//  Copyright © 2018 OursPrivacy. All rights reserved.
//

import Foundation

/// Access to the OursPrivacy Groups API, available through the getGroup function from
/// the main OursPrivacy instance.
open class Group {

    let apiToken: String
    let serialQueue: DispatchQueue
    let lock: ReadWriteLock
    let groupKey: String
    let groupID: OursPrivacyType
    weak var delegate: FlushDelegate?
    let metadata: SessionMetadata
    let oursprivacyPersistence: OursPrivacyPersistence
    weak var oursprivacyInstance: OursPrivacyInstance?

    init(apiToken: String,
         serialQueue: DispatchQueue,
         lock: ReadWriteLock,
         groupKey: String,
         groupID: OursPrivacyType,
         metadata: SessionMetadata,
         oursprivacyPersistence: OursPrivacyPersistence,
         oursprivacyInstance: OursPrivacyInstance) {
        self.apiToken = apiToken
        self.serialQueue = serialQueue
        self.lock = lock
        self.groupKey = groupKey
        self.groupID  = groupID
        self.metadata = metadata
        self.oursprivacyPersistence = oursprivacyPersistence
        self.oursprivacyInstance = oursprivacyInstance
    }

    func addGroupRecordToQueueWithAction(_ action: String, properties: InternalProperties) {
        if oursprivacyInstance?.hasOptedOutTracking() ?? false {
            return
        }
        let epochMilliseconds = round(Date().timeIntervalSince1970 * 1000)

        serialQueue.async {
            var r = InternalProperties()
            var p = InternalProperties()
            r["$token"] = self.apiToken
            r["$time"] = epochMilliseconds
            if action == "$unset" {
                // $unset takes an array of property names which is supplied to this method
                // in the properties parameter under the key "$properties"
                r[action] = properties["$properties"]
            } else {
                p += properties
                r[action] = p
            }
            self.metadata.toDict(isEvent: false).forEach { (k, v) in r[k] = v }

            r["$group_key"] = self.groupKey
            r["$group_id"] = self.groupID
            self.oursprivacyPersistence.saveEntity(r, type: .groups)
        }

        if OursPrivacyInstance.isiOSAppExtension() {
            delegate?.flush(performFullFlush: false, completion: nil)
        }
    }

    // MARK: - Group

    /**
     Sets properties on this group.

     Property keys must be String objects and the supported value types need to conform to OursPrivacyType.
     OursPrivacyType can be either String, Int, UInt, Double, Float, Bool, [OursPrivacyType], [String: OursPrivacyType], Date, URL, or NSNull.
     If the existing group record on the server already has a value for a given property, the old
     value is overwritten. Other existing properties will not be affected.

     - parameter properties: properties dictionary
     */
    open func set(properties: Properties) {
        assertPropertyTypes(properties)
        addGroupRecordToQueueWithAction("$set", properties: properties)
    }

    /**
     Convenience method for setting a single property in OursPrivacy Groups.

     Property keys must be String objects and the supported value types need to conform to OursPrivacyType.
     OursPrivacyType can be either String, Int, UInt, Double, Float, Bool, [OursPrivacyType], [String: OursPrivacyType], Date, URL, or NSNull.

     - parameter property: property name
     - parameter to:       property value
     */
    open func set(property: String, to: OursPrivacyType) {
        set(properties: [property: to])
    }

    /**
     Sets properties on the current OursPrivacy Group, but doesn't overwrite if
     there is an existing value.

     This method is identical to `set:` except it will only set
     properties that are not already set. It is particularly useful for collecting
     data about dates representing the first time something happened.

     - parameter properties: properties dictionary
     */
    open func setOnce(properties: Properties) {
        assertPropertyTypes(properties)
        addGroupRecordToQueueWithAction("$set_once", properties: properties)
    }

    /**
     Remove a property and its value from a group's profile in OursPrivacy Groups.

     For properties that don't exist there will be no effect.

     - parameter property: name of the property to unset
     */
    open func unset(property: String) {
        addGroupRecordToQueueWithAction("$unset", properties: ["$properties": [property]])
    }

    /**
     Removes list properties.

     Property keys must be String objects and the supported value types need to conform to OursPrivacyType.
     OursPrivacyType can be either String, Int, UInt, Double, Float, Bool, [OursPrivacyType], [String: OursPrivacyType], Date, URL, or NSNull.

     - parameter properties: mapping of list property names to values to remove
     */
    open func remove(key: String, value: OursPrivacyType) {
        let properties = [key: value]
        assertPropertyTypes(properties)
        addGroupRecordToQueueWithAction("$remove", properties: properties)
    }

    /**
     Union list properties.

     Property values must be array objects.

     - parameter properties: mapping of list property names to lists to union
     */
    open func union(key: String, values: [OursPrivacyType]) {
        let properties = [key: values]
        addGroupRecordToQueueWithAction("$union", properties: properties)
    }

    /**
     Delete group's record from OursPrivacy Groups.
     */
    open func deleteGroup() {
        addGroupRecordToQueueWithAction("$delete", properties: [:])
        oursprivacyInstance?.removeCachedGroup(groupKey: groupKey, groupID: groupID)
    }
}
