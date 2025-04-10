//
//  OursPrivacy.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Yarden Eitan on 6/1/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//

import Foundation
#if !os(OSX)
import UIKit
#endif // os(OSX)

/// The primary class for integrating OursPrivacy with your app.
open class OursPrivacy {
    
#if !os(OSX) && !os(watchOS)
    /**
     Initializes an instance of the API with the given project token.
     
     Returns a new OursPrivacy instance API object. This allows you to create more than one instance
     of the API object, which is convenient if you'd like to send data to more than
     one OursPrivacy project from a single app.
     
     - parameter token:                     your project token
     - parameter trackAutomaticEvents:      Whether or not to collect common mobile events
     - parameter flushInterval:             Optional. Interval to run background flushing
     - parameter instanceName:              Optional. The name you want to uniquely identify the OursPrivacy Instance.
     It is useful when you want more than one OursPrivacy instance under the same project token.
     - parameter optOutTrackingByDefault:   Optional. Whether or not to be opted out from tracking by default
     - parameter useUniqueDistinctId:       Optional. whether or not to use the unique device identifier as the distinct_id
     - parameter superProperties:           Optional. Super properties dictionary to register during initialization
     - parameter serverURL:                 Optional. OursPrivacy cluster URL
     
     - important: If you have more than one OursPrivacy instance, it is beneficial to initialize
     the instances with an instanceName. Then they can be reached by calling getInstance with name.
     
     - returns: returns a oursprivacy instance if needed to keep throughout the project.
     You can always get the instance by calling getInstance(name)
     */
    @discardableResult
    open class func initialize(token apiToken: String,
                               trackAutomaticEvents: Bool,
                               flushInterval: Double = 60,
                               instanceName: String? = nil,
                               optOutTrackingByDefault: Bool = false,
                               useUniqueDistinctId: Bool = false,
                               superProperties: Properties? = nil,
                               serverURL: String? = nil) -> OursPrivacyInstance {
        return OursPrivacyManager.sharedInstance.initialize(token: apiToken,
                                                         flushInterval: flushInterval,
                                                         instanceName: ((instanceName != nil) ? instanceName! : apiToken),
                                                         trackAutomaticEvents: trackAutomaticEvents,
                                                         optOutTrackingByDefault: optOutTrackingByDefault,
                                                         useUniqueDistinctId: useUniqueDistinctId,
                                                         superProperties: superProperties,
                                                         serverURL: serverURL)
    }
    
    /**
     Initializes an instance of the API with the given project token.
     
     Returns a new OursPrivacy instance API object. This allows you to create more than one instance
     of the API object, which is convenient if you'd like to send data to more than
     one OursPrivacy project from a single app.
     
     - parameter token:                     your project token
     - parameter trackAutomaticEvents:      Whether or not to collect common mobile events
     - parameter flushInterval:             Optional. Interval to run background flushing
     - parameter instanceName:              Optional. The name you want to uniquely identify the OursPrivacy Instance.
     It is useful when you want more than one OursPrivacy instance under the same project token.
     - parameter optOutTrackingByDefault:   Optional. Whether or not to be opted out from tracking by default
     - parameter useUniqueDistinctId:       Optional. whether or not to use the unique device identifier as the distinct_id
     - parameter superProperties:           Optional. Super properties dictionary to register during initialization
     - parameter proxyServerConfig:         Optional. Setup for proxy server.
     
     - important: If you have more than one OursPrivacy instance, it is beneficial to initialize
     the instances with an instanceName. Then they can be reached by calling getInstance with name.
     
     - returns: returns a oursprivacy instance if needed to keep throughout the project.
     You can always get the instance by calling getInstance(name)
     */
    
    @discardableResult
    open class func initialize(token apiToken: String,
                               trackAutomaticEvents: Bool,
                               flushInterval: Double = 60,
                               instanceName: String? = nil,
                               optOutTrackingByDefault: Bool = false,
                               useUniqueDistinctId: Bool = false,
                               superProperties: Properties? = nil,
                               proxyServerConfig: ProxyServerConfig) -> OursPrivacyInstance {
        return OursPrivacyManager.sharedInstance.initialize(token: apiToken,
                                                         flushInterval: flushInterval,
                                                         instanceName: ((instanceName != nil) ? instanceName! : apiToken),
                                                         trackAutomaticEvents: trackAutomaticEvents,
                                                         optOutTrackingByDefault: optOutTrackingByDefault,
                                                         useUniqueDistinctId: useUniqueDistinctId,
                                                         superProperties: superProperties,
                                                         proxyServerConfig: proxyServerConfig)
    }
#else
    /**
     Initializes an instance of the API with the given project token (MAC OS ONLY).
     
     Returns a new OursPrivacy instance API object. This allows you to create more than one instance
     of the API object, which is convenient if you'd like to send data to more than
     one OursPrivacy project from a single app.
     
     - parameter token:                     your project token
     - parameter flushInterval:             Optional. Interval to run background flushing
     - parameter instanceName:              Optional. The name you want to uniquely identify the OursPrivacy Instance.
     It is useful when you want more than one OursPrivacy instance under the same project token.
     - parameter optOutTrackingByDefault:   Optional. Whether or not to be opted out from tracking by default
     - parameter useUniqueDistinctId:       Optional. whether or not to use the unique device identifier as the distinct_id
     - parameter superProperties:           Optional. Super properties dictionary to register during initialization
     - parameter serverURL:                 Optional. OursPrivacy cluster URL
     
     - important: If you have more than one OursPrivacy instance, it is beneficial to initialize
     the instances with an instanceName. Then they can be reached by calling getInstance with name.
     
     - returns: returns a oursprivacy instance if needed to keep throughout the project.
     You can always get the instance by calling getInstance(name)
     */
    
