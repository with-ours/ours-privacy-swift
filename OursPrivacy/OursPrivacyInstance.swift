//
//  OursPrivacyInstance.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//
//  Created by Yarden Eitan on 6/2/16.
//  Copyright © 2016 Mixpanel. All rights reserved.
//

import Foundation
#if !os(OSX)
import UIKit
#else
import Cocoa
#endif // os(OSX)
#if os(iOS)
import SystemConfiguration
#endif

#if os(iOS)
import CoreTelephony
#endif // os(iOS)

private let devicePrefix = "$device:"

/**
 *  Delegate protocol for updating the Proxy Server API's network behavior.
 */
public protocol OursPrivacyProxyServerDelegate: AnyObject {
    /**
     Asks the delegate to return API resource items like query params & headers for proxy Server.
     
     - parameter oursprivacy: The oursprivacy instance
     
     - returns: return ServerProxyResource to give custom headers and query params.
     */
    func oursprivacyResourceForProxyServer(_ name: String) -> ServerProxyResource?
}

/**
 *  Delegate protocol for controlling the OursPrivacy API's network behavior.
 */
public protocol OursPrivacyDelegate: AnyObject {
    /**
     Asks the delegate if data should be uploaded to the server.
     
     - parameter oursprivacy: The oursprivacy instance
     
     - returns: return true to upload now or false to defer until later
     */
    func oursprivacyWillFlush(_ oursprivacy: OursPrivacyInstance) -> Bool
}

public typealias Properties = [String: OursPrivacyType]
typealias InternalProperties = [String: Any]
typealias Queue = [InternalProperties]

protocol AppLifecycle {
    func applicationDidBecomeActive()
    func applicationWillResignActive()
}

public struct ProxyServerConfig {
    public init?(serverUrl: String, delegate: OursPrivacyProxyServerDelegate? = nil) {
        /// check if proxy server is not same as default oursprivacy API
        /// if same, then fail the initializer
        /// this is to avoid case where client might inadvertently use headers intended for the proxy server
        /// on OursPrivacy's default server, leading to unexpected behavior.
        guard serverUrl != BasePath.DefaultAPIEndpoint else { return nil }
        self.serverUrl = serverUrl
        self.delegate = delegate
    }
    
    let serverUrl: String
    let delegate: OursPrivacyProxyServerDelegate?
}

/// The class that represents the OursPrivacy Instance
open class OursPrivacyInstance: CustomDebugStringConvertible, FlushDelegate, AEDelegate {
    
    /// apiToken string that identifies the project to track data to
    open var apiToken = ""
    
    /// The a OursPrivacyDelegate object that gives control over OursPrivacy network activity.
    open weak var delegate: OursPrivacyDelegate?
    
    /// distinctId string that uniquely identifies the current user.
    open var distinctId = ""
    
    /// anonymousId string that uniquely identifies the device.
    open var anonymousId: String?
    
    /// userId string that identify is called with.
    open var userId: String?
    
    /// hadPersistedDistinctId is a boolean value which specifies that the stored distinct_id
    /// already exists in persistence
    open var hadPersistedDistinctId: Bool?
    
    /// alias string that uniquely identifies the current user.
    open var alias: String?
    
    /// Accessor to the OursPrivacy People API object.
//    open var people: People!
    
    let oursprivacyPersistence: OursPrivacyPersistence
    
    /// Accessor to the OursPrivacy People API object.
//    var groups: [String: Group] = [:]
    
    /// Controls whether to show spinning network activity indicator when flushing
    /// data to the OursPrivacy servers. Defaults to true.
    open var showNetworkActivityIndicator = true
    
    /// This allows enabling or disabling collecting common mobile events,
    open var trackAutomaticEventsEnabled: Bool
    
    /// Flush timer's interval.
    /// Setting a flush interval of 0 will turn off the flush timer and you need to call the flush() API manually
    /// to upload queued data to the OursPrivacy server.
    open var flushInterval: Double {
        get {
            return flushInstance.flushInterval
        }
        set {
            flushInstance.flushInterval = newValue
        }
    }
    
    /// Control whether the library should flush data to OursPrivacy when the app
    /// enters the background. Defaults to true.
    open var flushOnBackground: Bool {
        get {
            return flushInstance.flushOnBackground
        }
        set {
            flushInstance.flushOnBackground = newValue
        }
    }
    
    /// Controls whether to automatically send the client IP Address as part of
    /// event tracking. With an IP address, the OursPrivacy Dashboard will show you the users' city.
    /// Defaults to true.
    open var useIPAddressForGeoLocation: Bool {
        get {
            return flushInstance.useIPAddressForGeoLocation
        }
        set {
            flushInstance.useIPAddressForGeoLocation = newValue
        }
    }
    
    /// The `flushBatchSize` property determines the number of events sent in a single network request to the OursPrivacy server.
    /// By configuring this value, you can optimize network usage and manage the frequency of communication between the client
    /// and the server. The maximum size is 50; any value over 50 will default to 50.
    open var flushBatchSize: Int {
        get {
            return flushInstance.flushBatchSize
        }
        set {
            flushInstance.flushBatchSize = min(newValue, APIConstants.maxBatchSize)
        }
    }
    
    
    /// The base URL used for OursPrivacy API requests.
    /// Useful if you need to proxy OursPrivacy requests. Defaults to
    /// https://api.oursprivacy.com/api/v1
    open var serverURL = BasePath.DefaultAPIEndpoint {
        didSet {
            flushInstance.serverURL = serverURL
        }
    }
    
    /// The a OursPrivacyProxyServerDelegate object that gives config control over Proxy Server's network activity.
    open weak var proxyServerDelegate: OursPrivacyProxyServerDelegate? = nil
    
    
    open var debugDescription: String {
        return "OursPrivacy(\n"
        + "    Token: \(apiToken),\n"
        + "    Distinct Id: \(distinctId)\n"
        + ")"
    }
    
    /// This allows enabling or disabling of all OursPrivacy logs at run time.
    /// - Note: All logging is disabled by default. Usually, this is only required
    ///         if you are running in to issues with the SDK and you need support.
    open var loggingEnabled: Bool = false {
        didSet {
            if loggingEnabled {
                OursPrivacyLogger.enableLevel(.debug)
                OursPrivacyLogger.enableLevel(.info)
                OursPrivacyLogger.enableLevel(.warning)
                OursPrivacyLogger.enableLevel(.error)
                OursPrivacyLogger.info(message: "OursPrivacyLogging Enabled")
            } else {
                OursPrivacyLogger.info(message: "OursPrivacyLogging Disabled")
                OursPrivacyLogger.disableLevel(.debug)
                OursPrivacyLogger.disableLevel(.info)
                OursPrivacyLogger.disableLevel(.warning)
                OursPrivacyLogger.disableLevel(.error)
            }
#if DEBUG
            var trackProps: Properties = ["OursPrivacyLogging Enabled": loggingEnabled]
            if (superProperties["mp_lib"] != nil) {
                trackProps["mp_lib"] = self.superProperties["mp_lib"] as! String
            }
            if (superProperties["$lib_version"] != nil) {
                trackProps["$lib_version"] = self.superProperties["$lib_version"] as! String
            }
#endif
        }
    }
    
