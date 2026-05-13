//
//  OursPrivacyInstance.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//

import Foundation
#if !os(OSX)
import UIKit
#else
import Cocoa
#endif

/// Delegate for proxy-server resource resolution. Same surface as before; the SDK
/// asks the host for headers / query items per request when a proxy is configured.
public protocol OursPrivacyProxyServerDelegate: AnyObject {
    func oursprivacyResourceForProxyServer(_ name: String) -> ServerProxyResource?
}

/// Delegate that can veto a flush attempt. Useful for hosts that gate network
/// activity on radio state, foreground/background, etc.
public protocol OursPrivacyDelegate: AnyObject {
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
        guard serverUrl != BasePath.DefaultAPIEndpoint else { return nil }
        self.serverUrl = serverUrl
        self.delegate = delegate
    }

    let serverUrl: String
    let delegate: OursPrivacyProxyServerDelegate?
}

/// The class that represents the OursPrivacy instance. Public API is the
/// stable surface customer apps call against — `identify`, `track`, `flush`,
/// `reset`, opt-in/out. Internal wire-shape composition lives in `Track`.
open class OursPrivacyInstance: CustomDebugStringConvertible, FlushDelegate, AEDelegate {

    /// The project token. Set once via `OursPrivacy.initialize(...)`.
    open var apiToken = ""

    /// Optional delegate that can veto a flush attempt.
    open weak var delegate: OursPrivacyDelegate?

    /// Stable per-install identifier sent as `visitor_id` on every event. Generated
    /// lazily on first launch and persisted in NSUserDefaults under the OursPrivacy
    /// suite. Reset by `reset()`.
    open var visitorId: String = ""

    /// True only when the host explicitly called `setVisitorId(...)` (Pass B).
    /// Forwarded as the top-level `is_manually_set_id` envelope field.
    open var isManuallySetId: Bool = false

    let oursprivacyPersistence: OursPrivacyPersistence

    /// Show the network activity indicator while flushing. iOS-only.
    open var showNetworkActivityIndicator = true

    /// Enables automatic-event tracking. Forwarded to `AutomaticEvents`.
    open var trackAutomaticEventsEnabled: Bool

    /// Flush timer interval (seconds). 0 disables auto-flush; the host calls
    /// `flush()` manually.
    open var flushInterval: Double {
        get { flushInstance.flushInterval }
        set { flushInstance.flushInterval = newValue }
    }

    /// Flush queued events when the app enters background. Defaults to true.
    open var flushOnBackground: Bool {
        get { flushInstance.flushOnBackground }
        set { flushInstance.flushOnBackground = newValue }
    }

    /// Number of events bundled into a single ingest request. Server caps at 50.
    open var flushBatchSize: Int {
        get { flushInstance.flushBatchSize }
        set { flushInstance.flushBatchSize = min(newValue, APIConstants.maxBatchSize) }
    }

    /// Base URL for `/ingest`. Defaults to `https://cdn.oursprivacy.com`.
    open var serverURL = BasePath.DefaultAPIEndpoint {
        didSet { flushInstance.serverURL = serverURL }
    }

    /// Optional proxy delegate that supplies per-request headers / query items.
    open weak var proxyServerDelegate: OursPrivacyProxyServerDelegate? = nil

    open var debugDescription: String {
        return "OursPrivacy(\n"
            + "    Token: \(apiToken),\n"
            + "    Visitor Id: \(visitorId)\n"
            + ")"
    }

    /// Toggles SDK logging at runtime. Off by default — flip on while debugging.
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
        }
    }

    /// Unique name for this instance. Defaults to the token. Allows multi-token apps.
    public let name: String

#if os(iOS) || os(tvOS) || os(visionOS)
    open var minimumSessionDuration: UInt64 {
        get { automaticEvents.minimumSessionDuration }
        set { automaticEvents.minimumSessionDuration = newValue }
    }

    open var maximumSessionDuration: UInt64 {
        get { automaticEvents.maximumSessionDuration }
        set { automaticEvents.maximumSessionDuration = newValue }
    }
#endif

    // Default-properties bags. Populated by the Pass B setters
    // (`updateDefaultEventProperties` / `…UserCustomProperties` /
    // `…UserConsentProperties` / `trackDeepLink`). Empty for now — the composer
    // reads them on every event with no conditional branch.
    var defaultEventProperties: InternalProperties = [:]
    var userCustomProperties: InternalProperties = [:]
    var userConsentProperties: InternalProperties = [:]
    var attributionDefaultProperties: InternalProperties = [:]

    var trackingQueue: DispatchQueue
    var networkQueue: DispatchQueue
    var optOutStatus: Bool?

    let readWriteLock: ReadWriteLock
#if !os(OSX) && !os(watchOS)
    var taskId = UIBackgroundTaskIdentifier.invalid
#endif
    let flushInstance: Flush
    let trackInstance: Track
#if os(iOS) || os(tvOS) || os(visionOS)
    let automaticEvents = AutomaticEvents()
