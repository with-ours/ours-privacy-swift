//
//  Track.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Yarden Eitan on 6/3/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//

import Foundation

func += <K, V> (left: inout [K: V], right: [K: V]) {
    for (k, v) in right {
        left.updateValue(v, forKey: k)
    }
}

class Track {
    let instanceName: String
    let apiToken: String
    let lock: ReadWriteLock
    let metadata: SessionMetadata
    let oursprivacyPersistence: OursPrivacyPersistence
    weak var oursprivacyInstance: OursPrivacyInstance?

    init(apiToken: String, instanceName: String, lock: ReadWriteLock, metadata: SessionMetadata,
         oursprivacyPersistence: OursPrivacyPersistence) {
        self.instanceName = instanceName
        self.apiToken = apiToken
        self.lock = lock
        self.metadata = metadata
        self.oursprivacyPersistence = oursprivacyPersistence
    }
    
    func track(event: String?,
               properties: Properties? = nil,
               timedEvents: InternalProperties,
               superProperties: InternalProperties,
               oursprivacyIdentity: OursPrivacyIdentity,
               epochInterval: Double) -> InternalProperties {
        var ev = "op_event"
        if let event = event {
            ev = event
        } else {
            OursPrivacyLogger.info(message: "oursprivacy track called with empty event parameter. using 'op_event'")
        }
        if !(oursprivacyInstance?.trackAutomaticEventsEnabled ?? false) && ev.hasPrefix("$ae_") {
            return timedEvents
        }
        assertPropertyTypes(properties)
        let epochMilliseconds = round(epochInterval * 1000)
        let eventStartTime = timedEvents[ev] as? Double
        var p = InternalProperties()
        AutomaticProperties.automaticPropertiesLock.read {
            p += AutomaticProperties.properties
        }
        p["token"] = apiToken
        p["time"] = epochMilliseconds
        var shadowTimedEvents = timedEvents
        if let eventStartTime = eventStartTime {
            shadowTimedEvents.removeValue(forKey: ev)
            p["$duration"] = Double(String(format: "%.3f", epochInterval - eventStartTime))
        }
        p["distinct_id"] = oursprivacyIdentity.distinctID
        if oursprivacyIdentity.anonymousId != nil {
            p["$device_id"] = oursprivacyIdentity.anonymousId
        }
        if oursprivacyIdentity.userId != nil {
            p["$user_id"] = oursprivacyIdentity.userId
        }
        if oursprivacyIdentity.hadPersistedDistinctId != nil {
            p["$had_persisted_distinct_id"] = oursprivacyIdentity.hadPersistedDistinctId
        }
        
        p += superProperties
        if let properties = properties {
            p += properties
        }

        var trackEvent: InternalProperties = ["event": ev, "token": apiToken, "userId": oursprivacyIdentity.userId as Any, "eventProperties": p]
        metadata.toDict().forEach { (k, v) in trackEvent[k] = v }
        
        self.oursprivacyPersistence.saveEntity(trackEvent, type: .events)
        OursPrivacyPersistence.saveTimedEvents(timedEvents: shadowTimedEvents, instanceName: instanceName)
        return shadowTimedEvents
    }

    func registerSuperProperties(_ properties: Properties,
                                 superProperties: InternalProperties) -> InternalProperties {
        if oursprivacyInstance?.hasOptedOutTracking() ?? false {
            return superProperties
        }

        var updatedSuperProperties = superProperties
        assertPropertyTypes(properties)
        updatedSuperProperties += properties
        
        return updatedSuperProperties
    }

    func registerSuperPropertiesOnce(_ properties: Properties,
                                     superProperties: InternalProperties,
                                     defaultValue: OursPrivacyType?) -> InternalProperties {
        if oursprivacyInstance?.hasOptedOutTracking() ?? false {
            return superProperties
        }

        var updatedSuperProperties = superProperties
        assertPropertyTypes(properties)
        _ = properties.map {
            let val = updatedSuperProperties[$0.key]
            if val == nil ||
                (defaultValue != nil && (val as? NSObject == defaultValue as? NSObject)) {
                updatedSuperProperties[$0.key] = $0.value
            }
        }
        
        return updatedSuperProperties
    }

    func unregisterSuperProperty(_ propertyName: String,
                                 superProperties: InternalProperties) -> InternalProperties {
        var updatedSuperProperties = superProperties
        updatedSuperProperties.removeValue(forKey: propertyName)
        return updatedSuperProperties
    }
        
    func clearSuperProperties(_ superProperties: InternalProperties) -> InternalProperties {
        var updatedSuperProperties = superProperties
        updatedSuperProperties.removeAll()
        return updatedSuperProperties
    }
    
    func updateSuperProperty(_ update: (_ superProperties: inout InternalProperties) -> Void, superProperties: inout InternalProperties) {
        update(&superProperties)
    }

    func time(event: String?, timedEvents: InternalProperties, startTime: Double) -> InternalProperties {
        if oursprivacyInstance?.hasOptedOutTracking() ?? false {
            return timedEvents
        }
        var updatedTimedEvents = timedEvents
        guard let event = event, !event.isEmpty else {
            OursPrivacyLogger.error(message: "oursprivacy cannot time an empty event")
            return updatedTimedEvents
        }
        updatedTimedEvents[event] = startTime
        return updatedTimedEvents
    }

    func clearTimedEvents(_ timedEvents: InternalProperties) -> InternalProperties {
        var updatedTimedEvents = timedEvents
        updatedTimedEvents.removeAll()
        return updatedTimedEvents
    }
    
    func clearTimedEvent(event: String?, timedEvents: InternalProperties) -> InternalProperties {
        var updatedTimedEvents = timedEvents
        guard let event = event, !event.isEmpty else {
            OursPrivacyLogger.error(message: "oursprivacy cannot clear an empty timed event")
            return updatedTimedEvents
        }
        updatedTimedEvents.removeValue(forKey: event)
        return updatedTimedEvents
    }
}