    /// A unique identifier for this OursPrivacyInstance
    public let name: String
    
    /// The minimum session duration (ms) that is tracked in automatic events.
    /// The default value is 10000 (10 seconds).
#if os(iOS) || os(tvOS) || os(visionOS)
    open var minimumSessionDuration: UInt64 {
        get {
            return automaticEvents.minimumSessionDuration
        }
        set {
            automaticEvents.minimumSessionDuration = newValue
        }
    }
    
    /// The maximum session duration (ms) that is tracked in automatic events.
    /// The default value is UINT64_MAX (no maximum session duration).
    open var maximumSessionDuration: UInt64 {
        get {
            return automaticEvents.maximumSessionDuration
        }
        set {
            automaticEvents.maximumSessionDuration = newValue
        }
    }
#endif
    var superProperties = InternalProperties()
    var trackingQueue: DispatchQueue
    var networkQueue: DispatchQueue
    var optOutStatus: Bool?
    var useUniqueDistinctId: Bool
    var timedEvents = InternalProperties()
    
    let readWriteLock: ReadWriteLock
#if os(iOS) && !targetEnvironment(macCatalyst)
    static let reachability = SCNetworkReachabilityCreateWithName(nil, "api.oursprivacy.com")
    static let telephonyInfo = CTTelephonyNetworkInfo()
#endif
#if !os(OSX) && !os(watchOS)
    var taskId = UIBackgroundTaskIdentifier.invalid
#endif // os(OSX)
    let sessionMetadata: SessionMetadata
    let flushInstance: Flush
    let trackInstance: Track
#if os(iOS) || os(tvOS) || os(visionOS)
    let automaticEvents = AutomaticEvents()
#endif
    private let registerSuperPropertiesNotificationName = Notification.Name("com.oursprivacy.properties.register")
    private let unregisterSuperPropertiesNotificationName = Notification.Name("com.oursprivacy.properties.unregister")
    
    convenience init(
        apiToken: String?,
        flushInterval: Double,
        name: String,
        trackAutomaticEvents: Bool,
        optOutTrackingByDefault: Bool = false,
        useUniqueDistinctId: Bool = false,
        superProperties: Properties? = nil,
        proxyServerConfig: ProxyServerConfig
    ) {
        self.init(apiToken: apiToken,
                  flushInterval: flushInterval,
                  name: name,
                  trackAutomaticEvents: trackAutomaticEvents,
                  optOutTrackingByDefault: optOutTrackingByDefault,
                  useUniqueDistinctId: useUniqueDistinctId,
                  superProperties: superProperties,
                  serverURL: proxyServerConfig.serverUrl,
                  proxyServerDelegate: proxyServerConfig.delegate)
    }
    
    convenience init(
        apiToken: String?,
        flushInterval: Double,
        name: String,
        trackAutomaticEvents: Bool,
        optOutTrackingByDefault: Bool = false,
        useUniqueDistinctId: Bool = false,
        superProperties: Properties? = nil,
        serverURL: String? = nil
    ) {
        self.init(apiToken: apiToken,
                  flushInterval: flushInterval,
                  name: name,
                  trackAutomaticEvents: trackAutomaticEvents,
                  optOutTrackingByDefault: optOutTrackingByDefault,
                  useUniqueDistinctId: useUniqueDistinctId,
                  superProperties: superProperties,
                  serverURL: serverURL,
                  proxyServerDelegate: nil)
    }
    
    
    private init(
        apiToken: String?,
        flushInterval: Double,
        name: String,
        trackAutomaticEvents: Bool,
        optOutTrackingByDefault: Bool = false,
        useUniqueDistinctId: Bool = false,
        superProperties: Properties? = nil,
        serverURL: String? = nil,
        proxyServerDelegate: OursPrivacyProxyServerDelegate? = nil
    ) {
        if let apiToken = apiToken, !apiToken.isEmpty {
            self.apiToken = apiToken
        }
        trackAutomaticEventsEnabled = trackAutomaticEvents
        if let serverURL = serverURL {
            self.serverURL = serverURL
        }
        self.proxyServerDelegate = proxyServerDelegate
        let label = "com.oursprivacy.\(self.apiToken)"
        trackingQueue = DispatchQueue(label: "\(label).tracking)", qos: .utility, autoreleaseFrequency: .workItem)
        networkQueue = DispatchQueue(label: "\(label).network)", qos: .utility, autoreleaseFrequency: .workItem)
        self.name = name
        
        oursprivacyPersistence = OursPrivacyPersistence.init(instanceName: name)
        oursprivacyPersistence.migrate()
        self.useUniqueDistinctId = useUniqueDistinctId
        
        readWriteLock = ReadWriteLock(label: "com.oursprivacy.globallock")
        flushInstance = Flush(serverURL: self.serverURL)
        sessionMetadata = SessionMetadata(trackingQueue: trackingQueue)
        trackInstance = Track(apiToken: self.apiToken,
                              instanceName: self.name,
                              lock: self.readWriteLock,
                              metadata: sessionMetadata, oursprivacyPersistence: oursprivacyPersistence)
        trackInstance.oursprivacyInstance = self
#if os(iOS) && !targetEnvironment(macCatalyst)
        if let reachability = OursPrivacyInstance.reachability {
            var context = SCNetworkReachabilityContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
            func reachabilityCallback(reachability: SCNetworkReachability,
                                      flags: SCNetworkReachabilityFlags,
                                      unsafePointer: UnsafeMutableRawPointer?) {
                let wifi = flags.contains(SCNetworkReachabilityFlags.reachable) && !flags.contains(SCNetworkReachabilityFlags.isWWAN)
                AutomaticProperties.automaticPropertiesLock.write {
                    AutomaticProperties.properties["$wifi"] = wifi
                }
                OursPrivacyLogger.info(message: "reachability changed, wifi=\(wifi)")
            }
            if SCNetworkReachabilitySetCallback(reachability, reachabilityCallback, &context) {
                if !SCNetworkReachabilitySetDispatchQueue(reachability, trackingQueue) {
                    // cleanup callback if setting dispatch queue failed
                    SCNetworkReachabilitySetCallback(reachability, nil, nil)
                }
            }
        }
#endif
        flushInstance.delegate = self
        distinctId = devicePrefix + defaultDeviceId()
//        people = People(apiToken: self.apiToken,
//                        serialQueue: trackingQueue,
//                        lock: self.readWriteLock,
//                        metadata: sessionMetadata, oursprivacyPersistence: oursprivacyPersistence)
//        people.oursprivacyInstance = self
//        people.delegate = self
        flushInstance.flushInterval = flushInterval
#if !os(watchOS)
        setupListeners()
#endif
        unarchive()
        
        // check whether we should opt out by default
        // note: we don't override opt out persistence here since opt-out default state is often
        // used as an initial state while GDPR information is being collected
        if optOutTrackingByDefault && (hasOptedOutTracking() || optOutStatus == nil) {
            optOutTracking()
        }
        
        if let superProperties = superProperties {
            registerSuperProperties(superProperties)
        }
        
#if os(iOS) || os(tvOS) || os(visionOS)
        if !OursPrivacyInstance.isiOSAppExtension() && trackAutomaticEvents {
            automaticEvents.delegate = self
            automaticEvents.initializeEvents(instanceName: self.name)
        }
#endif
    }
    
#if !os(OSX) && !os(watchOS)
    private func setupListeners() {
        let notificationCenter = NotificationCenter.default
#if os(iOS) && !targetEnvironment(macCatalyst)
        setCurrentRadio()
        // Temporarily remove the ability to monitor the radio change due to a crash issue might relate to the api from Apple
        // https://openradar.appspot.com/46873673
        //    notificationCenter.addObserver(self,
        //                                   selector: #selector(setCurrentRadio),
        //                                   name: .CTRadioAccessTechnologyDidChange,
        //                                   object: nil)
#endif // os(iOS)
        if !OursPrivacyInstance.isiOSAppExtension() {
            notificationCenter.addObserver(self,
                                           selector: #selector(applicationWillResignActive(_:)),
                                           name: UIApplication.willResignActiveNotification,
                                           object: nil)
            notificationCenter.addObserver(self,
                                           selector: #selector(applicationDidBecomeActive(_:)),
                                           name: UIApplication.didBecomeActiveNotification,
                                           object: nil)
            notificationCenter.addObserver(self,
                                           selector: #selector(applicationDidEnterBackground(_:)),
                                           name: UIApplication.didEnterBackgroundNotification,
                                           object: nil)
            notificationCenter.addObserver(self,
                                           selector: #selector(applicationWillEnterForeground(_:)),
                                           name: UIApplication.willEnterForegroundNotification,
                                           object: nil)
            notificationCenter.addObserver(
                self,
                selector: #selector(handleSuperPropertiesRegistrationNotification(_:)),
                name: registerSuperPropertiesNotificationName,
                object: nil
            )
            notificationCenter.addObserver(
                self,
                selector: #selector(handleSuperPropertiesRegistrationNotification(_:)),
                name: unregisterSuperPropertiesNotificationName,
                object: nil
            )
        }
    }
#elseif os(OSX)
    private func setupListeners() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self,
                                       selector: #selector(applicationWillResignActive(_:)),
                                       name: NSApplication.willResignActiveNotification,
                                       object: nil)
        notificationCenter.addObserver(self,
                                       selector: #selector(applicationDidBecomeActive(_:)),
                                       name: NSApplication.didBecomeActiveNotification,
                                       object: nil)
    }