#endif

    convenience init(apiToken: String?,
                     flushInterval: Double,
                     name: String,
                     trackAutomaticEvents: Bool,
                     optOutTrackingByDefault: Bool = false,
                     proxyServerConfig: ProxyServerConfig) {
        self.init(apiToken: apiToken,
                  flushInterval: flushInterval,
                  name: name,
                  trackAutomaticEvents: trackAutomaticEvents,
                  optOutTrackingByDefault: optOutTrackingByDefault,
                  serverURL: proxyServerConfig.serverUrl,
                  proxyServerDelegate: proxyServerConfig.delegate)
    }

    convenience init(apiToken: String?,
                     flushInterval: Double,
                     name: String,
                     trackAutomaticEvents: Bool,
                     optOutTrackingByDefault: Bool = false,
                     serverURL: String? = nil) {
        self.init(apiToken: apiToken,
                  flushInterval: flushInterval,
                  name: name,
                  trackAutomaticEvents: trackAutomaticEvents,
                  optOutTrackingByDefault: optOutTrackingByDefault,
                  serverURL: serverURL,
                  proxyServerDelegate: nil)
    }

    private init(apiToken: String?,
                 flushInterval: Double,
                 name: String,
                 trackAutomaticEvents: Bool,
                 optOutTrackingByDefault: Bool = false,
                 serverURL: String? = nil,
                 proxyServerDelegate: OursPrivacyProxyServerDelegate? = nil) {
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

        oursprivacyPersistence = OursPrivacyPersistence(instanceName: name)
        oursprivacyPersistence.wipeLegacyStateIfNeeded()

        readWriteLock = ReadWriteLock(label: "com.oursprivacy.globallock")
        flushInstance = Flush(serverURL: self.serverURL)
        trackInstance = Track()
        trackInstance.oursprivacyInstance = self
        flushInstance.delegate = self
        flushInstance.flushInterval = flushInterval

#if !os(watchOS)
        setupListeners()
#endif
        unarchive()

        if optOutTrackingByDefault && (hasOptedOutTracking() || optOutStatus == nil) {
            optOutTracking()
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
#endif

    deinit {
        NotificationCenter.default.removeObserver(self)
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
#endif

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
        if flushOnBackground {
            flush(performFullFlush: true, completion: completionHandler)
        }
    }

    @objc private func applicationWillEnterForeground(_ notification: Notification) {
        guard let sharedApplication = OursPrivacyInstance.sharedUIApplication() else {
            return
        }
        if taskId != UIBackgroundTaskIdentifier.invalid {
            sharedApplication.endBackgroundTask(taskId)
            taskId = UIBackgroundTaskIdentifier.invalid
#if os(iOS)
            self.updateNetworkActivityIndicator(false)
#endif
        }
    }
#endif

#if os(iOS)
    func updateNetworkActivityIndicator(_ on: Bool) {
        if showNetworkActivityIndicator {
            DispatchQueue.main.async { [on] in
                OursPrivacyInstance.sharedUIApplication()?.isNetworkActivityIndicatorVisible = on
            }
        }
    }
#endif

    private func newVisitorId() -> String {
        return UUID().uuidString
    }

    func currentEventContext() -> EventContext {
        var visitorIdSnapshot = ""
        var defaultEventSnapshot: InternalProperties = [:]
        var customSnapshot: InternalProperties = [:]
        var consentSnapshot: InternalProperties = [:]
        var attributionSnapshot: InternalProperties = [:]
        readWriteLock.read {
            visitorIdSnapshot = visitorId
            defaultEventSnapshot = defaultEventProperties
            customSnapshot = userCustomProperties
            consentSnapshot = userConsentProperties
            attributionSnapshot = attributionDefaultProperties
        }
        return EventContext(visitorId: visitorIdSnapshot,
                            defaultEventProperties: defaultEventSnapshot,
                            userCustomProperties: customSnapshot,
                            userConsentProperties: consentSnapshot,
                            attributionDefaultProperties: attributionSnapshot)
    }
}

extension OursPrivacyInstance {
    // MARK: - Identity

    /// Identifies the current visitor with an external ID. Equivalent to RN's
    /// `identify(externalId, userProperties)` (see `oursprivacy-main.js:185`).
    ///
    /// Fires a single `$identify` event through the canonical wire shape with
    /// `userProperties.external_id = distinctId` merged in alongside any
    /// caller-provided typed user properties.
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
        trackingQueue.async { [weak self, distinctId, userProperties, completion] in
            guard let self = self else { return }
            let context = self.currentEventContext()
            let item = self.trackInstance.composeIdentifyEvent(distinctId: distinctId,
                                                               userProperties: userProperties,
                                                               context: context)
            self.oursprivacyPersistence.saveEntity(item, type: .events)
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
        }

        if OursPrivacyInstance.isiOSAppExtension() {
            flush()
        }
    }

    /// Clears the visitor identity, the typed user bags, and the local event
    /// queue. The next track call gets a fresh `visitor_id`.
    public func reset(completion: (() -> Void)? = nil) {
        flush()
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            OursPrivacyPersistence.deleteUserDefaultsData(instanceName: self.name)
            self.readWriteLock.write {
                self.visitorId = self.newVisitorId()
                self.isManuallySetId = false
                self.defaultEventProperties = [:]
                self.userCustomProperties = [:]
                self.userConsentProperties = [:]
                self.attributionDefaultProperties = [:]
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
        readWriteLock.read {
            OursPrivacyPersistence.saveIdentity(
                OursPrivacyIdentity(visitorId: visitorId, isManuallySetId: isManuallySetId),
                instanceName: self.name)
        }
    }

    func unarchive() {
        readWriteLock.write {
            optOutStatus = OursPrivacyPersistence.loadOptOutStatusFlag(instanceName: self.name)
            let identity = OursPrivacyPersistence.loadIdentity(instanceName: self.name)
            visitorId = identity.visitorId
            isManuallySetId = identity.isManuallySetId
            if visitorId.isEmpty {
                visitorId = newVisitorId()
            }
        }
        readWriteLock.read {
            OursPrivacyPersistence.saveIdentity(
                OursPrivacyIdentity(visitorId: visitorId, isManuallySetId: isManuallySetId),
                instanceName: self.name)
        }
    }
}

extension OursPrivacyInstance {
    // MARK: - Flush

    /// Drains the local event queue to `/ingest`. The flush timer (`flushInterval`)
    /// and the background hook also call this; the host rarely needs to.
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
            let eventQueue = self.oursprivacyPersistence.loadEntitiesInBatch(
                type: .events,
                batchSize: performFullFlush ? Int.max : self.flushBatchSize,
                excludeAutomaticEvents: !self.trackAutomaticEventsEnabled
            )
            self.networkQueue.async { [weak self, completion] in
                guard let self = self else {
                    if let completion = completion {
                        DispatchQueue.main.async(execute: completion)
                    }
                    return
                }
                self.flushQueue(eventQueue, type: .events)
                if let completion = completion {
                    DispatchQueue.main.async(execute: completion)
                }
            }
        }
    }

    func flushQueue(_ queue: Queue, type: FlushType) {
        if hasOptedOutTracking() {
            return
        }
        let proxyServerResource = proxyServerDelegate?.oursprivacyResourceForProxyServer(name)
        let headers: [String: String] = proxyServerResource?.headers ?? [:]
        let queryItems = proxyServerResource?.queryItems ?? []
        flushInstance.flushQueue(queue, type: type, headers: headers, queryItems: queryItems)
    }

    func flushSuccess(type: FlushType, ids: [Int32]) {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            self.oursprivacyPersistence.removeEntitiesInBatch(type: .events, ids: ids)
        }
    }

    func flushEnvelopeContext() -> (token: String, isManuallySetId: Bool) {
        var manualSnapshot = false
        readWriteLock.read {
            manualSnapshot = self.isManuallySetId
        }
        return (apiToken, manualSnapshot)
    }
}

