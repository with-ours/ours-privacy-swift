//
//  OursPrivacy.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//

import Foundation
#if !os(OSX)
import UIKit
#endif

/// Top-level entry point — call `OursPrivacy.initialize(token:...)` once at app
/// launch, then access the shared instance via `OursPrivacy.mainInstance()`.
open class OursPrivacy {

#if !os(OSX) && !os(watchOS)
    @discardableResult
    open class func initialize(token apiToken: String,
                               trackAutomaticEvents: Bool,
                               flushInterval: Double = 60,
                               instanceName: String? = nil,
                               optOutTrackingByDefault: Bool = false,
                               serverURL: String? = nil) -> OursPrivacyInstance {
        return OursPrivacyManager.sharedInstance.initialize(
            token: apiToken,
            flushInterval: flushInterval,
            instanceName: instanceName ?? apiToken,
            trackAutomaticEvents: trackAutomaticEvents,
            optOutTrackingByDefault: optOutTrackingByDefault,
            serverURL: serverURL)
    }

    @discardableResult
    open class func initialize(token apiToken: String,
                               trackAutomaticEvents: Bool,
                               flushInterval: Double = 60,
                               instanceName: String? = nil,
                               optOutTrackingByDefault: Bool = false,
                               proxyServerConfig: ProxyServerConfig) -> OursPrivacyInstance {
        return OursPrivacyManager.sharedInstance.initialize(
            token: apiToken,
            flushInterval: flushInterval,
            instanceName: instanceName ?? apiToken,
            trackAutomaticEvents: trackAutomaticEvents,
            optOutTrackingByDefault: optOutTrackingByDefault,
            proxyServerConfig: proxyServerConfig)
    }
#else
    @discardableResult
    open class func initialize(token apiToken: String,
                               flushInterval: Double = 60,
                               instanceName: String? = nil,
                               optOutTrackingByDefault: Bool = false,
                               serverURL: String? = nil) -> OursPrivacyInstance {
        return OursPrivacyManager.sharedInstance.initialize(
            token: apiToken,
            flushInterval: flushInterval,
            instanceName: instanceName ?? apiToken,
            trackAutomaticEvents: false,
            optOutTrackingByDefault: optOutTrackingByDefault,
            serverURL: serverURL)
    }

    @discardableResult
    open class func initialize(token apiToken: String,
                               flushInterval: Double = 60,
                               instanceName: String? = nil,
                               optOutTrackingByDefault: Bool = false,
                               proxyServerConfig: ProxyServerConfig) -> OursPrivacyInstance {
        return OursPrivacyManager.sharedInstance.initialize(
            token: apiToken,
            flushInterval: flushInterval,
            instanceName: instanceName ?? apiToken,
            trackAutomaticEvents: false,
            optOutTrackingByDefault: optOutTrackingByDefault,
            proxyServerConfig: proxyServerConfig)
    }
#endif

    open class func getInstance(name: String) -> OursPrivacyInstance? {
        return OursPrivacyManager.sharedInstance.getInstance(name: name)
    }

    open class func mainInstance() -> OursPrivacyInstance {
        if let instance = OursPrivacyManager.sharedInstance.getMainInstance() {
            return instance
        } else {
#if !targetEnvironment(simulator)
            assert(false, "You have to call initialize(token:trackAutomaticEvents:) before calling the main instance, " +
                   "or define a new main instance if removing the main one")
#endif
#if !os(OSX) && !os(watchOS)
            return OursPrivacy.initialize(token: "", trackAutomaticEvents: true)
#else
            return OursPrivacy.initialize(token: "")
#endif
        }
    }

    open class func setMainInstance(name: String) {
        OursPrivacyManager.sharedInstance.setMainInstance(name: name)
    }

    open class func removeInstance(name: String) {
        OursPrivacyManager.sharedInstance.removeInstance(name: name)
    }
}

final class OursPrivacyManager {

    static let sharedInstance = OursPrivacyManager()
    private var instances: [String: OursPrivacyInstance]
    private var mainInstance: OursPrivacyInstance?
    private let readWriteLock: ReadWriteLock
    private let instanceQueue: DispatchQueue

    init() {
        instances = [String: OursPrivacyInstance]()
        OursPrivacyLogger.addLogging(PrintLogging())
        readWriteLock = ReadWriteLock(label: "com.oursprivacy.instance.manager.lock")
        instanceQueue = DispatchQueue(label: "com.oursprivacy.instance.manager.instance", qos: .utility, autoreleaseFrequency: .workItem)
    }

    func initialize(token apiToken: String,
                    flushInterval: Double,
                    instanceName: String,
                    trackAutomaticEvents: Bool,
                    optOutTrackingByDefault: Bool = false,
                    serverURL: String? = nil) -> OursPrivacyInstance {
        return dequeueInstance(instanceName: instanceName) {
            OursPrivacyInstance(apiToken: apiToken,
                                flushInterval: flushInterval,
                                name: instanceName,
                                trackAutomaticEvents: trackAutomaticEvents,
                                optOutTrackingByDefault: optOutTrackingByDefault,
                                serverURL: serverURL)
        }
    }

    func initialize(token apiToken: String,
                    flushInterval: Double,
                    instanceName: String,
                    trackAutomaticEvents: Bool,
                    optOutTrackingByDefault: Bool = false,
                    proxyServerConfig: ProxyServerConfig) -> OursPrivacyInstance {
        return dequeueInstance(instanceName: instanceName) {
            OursPrivacyInstance(apiToken: apiToken,
                                flushInterval: flushInterval,
                                name: instanceName,
                                trackAutomaticEvents: trackAutomaticEvents,
                                optOutTrackingByDefault: optOutTrackingByDefault,
                                proxyServerConfig: proxyServerConfig)
        }
    }

    private func dequeueInstance(instanceName: String, instanceCreation: () -> OursPrivacyInstance) -> OursPrivacyInstance {
        instanceQueue.sync {
            if let instance = instances[instanceName] {
                mainInstance = instance
                return
            }
            let instance = instanceCreation()
            readWriteLock.write {
                instances[instanceName] = instance
                mainInstance = instance
            }
        }
        return mainInstance!
    }

    func getInstance(name instanceName: String) -> OursPrivacyInstance? {
        var instance: OursPrivacyInstance?
        readWriteLock.read {
            instance = instances[instanceName]
        }
        if instance == nil {
            OursPrivacyLogger.warn(message: "no such instance: \(instanceName)")
            return nil
        }
        return instance
    }

    func getMainInstance() -> OursPrivacyInstance? {
        return mainInstance
    }

    func getAllInstances() -> [OursPrivacyInstance]? {
        var allInstances: [OursPrivacyInstance]?
        readWriteLock.read {
            allInstances = Array(instances.values)
        }
        return allInstances
    }

    func setMainInstance(name instanceName: String) {
        var instance: OursPrivacyInstance?
        readWriteLock.read {
            instance = instances[instanceName]
        }
        if instance == nil { return }
        mainInstance = instance
    }

    func removeInstance(name instanceName: String) {
        readWriteLock.write {
            if instances[instanceName] === mainInstance {
                mainInstance = nil
            }
            instances[instanceName] = nil
        }
    }
}