#endif // os(OSX)
    
    deinit {
        NotificationCenter.default.removeObserver(self)
#if os(iOS) && !os(watchOS) && !targetEnvironment(macCatalyst)
        if let reachability = OursPrivacyInstance.reachability {
            if !SCNetworkReachabilitySetCallback(reachability, nil, nil) {
                OursPrivacyLogger.error(message: "\(self) error unsetting reachability callback")
            }
            if !SCNetworkReachabilitySetDispatchQueue(reachability, nil) {
                OursPrivacyLogger.error(message: "\(self) error unsetting reachability dispatch queue")
            }
        }
#endif
    }
    
    static func isiOSAppExtension() -> Bool {
        return Bundle.main.bundlePath.hasSuffix(".appex")
    }
    
#if !os(OSX) && !os(watchOS)
    static func sharedUIApplication() -> UIApplication? {
        guard let sharedApplication =
                UIApplication.perform(NSSelectorFromString("sharedApplication"))?.takeUnretainedValue() as? UIApplication else {
            return nil
        }
        return sharedApplication
    }
#endif // !os(OSX)
    
    @objc private func applicationDidBecomeActive(_ notification: Notification) {
        flushInstance.applicationDidBecomeActive()
    }
    
    @objc private func applicationWillResignActive(_ notification: Notification) {
        flushInstance.applicationWillResignActive()
#if os(OSX)
        if flushOnBackground {
            flush()
        }
        
#endif
    }
    
#if !os(OSX) && !os(watchOS)
    @objc private func applicationDidEnterBackground(_ notification: Notification) {
        guard let sharedApplication = OursPrivacyInstance.sharedUIApplication() else {
            return
        }
        
        if hasOptedOutTracking() {
            return
        }
        
        let completionHandler: () -> Void = { [weak self] in
            guard let self = self else { return }
            
            if self.taskId != UIBackgroundTaskIdentifier.invalid {
                sharedApplication.endBackgroundTask(self.taskId)
                self.taskId = UIBackgroundTaskIdentifier.invalid
            }
        }
        
        taskId = sharedApplication.beginBackgroundTask(expirationHandler: completionHandler)
        
        // Ensure that any session replay ID is cleared when the app enters the background
        unregisterSuperProperty("$mp_replay_id")
        
        if flushOnBackground {
            flush(performFullFlush: true, completion: completionHandler)
        }
    }
    
    @objc private func applicationWillEnterForeground(_ notification: Notification) {
        guard let sharedApplication = OursPrivacyInstance.sharedUIApplication() else {
            return
        }
        sessionMetadata.applicationWillEnterForeground()
        
        if taskId != UIBackgroundTaskIdentifier.invalid {
            sharedApplication.endBackgroundTask(taskId)
            taskId = UIBackgroundTaskIdentifier.invalid
#if os(iOS)
            self.updateNetworkActivityIndicator(false)
#endif // os(iOS)
        }
        
    }
#endif
    
    func addPrefixToDeviceId(deviceId: String?) -> String {
        if let temp = deviceId {
            return devicePrefix + temp
        }
        return ""
    }
    
    func defaultDeviceId() -> String {
        let distinctId: String?
        if useUniqueDistinctId {
            distinctId = uniqueIdentifierForDevice()
        } else {
#if OURSPRIVACY_UNIQUE_DISTINCT_ID
            distinctId = uniqueIdentifierForDevice()
#else
            distinctId = nil
#endif
        }
        return distinctId ?? UUID().uuidString // use a random UUID by default
    }
    
    func uniqueIdentifierForDevice() -> String? {
        var distinctId: String?
#if os(OSX)
        distinctId = OursPrivacyInstance.macOSIdentifier()
#elseif !os(watchOS)
        if NSClassFromString("UIDevice") != nil {
            distinctId = UIDevice.current.identifierForVendor?.uuidString
        } else {
            distinctId = nil
        }
#else
        distinctId = nil
#endif
        return distinctId
    }
    