extension OursPrivacyInstance {
    // MARK: - Track

    /// Records an event. `properties` becomes `eventProperties` on the wire
    /// (after merging the store-level `defaultEventProperties`). `userProperties`
    /// is per-call only — not sticky across subsequent tracks (server stitches
    /// by `visitor_id`).
    public func track(event: String?, properties: Properties? = nil, userProperties: Properties? = nil) {
        OursPrivacyLogger.debug(message: "Tracking \(event ?? "nil")")
        trackingQueue.async { [weak self, event, properties, userProperties] in
            guard let self = self else { return }
            if self.hasOptedOutTracking() {
                return
            }
            let context = self.currentEventContext()
            let item = self.trackInstance.composeTrackEvent(event: event,
                                                            eventProperties: properties,
                                                            userProperties: userProperties,
                                                            context: context)
            if item.isEmpty { return }
            self.oursprivacyPersistence.saveEntity(item, type: .events)
        }

        if OursPrivacyInstance.isiOSAppExtension() {
            flush()
        }
    }
}

extension OursPrivacyInstance {
    // MARK: - Opt-out

    /// Stops all tracking. Pending events are dropped; `visitor_id` is regenerated.
    public func optOutTracking() {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            self.readWriteLock.write {
                self.visitorId = self.newVisitorId()
                self.isManuallySetId = false
                self.defaultEventProperties = [:]
                self.userCustomProperties = [:]
                self.userConsentProperties = [:]
                self.attributionDefaultProperties = [:]
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

    /// Re-enables tracking for an opted-out visitor and fires `$opt_in`. If a
    /// `distinctId` is supplied, identifies the visitor in the same flow.
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

    public func hasOptedOutTracking() -> Bool {
        var optOutStatusShadow: Bool?
        readWriteLock.read {
            optOutStatusShadow = optOutStatus
        }
        return optOutStatusShadow ?? false
    }

    // MARK: - AEDelegate
    func increment(property: String, by: Double) {
        // People profile increments are no longer supported — Wave 3.
    }

    func setOnce(properties: Properties) {
        // People profile setOnce is no longer supported — Wave 3.
    }
}