    @discardableResult
    open class func initialize(token apiToken: String,
                               flushInterval: Double = 60,
                               instanceName: String? = nil,
                               optOutTrackingByDefault: Bool = false,
                               useUniqueDistinctId: Bool = false,
                               superProperties: Properties? = nil,
                               serverURL: String? = nil) -> OursPrivacyInstance {
        return OursPrivacyManager.sharedInstance.initialize(token: apiToken,
                                                         flushInterval: flushInterval,
                                                         instanceName: ((instanceName != nil) ? instanceName! : apiToken),
                                                         trackAutomaticEvents: false,
                                                         optOutTrackingByDefault: optOutTrackingByDefault,
                                                         useUniqueDistinctId: useUniqueDistinctId,
                                                         superProperties: superProperties,
                                                         serverURL: serverURL)
    }
    
    /**
     Initializes an instance of the API with the given project token (MAC OS ONLY).
     
     Returns a new OursPrivacy instance API object. This allows you to create more than one instance
     of the API object, which is convenient if you'd like to send data to more than
     one OursPrivacy project from a single app.
     
     - parameter token:                     your project token
     - parameter flushInterval:             Optional. Interval to run background flushing
     - parameter instanceName:              Optional. The name you want to uniquely identify the OursPrivacy Instance.
     It is useful when you want more than one OursPrivacy instance under the same project token.
     - parameter optOutTrackingByDefault:   Optional. Whether or not to be opted out from tracking by default
     - parameter useUniqueDistinctId:       Optional. whether or not to use the unique device identifier as the distinct_id
     - parameter superProperties:           Optional. Super properties dictionary to register during initialization
     - parameter proxyServerConfig:         Optional. Setup for proxy server.
     
     - important: If you have more than one OursPrivacy instance, it is beneficial to initialize
     the instances with an instanceName. Then they can be reached by calling getInstance with name.
     
     - returns: returns a oursprivacy instance if needed to keep throughout the project.
     You can always get the instance by calling getInstance(name)
     */
    
    @discardableResult
    open class func initialize(token apiToken: String,
                               flushInterval: Double = 60,
                               instanceName: String? = nil,
                               optOutTrackingByDefault: Bool = false,
                               useUniqueDistinctId: Bool = false,
                               superProperties: Properties? = nil,
                               proxyServerConfig: ProxyServerConfig) -> OursPrivacyInstance {
        return OursPrivacyManager.sharedInstance.initialize(token: apiToken,
                                                         flushInterval: flushInterval,
                                                         instanceName: ((instanceName != nil) ? instanceName! : apiToken),
                                                         trackAutomaticEvents: false,
                                                         optOutTrackingByDefault: optOutTrackingByDefault,
                                                         useUniqueDistinctId: useUniqueDistinctId,
                                                         superProperties: superProperties,
                                                         proxyServerConfig: proxyServerConfig)
    }
#endif // os(OSX)
    
    /**
     Gets the oursprivacy instance with the given name
     
     - parameter name: the instance name
     
     - returns: returns the oursprivacy instance
     */
    open class func getInstance(name: String) -> OursPrivacyInstance? {
        return OursPrivacyManager.sharedInstance.getInstance(name: name)
    }
    
    /**
     Returns the main instance that was initialized.
     
     If not specified explicitly, the main instance is always the last instance added
     
     - returns: returns the main OursPrivacy instance
     */
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
    
    /**
     Sets the main instance based on the instance name
     
     - parameter name: the instance name
     */
    open class func setMainInstance(name: String) {
        OursPrivacyManager.sharedInstance.setMainInstance(name: name)
    }
    
    /**
     Removes an unneeded OursPrivacy instance based on its name
     
     - parameter name: the instance name
     */
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
                    useUniqueDistinctId: Bool = false,
                    superProperties: Properties? = nil,
                    serverURL: String? = nil
    ) -> OursPrivacyInstance {
        return dequeueInstance(instanceName: instanceName) {
            return OursPrivacyInstance(apiToken: apiToken,
                                    flushInterval: flushInterval,
                                    name: instanceName,
                                    trackAutomaticEvents: trackAutomaticEvents,
                                    optOutTrackingByDefault: optOutTrackingByDefault,
                                    useUniqueDistinctId: useUniqueDistinctId,
                                    superProperties: superProperties,
                                    serverURL: serverURL)
        }
    }
    
    func initialize(token apiToken: String,
                    flushInterval: Double,
                    instanceName: String,
                    trackAutomaticEvents: Bool,
                    optOutTrackingByDefault: Bool = false,
                    useUniqueDistinctId: Bool = false,
                    superProperties: Properties? = nil,
                    proxyServerConfig: ProxyServerConfig
    ) -> OursPrivacyInstance {
        return dequeueInstance(instanceName: instanceName) {
            return OursPrivacyInstance(apiToken: apiToken,
                                    flushInterval: flushInterval,
                                    name: instanceName,
                                    trackAutomaticEvents: trackAutomaticEvents,
                                    optOutTrackingByDefault: optOutTrackingByDefault,
                                    useUniqueDistinctId: useUniqueDistinctId,
                                    superProperties: superProperties,
                                    proxyServerConfig: proxyServerConfig)
        }
    }
    
    private func dequeueInstance(instanceName: String, instanceCreation: () -> OursPrivacyInstance) -> OursPrivacyInstance {
        instanceQueue.sync {
            var instance: OursPrivacyInstance?
            if let instance = instances[instanceName] {
                mainInstance = instance
                return
            }
            
            instance = instanceCreation()
            readWriteLock.write {
                instances[instanceName] = instance!
                mainInstance = instance!
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
        if instance == nil {
            return
        }
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