#if os(OSX)
    static func macOSIdentifier() -> String? {
        let platformExpert: io_service_t = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        let serialNumberAsCFString =
        IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)
        IOObjectRelease(platformExpert)
        return (serialNumberAsCFString?.takeUnretainedValue() as? String)
    }
#endif // os(OSX)
    
#if os(iOS)
    func updateNetworkActivityIndicator(_ on: Bool) {
        if showNetworkActivityIndicator {
            DispatchQueue.main.async { [on] in
                OursPrivacyInstance.sharedUIApplication()?.isNetworkActivityIndicatorVisible = on
            }
        }
    }
#if os(iOS) && !targetEnvironment(macCatalyst)
    @objc func setCurrentRadio() {
        var radio = ""
        let prefix = "CTRadioAccessTechnology"
        if #available(iOS 12.0, *) {
            if let radioDict = OursPrivacyInstance.telephonyInfo.serviceCurrentRadioAccessTechnology {
                for (_, value) in radioDict where !value.isEmpty && value.hasPrefix(prefix) {
                    // the first should be the prefix, second the target
                    let components = value.components(separatedBy: prefix)
                    
                    // Something went wrong and we have more than prefix:target
                    guard components.count == 2 else {
                        continue
                    }
                    
                    // Safe to directly access by index since we confirmed count == 2 above
                    let radioValue = components[1]
                    
                    // Send to parent
                    radio += radio.isEmpty ? radioValue : ", \(radioValue)"
                }
                
                radio = radio.isEmpty ? "None": radio
            }
        } else {
            radio = OursPrivacyInstance.telephonyInfo.currentRadioAccessTechnology ?? "None"
            if radio.hasPrefix(prefix) {
                radio = (radio as NSString).substring(from: prefix.count)
            }
        }
        
        trackingQueue.async {
            AutomaticProperties.automaticPropertiesLock.write { [weak self, radio] in
                AutomaticProperties.properties["$radio"] = radio
                
                guard self != nil else {
                    return
                }
                
                AutomaticProperties.properties["$carrier"] = ""
                if #available(iOS 12.0, *) {
                    if let carrierName = OursPrivacyInstance.telephonyInfo.serviceSubscriberCellularProviders?.first?.value.carrierName {
                        AutomaticProperties.properties["$carrier"] = carrierName
                    }
                } else {
                    if let carrierName = OursPrivacyInstance.telephonyInfo.subscriberCellularProvider?.carrierName {
                        AutomaticProperties.properties["$carrier"] = carrierName
                    }
                }
            }
        }
    }
#endif
#endif // os(iOS)
    
    @objc func handleSuperPropertiesRegistrationNotification(_ notification: Notification) {
        guard let data = notification.userInfo else { return }
        
        if notification.name.rawValue == registerSuperPropertiesNotificationName.rawValue {
            guard let properties = data as? Properties else { return }
            registerSuperProperties(properties)
        } else {
            for (key, _) in data {
                if let keyToUnregister = key as? String {
                    unregisterSuperProperty(keyToUnregister)
                }
            }
        }
    }
}

extension OursPrivacyInstance {
    // MARK: - Identity
    
    /**
     Sets the distinct ID of the current user.
     
     OursPrivacy uses a randomly generated persistent UUID  as the default local distinct ID.
     
     If you want to  use a unique persistent UUID, you can define the
     <code>OURSPRIVACY_UNIQUE_DISTINCT_ID</code> flag in your <code>Active Compilation Conditions</code>
     build settings. It then uses the IFV String (`UIDevice.current().identifierForVendor`) as
     the default local distinct ID. This ID will identify a user across all apps by the same vendor, but cannot be
     used to link the same user across apps from different vendors. If we are unable to get an IFV, we will fall
     back to generating a random persistent UUID.
     
     For tracking events, you do not need to call `identify:`. However,
     **OursPrivacy User profiles always requires an explicit call to `identify:`.**
          
     If you'd like to use the default distinct ID for OursPrivacy People as well
     (recommended), call `identify:` using the current distinct ID:
     `oursprivacyInstance.identify(oursprivacyInstance.distinctId)`.
     
     - parameter distinctId: string that uniquely identifies the current user
     - parameter userProperties: user properties to associate with this user.  The existing user properties will be updated.  All future events will have these properties associated with them.
     - parameter completion: an optional completion handler for when the identify has completed.
     
     see https://docs.oursprivacy.com/reference/postidentify
     */
    public func identify(distinctId: String, userProperties: Properties?, completion: (() -> Void)? = nil) {
        if hasOptedOutTracking() {
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }
        if distinctId.isEmpty {
            OursPrivacyLogger.error(message: "\(self) cannot identify blank distinct id")
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }
        trackingQueue.async { [weak self, distinctId] in
            guard let self = self else { return }
            
            // If there's no anonymousId assigned yet, that means distinctId is stored in the storage. Assigning already stored
            // distinctId as anonymousId on identify and also setting a flag to notify that it might be previously logged in user
            if self.anonymousId == nil {
                self.anonymousId = self.distinctId
                self.hadPersistedDistinctId = true
            }
            
            if self.userId == nil {
                self.readWriteLock.write {
                    self.userId = distinctId
                }
            }
            
            if distinctId != self.distinctId {
                let oldDistinctId = self.distinctId
                self.readWriteLock.write {
                    self.alias = nil
                    self.distinctId = distinctId
                    self.userId = distinctId
                }
                self.track(event: "$identify", properties: ["$anon_distinct_id": oldDistinctId])
            }
            
//            if usePeople {
//                self.readWriteLock.write {
//                    self.people.distinctId = distinctId
//                }
//                self.oursprivacyPersistence.identifyPeople(token: self.apiToken)
//            } else {
//                self.people.distinctId = nil
//            }
            
            OursPrivacyPersistence.saveIdentity(OursPrivacyIdentity.init(
                distinctID: self.distinctId,
//                peopleDistinctID: self.people.distinctId,
                anonymousId: self.anonymousId,
                userId: self.userId,
                alias: self.alias,
                hadPersistedDistinctId: self.hadPersistedDistinctId), instanceName: self.name)
            
            let proxyServerResource = proxyServerDelegate?.oursprivacyResourceForProxyServer(name)
            let headers: [String: String] = proxyServerResource?.headers ?? [:]
            let queryItems = proxyServerResource?.queryItems ?? []
            var requestData = ["userId": distinctId, "token": self.apiToken] as Properties
            if let up = userProperties {
                requestData.updateValue(up, forKey: "userProperties")
            }
            if let requestDataStr = JSONHandler.encodeAPIData(requestData) {
                let result = flushInstance.flushRequest.sendRequest(requestDataStr, type: .identify, useIP: true, headers: headers, queryItems: queryItems)
                if !result {
                    OursPrivacyLogger.warn(message: "Remote call to identify failed")
                }
            } else {
                OursPrivacyLogger.error(message: "Unable to JSON encode user properties in identify")
            }
            
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
        
        if OursPrivacyInstance.isiOSAppExtension() {
            flush()
        }
    }
    
    /**
     The alias method creates an alias which OursPrivacy will use to remap one id to another.
     Multiple aliases can point to the same identifier.
     
     Please note: With OursPrivacy Identity Merge enabled, calling alias is no longer required
     but can be used to merge two IDs in scenarios where identify() would fail
     
     
     `oursprivacyInstance.createAlias("New ID", distinctId: oursprivacyInstance.distinctId)`
     
     You can add multiple id aliases to the existing id
     
     `oursprivacyInstance.createAlias("Newer ID", distinctId: oursprivacyInstance.distinctId)`
     
     
     - parameter alias:      A unique identifier that you want to use as an identifier for this user.
     - parameter distinctId: The current user identifier.
     - parameter usePeople: boolean that controls whether or not to set the people distinctId to the event distinctId.
     - parameter andIdentify: an optional boolean that controls whether or not to call 'identify' with your current
     user identifier(not alias). Default to true for keeping your signup funnels working correctly in most cases.
     - parameter completion: an optional completion handler for when the createAlias has completed.
     This should only be set to false if you wish to prevent people profile updates for that user.
     */
    public func createAlias(_ alias: String, distinctId: String, usePeople: Bool = true, andIdentify: Bool = true, completion: (() -> Void)? = nil) {
        if hasOptedOutTracking() {
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }
        
        if distinctId.isEmpty {
            OursPrivacyLogger.error(message: "\(self) cannot identify blank distinct id")
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }
        
        if alias.isEmpty {
            OursPrivacyLogger.error(message: "\(self) create alias called with empty alias")
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }

        if alias != distinctId {
            trackingQueue.async { [weak self, alias] in
                guard let self = self else {
                    if let completion = completion {
                        DispatchQueue.main.async(execute: completion)
                    }
                    return
                }
                self.readWriteLock.write {
                    self.alias = alias
                }
                
                var distinctIdSnapshot: String?
//                var peopleDistinctIDSnapshot: String?
                var anonymousIdSnapshot: String?
                var userIdSnapshot: String?
                var aliasSnapshot: String?
                var hadPersistedDistinctIdSnapshot: Bool?
                
                self.readWriteLock.read {
                    distinctIdSnapshot = self.distinctId
//                    peopleDistinctIDSnapshot = self.people.distinctId
                    anonymousIdSnapshot = self.anonymousId
                    userIdSnapshot = self.userId
                    aliasSnapshot = self.alias
                    hadPersistedDistinctIdSnapshot = self.hadPersistedDistinctId
                }
                
                OursPrivacyPersistence.saveIdentity(OursPrivacyIdentity.init(
                    distinctID: distinctIdSnapshot!,
//                    peopleDistinctID: peopleDistinctIDSnapshot,
                    anonymousId: anonymousIdSnapshot,
                    userId: userIdSnapshot,
                    alias: aliasSnapshot,
                    hadPersistedDistinctId: hadPersistedDistinctIdSnapshot), instanceName: self.name)
            }
            
            let properties = ["distinct_id": distinctId, "alias": alias]
            track(event: "$create_alias", properties: properties)
            if andIdentify {
                identify(distinctId: distinctId, userProperties: nil)
            }
            flush(completion: completion)
        } else {
            OursPrivacyLogger.error(message: "alias: \(alias) matches distinctId: \(distinctId) - skipping api call.")
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }
    
    /**
     Clears all stored properties including the distinct Id.
     Useful if your app's user logs out.
     
     - parameter completion: an optional completion handler for when the reset has completed.
     */
    public func reset(completion: (() -> Void)? = nil) {
        flush()
        trackingQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            
            OursPrivacyPersistence.deleteMPUserDefaultsData(instanceName: self.name)
            self.readWriteLock.write {
                self.timedEvents = InternalProperties()
                self.anonymousId = self.defaultDeviceId()
                self.distinctId = self.addPrefixToDeviceId(deviceId: self.anonymousId)
                self.hadPersistedDistinctId = true
                self.userId = nil
                self.superProperties = InternalProperties()
//                self.people.distinctId = nil
                self.alias = nil
            }
            
            self.oursprivacyPersistence.resetEntities()
            self.archive()
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }
}

extension OursPrivacyInstance {
    // MARK: - Persistence
    
    public func archive() {
        self.readWriteLock.read {
            OursPrivacyPersistence.saveTimedEvents(timedEvents: timedEvents, instanceName: self.name)
            OursPrivacyPersistence.saveSuperProperties(superProperties: superProperties, instanceName: self.name)
            OursPrivacyPersistence.saveIdentity(OursPrivacyIdentity.init(
                distinctID: distinctId,
//                peopleDistinctID: people.distinctId,
                anonymousId: anonymousId,
                userId: userId,
                alias: alias,
                hadPersistedDistinctId: hadPersistedDistinctId), instanceName: self.name)
        }
    }
    
    func unarchive() {
        let didCreateIdentity = self.readWriteLock.write {
            optOutStatus = OursPrivacyPersistence.loadOptOutStatusFlag(instanceName: self.name)
            superProperties = OursPrivacyPersistence.loadSuperProperties(instanceName: self.name)
            timedEvents = OursPrivacyPersistence.loadTimedEvents(instanceName: self.name)
            let oursprivacyIdentity = OursPrivacyPersistence.loadIdentity(instanceName: self.name)
            (distinctId, anonymousId, userId, alias, hadPersistedDistinctId) = (
                oursprivacyIdentity.distinctID,
                oursprivacyIdentity.anonymousId,
                oursprivacyIdentity.userId,
                oursprivacyIdentity.alias,
                oursprivacyIdentity.hadPersistedDistinctId
            )
            if distinctId.isEmpty {
                anonymousId = defaultDeviceId()
                distinctId = addPrefixToDeviceId(deviceId: anonymousId)
                hadPersistedDistinctId = true
                userId = nil
                return true
            } else {
                return false
            }
        }

        if didCreateIdentity {
            self.readWriteLock.read {
                OursPrivacyPersistence.saveIdentity(OursPrivacyIdentity.init(
                    distinctID: distinctId,
//                    peopleDistinctID: people.distinctId,
                    anonymousId: anonymousId,
                    userId: userId,
                    alias: alias,
                    hadPersistedDistinctId: hadPersistedDistinctId), instanceName: self.name)
            }
        }
    }
}

extension OursPrivacyInstance {
    // MARK: - Flush
    
    /**
     Uploads queued data to the OursPrivacy server.
     
     By default, queued data is flushed to the OursPrivacy servers every minute (the
     default for `flushInterval`), and on background (since
     `flushOnBackground` is on by default). You only need to call this
     method manually if you want to force a flush at a particular moment.
     
     - parameter performFullFlush: A optional boolean value indicating whether a full flush should be performed. If `true`, a full flush will be triggered, sending all events to the server. Default to `false`, a partial flush will be executed for reducing memory footprint.
     - parameter completion: an optional completion handler for when the flush has completed.
     */
    public func flush(performFullFlush: Bool = false, completion: (() -> Void)? = nil) {
        if hasOptedOutTracking() {
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }
        trackingQueue.async { [weak self, completion] in
            guard let self = self else {
                if let completion = completion {
                    DispatchQueue.main.async(execute: completion)
                }
                return
            }
            
            if let shouldFlush = self.delegate?.oursprivacyWillFlush(self), !shouldFlush {
                if let completion = completion {
                    DispatchQueue.main.async(execute: completion)
                }
                return
            }
            
            // automatic events will NOT be flushed until one of the flags is non-nil
            let eventQueue = self.oursprivacyPersistence.loadEntitiesInBatch(
                type: self.persistenceTypeFromFlushType(.events),
                batchSize: performFullFlush ? Int.max : self.flushBatchSize,
                excludeAutomaticEvents: !self.trackAutomaticEventsEnabled
            )
//            let peopleQueue = self.oursprivacyPersistence.loadEntitiesInBatch(
//                type: self.persistenceTypeFromFlushType(.people),
//                batchSize: performFullFlush ? Int.max : self.flushBatchSize
//            )
//            let groupsQueue = self.oursprivacyPersistence.loadEntitiesInBatch(
//                type: self.persistenceTypeFromFlushType(.groups),
//                batchSize: performFullFlush ? Int.max : self.flushBatchSize
//            )
            
            self.networkQueue.async { [weak self, completion] in
                guard let self = self else {
                    if let completion = completion {
                        DispatchQueue.main.async(execute: completion)
                    }
                    return
                }
                self.flushQueue(eventQueue, type: .events)
//                self.flushQueue(peopleQueue, type: .people)
//                self.flushQueue(groupsQueue, type: .groups)
                
                if let completion = completion {
                    DispatchQueue.main.async(execute: completion)
                }
            }
        }
    }
    
    private func persistenceTypeFromFlushType(_ type: FlushType) -> PersistenceType {
//        switch type {
//        case .events:
            return PersistenceType.events
//        case .people:
//            return PersistenceType.people
//        case .groups:
//            return PersistenceType.groups
//        }
    }
    
    func flushQueue(_ queue: Queue, type: FlushType) {
        if hasOptedOutTracking() {
            return
        }
        let proxyServerResource = proxyServerDelegate?.oursprivacyResourceForProxyServer(name)
        let headers: [String: String] = proxyServerResource?.headers ?? [:]
        let queryItems = proxyServerResource?.queryItems ?? []
       
        self.flushInstance.flushQueue(queue, type: type, headers: headers, queryItems: queryItems)
    }
    
    func flushSuccess(type: FlushType, ids: [Int32]) {
        trackingQueue.async { [weak self] in
            guard let self = self else {
                return
            }
            self.oursprivacyPersistence.removeEntitiesInBatch(type: self.persistenceTypeFromFlushType(type), ids: ids)
        }
    }
    
}

extension OursPrivacyInstance {
    // MARK: - Track
    
    /**
     Tracks an event with properties.
     Properties are optional and can be added only if needed.
     
     Properties will allow you to segment your events in your OursPrivacy reports.
     Property keys must be String objects and the supported value types need to conform to OursPrivacyType.
     OursPrivacyType can be either String, Int, UInt, Double, Float, Bool, [OursPrivacyType], [String: OursPrivacyType], Date, URL, or NSNull.
     If the event is being timed, the timer will stop and be added as a property.
     
     - parameter event:      event name
     - parameter properties: properties dictionary
     */
    public func track(event: String?, properties: Properties? = nil) {
        let epochInterval = Date().timeIntervalSince1970
        
        OursPrivacyLogger.debug(message: "Tracking \(event ?? "nil")")
        
        trackingQueue.async { [weak self, event, properties, epochInterval] in
            guard let self else {
                return
            }
            if self.hasOptedOutTracking() {
                return
            }
            var shadowTimedEvents = InternalProperties()
            var shadowSuperProperties = InternalProperties()
            
            self.readWriteLock.read {
                shadowTimedEvents = self.timedEvents
                shadowSuperProperties = self.superProperties
            }
            
            let oursprivacyIdentity = OursPrivacyIdentity.init(distinctID: self.distinctId,
//                                                         peopleDistinctID: nil,
                                                         anonymousId: self.anonymousId,
                                                         userId: self.userId,
                                                         alias: nil,
                                                         hadPersistedDistinctId: self.hadPersistedDistinctId)
            let timedEventsSnapshot = self.trackInstance.track(event: event,
                                                               properties: properties,
                                                               timedEvents: shadowTimedEvents,
                                                               superProperties: shadowSuperProperties,
                                                               oursprivacyIdentity: oursprivacyIdentity,
                                                               epochInterval: epochInterval)
            
            self.readWriteLock.write {
                self.timedEvents = timedEventsSnapshot
            }
        }
        
        if OursPrivacyInstance.isiOSAppExtension() {
            flush()
        }
    }
    
//    /**
//     Tracks an event with properties and to specific groups.
//     Properties and groups are optional and can be added only if needed.
//     
//     Properties will allow you to segment your events in your OursPrivacy reports.
//     Property and group keys must be String objects and the supported value types need to conform to OursPrivacyType.
//     OursPrivacyType can be either String, Int, UInt, Double, Float, Bool, [OursPrivacyType], [String: OursPrivacyType], Date, URL, or NSNull.
//     If the event is being timed, the timer will stop and be added as a property.
//     
//     - parameter event:      event name
//     - parameter properties: properties dictionary
//     - parameter groups:     groups dictionary
//     */
//    public func trackWithGroups(event: String?, properties: Properties? = nil, groups: Properties?) {
//        if hasOptedOutTracking() {
//            return
//        }
//        
//        guard let properties = properties else {
//            self.track(event: event, properties: groups)
//            return
//        }
//        
//        guard let groups = groups else {
//            self.track(event: event, properties: properties)
//            return
//        }
//        
//        var mergedProperties = properties
//        for (groupKey, groupID) in groups {
//            mergedProperties[groupKey] = groupID
//        }
//        self.track(event: event, properties: mergedProperties)
//    }
    
//    public func getGroup(groupKey: String, groupID: OursPrivacyType) -> Group {
//        let key = makeMapKey(groupKey: groupKey, groupID: groupID)
//        
//        var groupsShadow: [String: Group] = [:]
//        
//        readWriteLock.read {
//            groupsShadow = groups
//        }
//        
//        guard let group = groupsShadow[key] else {
//            readWriteLock.write {
//                groups[key] = Group(apiToken: apiToken,
//                                    serialQueue: trackingQueue,
//                                    lock: self.readWriteLock,
//                                    groupKey: groupKey,
//                                    groupID: groupID,
//                                    metadata: sessionMetadata,
//                                    oursprivacyPersistence: oursprivacyPersistence,
//                                    oursprivacyInstance: self)
//                groupsShadow = groups
//            }
//            return groupsShadow[key]!
//        }
//        
//        if !(group.groupKey == groupKey && group.groupID.equals(rhs: groupID)) {
//            // we somehow hit a collision on the map key, return a new group with the correct key and ID
//            OursPrivacyLogger.info(message: "groups dictionary key collision: \(key)")
//            let newGroup = Group(apiToken: apiToken,
//                                 serialQueue: trackingQueue,
//                                 lock: self.readWriteLock,
//                                 groupKey: groupKey,
//                                 groupID: groupID,
//                                 metadata: sessionMetadata,
//                                 oursprivacyPersistence: oursprivacyPersistence,
//                                 oursprivacyInstance: self)
//            readWriteLock.write {
//                groups[key] = newGroup
//            }
//            return newGroup
//        }
//        
//        return group
//    }
//    
//    func removeCachedGroup(groupKey: String, groupID: OursPrivacyType) {
//        readWriteLock.write {
//            groups.removeValue(forKey: makeMapKey(groupKey: groupKey, groupID: groupID))
//        }
//    }
    
//    func makeMapKey(groupKey: String, groupID: OursPrivacyType) -> String {
//        return "\(groupKey)_\(groupID)"
//    }
    
    /**
     Starts a timer that will be stopped and added as a property when a
     corresponding event is tracked.
     
     This method is intended to be used in advance of events that have
     a duration. For example, if a developer were to track an "Image Upload" event
     she might want to also know how long the upload took. Calling this method
     before the upload code would implicitly cause the `track`
     call to record its duration.
     
     - precondition:
     // begin timing the image upload:
     oursprivacyInstance.time(event:"Image Upload")
     // upload the image:
     self.uploadImageWithSuccessHandler() { _ in
     // track the event
     oursprivacyInstance.track("Image Upload")
     }
     
     - parameter event: the event name to be timed
     
     */
    public func time(event: String) {
        let startTime = Date().timeIntervalSince1970
        trackingQueue.async { [weak self, startTime, event] in
            guard let self = self else { return }
            let timedEvents = self.trackInstance.time(event: event, timedEvents: self.timedEvents, startTime: startTime)
            self.readWriteLock.write {
                self.timedEvents = timedEvents
            }
            OursPrivacyPersistence.saveTimedEvents(timedEvents: timedEvents, instanceName: self.name)
        }
    }
    
    /**
     Retrieves the time elapsed for the named event since time(event:) was called.
     
     - parameter event: the name of the event to be tracked that was passed to time(event:)
     */
    public func eventElapsedTime(event: String) -> Double {
        var timedEvents = InternalProperties()
        self.readWriteLock.read {
            timedEvents = self.timedEvents
        }
        
        if let startTime = timedEvents[event] as? TimeInterval {
            return Date().timeIntervalSince1970 - startTime
        }
        return 0
    }
    
    /**
     Clears all current event timers.
     */
    public func clearTimedEvents() {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            self.readWriteLock.write {
                self.timedEvents = InternalProperties()
            }
            OursPrivacyPersistence.saveTimedEvents(timedEvents: InternalProperties(), instanceName: self.name)
        }
    }
    
    /**
     Clears the event timer for the named event.
     
     - parameter event: the name of the event to clear the timer for
     */
    public func clearTimedEvent(event: String) {
        trackingQueue.async { [weak self, event] in
            guard let self = self else { return }
            
            let updatedTimedEvents = self.trackInstance.clearTimedEvent(event: event, timedEvents: self.timedEvents)
            OursPrivacyPersistence.saveTimedEvents(timedEvents: updatedTimedEvents, instanceName: self.name)
        }
    }
    
    /**
     Returns the currently set super properties.
     
     - returns: the current super properties
     */
    public func currentSuperProperties() -> [String: Any] {
        var properties = InternalProperties()
        self.readWriteLock.read {
            properties = superProperties
        }
        return properties
    }
    
    /**
     Clears all currently set super properties.
     */
    public func clearSuperProperties() {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            self.superProperties = self.trackInstance.clearSuperProperties(self.superProperties)
            OursPrivacyPersistence.saveSuperProperties(superProperties: self.superProperties, instanceName: self.name)
        }
    }
    
    /**
     Registers super properties, overwriting ones that have already been set.
     
     Super properties, once registered, are automatically sent as properties for
     all event tracking calls. They save you having to maintain and add a common
     set of properties to your events.
     Property keys must be String objects and the supported value types need to conform to OursPrivacyType.
     OursPrivacyType can be either String, Int, UInt, Double, Float, Bool, [OursPrivacyType], [String: OursPrivacyType], Date, URL, or NSNull.
     
     - parameter properties: properties dictionary
     */
    public func registerSuperProperties(_ properties: Properties) {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            let updatedSuperProperties = self.trackInstance.registerSuperProperties(properties,
                                                                                    superProperties: self.superProperties)
            self.readWriteLock.write {
                self.superProperties = updatedSuperProperties
            }
            self.readWriteLock.read {
                OursPrivacyPersistence.saveSuperProperties(superProperties: self.superProperties, instanceName: self.name)
            }
        }
    }
    
    
    
    
    
    /**
     Registers super properties without overwriting ones that have already been set,
     unless the existing value is equal to defaultValue. defaultValue is optional.
     
     Property keys must be String objects and the supported value types need to conform to OursPrivacyType.
     OursPrivacyType can be either String, Int, UInt, Double, Float, Bool, [OursPrivacyType], [String: OursPrivacyType], Date, URL, or NSNull.
     
     - parameter properties:   properties dictionary
     - parameter defaultValue: Optional. overwrite existing properties that have this value
     */
    public func registerSuperPropertiesOnce(_ properties: Properties,
                                          defaultValue: OursPrivacyType? = nil) {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            let updatedSuperProperties = self.trackInstance.registerSuperPropertiesOnce(properties,
                                                                                        superProperties: self.superProperties,
                                                                                        defaultValue: defaultValue)
            self.readWriteLock.write {
                self.superProperties = updatedSuperProperties
            }
            self.readWriteLock.read {
                OursPrivacyPersistence.saveSuperProperties(superProperties: self.superProperties, instanceName: self.name)
            }
        }
    }
    
    /**
     Removes a previously registered super property.
     
     As an alternative to clearing all properties, unregistering specific super
     properties prevents them from being recorded on future events. This operation
     does not affect the value of other super properties. Any property name that is
     not registered is ignored.
     Note that after removing a super property, events will show the attribute as
     having the value `undefined` in OursPrivacy until a new value is
     registered.
     
     - parameter propertyName: array of property name strings to remove
     */
    public func unregisterSuperProperty(_ propertyName: String) {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            let updatedSuperProperties = self.trackInstance.unregisterSuperProperty(propertyName,
                                                                              superProperties: self.superProperties)
            self.readWriteLock.write {
                self.superProperties = updatedSuperProperties
            }
            self.readWriteLock.read {
                OursPrivacyPersistence.saveSuperProperties(superProperties: self.superProperties, instanceName: self.name)
            }
        }
    }
    
    /**
     Updates a super property atomically. The update function
     
     - parameter update: closure to apply to super properties
     */
    func updateSuperProperty(_ update: @escaping (_ superproperties: inout InternalProperties) -> Void) {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            var superPropertiesShadow = self.superProperties
            self.trackInstance.updateSuperProperty(update,
                                                   superProperties: &superPropertiesShadow)
            self.readWriteLock.write {
                self.superProperties = superPropertiesShadow
            }
            self.readWriteLock.read {
                OursPrivacyPersistence.saveSuperProperties(superProperties: self.superProperties, instanceName: self.name)
            }
        }
    }
    
//    /**
//     Convenience method to set a single group the user belongs to.
//     
//     - parameter groupKey: The property name associated with this group type (must already have been set up).
//     - parameter groupID: The group the user belongs to.
//     */
//    public func setGroup(groupKey: String, groupID: OursPrivacyType) {
//        if hasOptedOutTracking() {
//            return
//        }
//        
//        setGroup(groupKey: groupKey, groupIDs: [groupID])
//    }
    
//    /**
//     Set the groups this user belongs to.
//     
//     - parameter groupKey: The property name associated with this group type (must already have been set up).
//     - parameter groupIDs: The list of groups the user belongs to.
//     */
//    public func setGroup(groupKey: String, groupIDs: [OursPrivacyType]) {
//        if hasOptedOutTracking() {
//            return
//        }
//        
//        let properties = [groupKey: groupIDs]
//        self.registerSuperProperties(properties)
//        people.set(properties: properties)
//    }
    
//    /**
//     Add a group to this user's membership for a particular group key
//     
//     - parameter groupKey: The property name associated with this group type (must already have been set up).
//     - parameter groupID: The new group the user belongs to.
//     */
//    public func addGroup(groupKey: String, groupID: OursPrivacyType) {
//        if hasOptedOutTracking() {
//            return
//        }
//        
//        updateSuperProperty { superProperties in
//            guard let oldValue = superProperties[groupKey] else {
//                superProperties[groupKey] = [groupID]
//                self.people.set(properties: [groupKey: [groupID]])
//                return
//            }
//            
//            if let oldValue = oldValue as? [OursPrivacyType] {
//                var vals = oldValue
//                if !vals.contains(where: { $0.equals(rhs: groupID) }) {
//                    vals.append(groupID)
//                    superProperties[groupKey] = vals
//                }
//            } else {
//                superProperties[groupKey] = [oldValue, groupID]
//            }
//            
//            // This is a best effort--if the people property is not already a list, this call does nothing.
//            self.people.union(properties: [groupKey: [groupID]])
//        }
//    }
//    
//    /**
//     Remove a group from this user's membership for a particular group key
//     
//     - parameter groupKey: The property name associated with this group type (must already have been set up).
//     - parameter groupID: The group value to remove.
//     */
//    public func removeGroup(groupKey: String, groupID: OursPrivacyType) {
//        if hasOptedOutTracking() {
//            return
//        }
//        
//        updateSuperProperty { (superProperties) -> Void in
//            guard let oldValue = superProperties[groupKey] else {
//                return
//            }
//            
//            guard let vals = oldValue as? [OursPrivacyType] else {
//                superProperties.removeValue(forKey: groupKey)
//                self.people.unset(properties: [groupKey])
//                return
//            }
//            
//            if vals.count < 2 {
//                superProperties.removeValue(forKey: groupKey)
//                self.people.unset(properties: [groupKey])
//                return
//            }
//            
//            superProperties[groupKey] = vals.filter {!$0.equals(rhs: groupID)}
//            self.people.remove(properties: [groupKey: groupID])
//        }
//    }
    
    /**
     Opt out tracking.
     
     This method is used to opt out tracking. This causes all events requests no longer
     to be sent back to the OursPrivacy server.
     */
    public func optOutTracking() {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
//            if self.people.distinctId != nil {
//                self.people.deleteUser()
//                self.people.clearCharges()
//                self.flush()
//            }
            self.readWriteLock.write { [weak self] in
                guard let self = self else {
                    return
                }
                
                self.alias = nil
//                self.people.distinctId = nil
                self.userId = nil
                self.anonymousId = self.defaultDeviceId()
                self.distinctId = self.addPrefixToDeviceId(deviceId: self.anonymousId)
                self.hadPersistedDistinctId = true
                self.superProperties = InternalProperties()
                OursPrivacyPersistence.saveTimedEvents(timedEvents: InternalProperties(), instanceName: self.name)
            }
            self.archive()
            self.readWriteLock.write {
                self.optOutStatus = true
            }
            self.readWriteLock.read {
                OursPrivacyPersistence.saveOptOutStatusFlag(value: self.optOutStatus!, instanceName: self.name)
            }
            
        }
    }
    
    /**
     Opt in tracking.
     
     Use this method to opt in an already opted out user from tracking. People updates and track calls will be
     sent to OursPrivacy after using this method.
     
     This method will internally track an opt in event to your project.
     
     - parameter distintId: an optional string to use as the distinct ID for events
     - parameter properties: an optional properties dictionary that could be passed to add properties to the opt-in event
     that is sent to OursPrivacy
     */
    public func optInTracking(distinctId: String? = nil, properties: Properties? = nil) {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            self.readWriteLock.write {
                self.optOutStatus = false
            }
            self.readWriteLock.read {
                OursPrivacyPersistence.saveOptOutStatusFlag(value: self.optOutStatus!, instanceName: self.name)
            }
            if let distinctId = distinctId {
                self.identify(distinctId: distinctId, userProperties: nil)
            }
            self.track(event: "$opt_in", properties: properties)
        }
        
        
    }
    
    /**
     Returns if the current user has opted out tracking.
     
     - returns: the current super opted out tracking status
     */
    public func hasOptedOutTracking() -> Bool {
        var optOutStatusShadow: Bool?
        readWriteLock.read {
            optOutStatusShadow = optOutStatus
        }
        return optOutStatusShadow ?? false
    }
    
    // MARK: - AEDelegate
    func increment(property: String, by: Double) {
//        people?.increment(property: property, by: by)
    }
    
    func setOnce(properties: Properties) {
//        people?.setOnce(properties: properties)
    }
    
}

