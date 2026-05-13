//
//  OursPrivacyInstance.swift
//  OursPrivacy
//
//  Copyright © 2026 Ours Wellness Inc. All rights reserved.
//

import Foundation
#if !os(OSX)
import UIKit
#else
import Cocoa
#endif

/// Delegate for proxy-server resource resolution. The SDK asks the host for
/// headers / query items per request when a proxy is configured.
public protocol OursPrivacyProxyServerDelegate: AnyObject {
    func oursprivacyResourceForProxyServer(_ name: String) -> ServerProxyResource?
}

/// Delegate that can veto a flush attempt. Useful for hosts that gate
/// network activity on radio state, foreground/background, etc.
public protocol OursPrivacyDelegate: AnyObject {
    func oursprivacyWillFlush(_ oursprivacy: OursPrivacy) -> Bool
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

/// The SDK entry point. Construct a single instance per project token and
/// hold the reference for the lifetime of the app. The public surface
/// mirrors the React Native SDK so cross-platform integrations share a
/// vocabulary.
///
/// ```swift
/// let op = OursPrivacy(token: "TOKEN", trackAutomaticEvents: true)
/// await op.initialize()
/// op.identify(OursPrivacyUserProperties(email: "u@example.com",
///                                       externalId: "user-123"))
/// op.track(event: "Sign Up")
/// ```
open class OursPrivacy: CustomDebugStringConvertible, FlushDelegate, AEDelegate {

    /// The project token. Set at construction.
    open var apiToken = ""

    /// Optional delegate that can veto a flush attempt.
    open weak var delegate: OursPrivacyDelegate?

    /// Stable per-install identifier sent as `visitor_id` on every event.
    /// Generated lazily on first launch and persisted in NSUserDefaults
    /// under the OursPrivacy suite. Reset by ``reset(completion:)``.
    open internal(set) var visitorId: String = ""

    /// True only when the host explicitly called ``setVisitorId(_:)``.
    /// Forwarded as the top-level `is_manually_set_id` envelope field.
    open internal(set) var isManuallySetId: Bool = false

    let oursprivacyPersistence: OursPrivacyPersistence

    /// Show the network activity indicator while flushing. iOS-only.
    open var showNetworkActivityIndicator = true

    /// Enables automatic-event tracking. Forwarded to `AutomaticEvents`.
    open var trackAutomaticEventsEnabled: Bool

    /// Flush timer interval (seconds). 0 disables auto-flush; the host
    /// calls ``flush(performFullFlush:completion:)`` manually.
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

    /// Toggles SDK logging at runtime. Off by default. Prefer
    /// ``setLoggingEnabled(_:)`` for the method-style API.
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

    /// Instance name (defaults to the API token). Identifies the
    /// per-token NSUserDefaults suite used for persistence.
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

    // Default-properties bags. Populated by the public setters below.
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

    /// Construct a new SDK instance bound to `token`. Call
    /// ``initialize(options:)`` immediately after to
    /// apply boot-time options and start the flush timer.
    ///
    /// `trackAutomaticEvents` is ignored on watchOS / macOS where automatic
    /// events aren't supported.
    public convenience init(token: String, trackAutomaticEvents: Bool) {
        self.init(apiToken: token,
                  flushInterval: 60,
                  name: token,
                  trackAutomaticEvents: trackAutomaticEvents,
                  optOutTrackingByDefault: false,
                  serverURL: nil,
                  proxyServerDelegate: nil,
                  startFlushTimer: false)
    }

    /// Construct a new SDK instance bound to `token` with a custom proxy
    /// configuration. Call
    /// ``initialize(options:)`` immediately after.
    public convenience init(token: String, trackAutomaticEvents: Bool, proxyServerConfig: ProxyServerConfig) {
        self.init(apiToken: token,
                  flushInterval: 60,
                  name: token,
                  trackAutomaticEvents: trackAutomaticEvents,
                  optOutTrackingByDefault: false,
                  serverURL: proxyServerConfig.serverUrl,
                  proxyServerDelegate: proxyServerConfig.delegate,
                  startFlushTimer: false)
    }

    private init(apiToken: String?,
                 flushInterval: Double,
                 name: String,
                 trackAutomaticEvents: Bool,
                 optOutTrackingByDefault: Bool = false,
                 serverURL: String? = nil,
                 proxyServerDelegate: OursPrivacyProxyServerDelegate? = nil,
                 startFlushTimer: Bool = true) {
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
        if startFlushTimer {
            flushInstance.flushInterval = flushInterval
        } else {
            // Set the interval without triggering the timer; the host kicks
            // it off via ``initialize(options:)``.
            flushInstance._flushInterval = flushInterval
        }

#if !os(watchOS)
        setupListeners()
#endif
        unarchive()

        if optOutTrackingByDefault && (hasOptedOutTracking() || optOutStatus == nil) {
            optOutTracking()
        }

#if os(iOS) || os(tvOS) || os(visionOS)
        if !OursPrivacy.isiOSAppExtension() && trackAutomaticEvents {
            automaticEvents.delegate = self
            automaticEvents.initializeEvents(instanceName: self.name)
        }
#endif
    }

#if !os(OSX) && !os(watchOS)
    private func setupListeners() {
        let notificationCenter = NotificationCenter.default
        if !OursPrivacy.isiOSAppExtension() {
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
        guard let sharedApplication = OursPrivacy.sharedUIApplication() else {
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
        guard let sharedApplication = OursPrivacy.sharedUIApplication() else {
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
                OursPrivacy.sharedUIApplication()?.isNetworkActivityIndicatorVisible = on
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

    func archive() {
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

extension OursPrivacy {
    // MARK: - Boot

    /// Apply boot-time options and start the flush timer. Call once,
    /// immediately after construction, before any `identify` / `track` call.
    ///
    /// `options` carries optional overrides: server URL, manually-set
    /// visitor ID, deep-link URL to parse for attribution at boot, default
    /// property bags merged into every subsequent event, and
    /// ``OursPrivacyInitOptions/optedOutByDefault`` to opt the visitor out
    /// on first launch (only when no persisted opt-in / opt-out decision
    /// exists).
    public func initialize(options: OursPrivacyInitOptions? = nil) async {
        if let serverURL = options?.serverURL {
            self.serverURL = serverURL
        }
        if let visitorId = options?.visitorId, !visitorId.isEmpty {
            setVisitorId(visitorId)
        }
        if let defaults = options?.defaultEventProperties {
            updateDefaultEventProperties(defaults)
        }
        if let defaults = options?.defaultUserCustomProperties {
            updateDefaultUserCustomProperties(defaults)
        }
        if let defaults = options?.defaultUserConsentProperties {
            updateDefaultUserConsentProperties(defaults)
        }
        if let initialURL = options?.initialURL, !initialURL.isEmpty {
            trackDeepLink(initialURL)
        }
        if options?.optedOutByDefault == true && optOutStatus == nil {
            optOutTracking()
            await withCheckedContinuation { cont in
                trackingQueue.async { cont.resume() }
            }
        }
        // Kick the flush timer using whatever interval the host has set.
        flushInstance.flushInterval = flushInstance.flushInterval
    }
}

extension OursPrivacy {
    // MARK: - Identity

    /// Returns the current visitor ID, or `nil` if the SDK hasn't generated
    /// one yet (the typical case is before the first `identify` / `track`).
    public func getVisitorId() -> String? {
        var current = ""
        readWriteLock.read { current = visitorId }
        return current.isEmpty ? nil : current
    }

    /// Override the visitor ID with a host-supplied value. Flips
    /// ``isManuallySetId`` to true so the envelope's `is_manually_set_id`
    /// flag tells the server this visitor came from a stitched identity
    /// (e.g. a web → app deep link).
    public func setVisitorId(_ visitorId: String) {
        guard !visitorId.isEmpty else {
            OursPrivacyLogger.error(message: "setVisitorId called with empty string — ignoring")
            return
        }
        readWriteLock.write {
            self.visitorId = visitorId
            self.isManuallySetId = true
        }
        archive()
    }

    /// Identify the current visitor. Fires a single `$identify` event
    /// carrying the visitor's typed user properties. To stitch the visitor
    /// to an external system, set ``OursPrivacyUserProperties/externalId``
    /// on the struct — it serializes as `external_id` on the wire.
    public func identify(_ userProperties: OursPrivacyUserProperties? = nil,
                         completion: (() -> Void)? = nil) {
        if hasOptedOutTracking() {
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }
        let wireProps = userProperties?.toWireProperties()
        trackingQueue.async { [weak self, wireProps, completion] in
            guard let self = self else { return }
            let context = self.currentEventContext()
            let item = self.trackInstance.composeIdentifyEvent(userProperties: wireProps,
                                                               context: context)
            self.oursprivacyPersistence.saveEntity(item, type: .events)
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
        }

        if OursPrivacy.isiOSAppExtension() {
            flush()
        }
    }

    /// Clears the visitor identity, the typed user bags, and the local
    /// event queue. The next event gets a fresh `visitor_id`.
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

extension OursPrivacy {
    // MARK: - Default properties

    /// Merge `properties` into the store-level default event properties.
    /// Subsequent `track` calls receive these keys on every event under
    /// `eventProperties` (per-call values win on collision).
    public func updateDefaultEventProperties(_ properties: [String: OursPrivacyType]) {
        readWriteLock.write {
            for (k, v) in properties { defaultEventProperties[k] = v }
        }
    }

    /// Merge `properties` into the store-level default
    /// `userProperties.custom_properties`. Subsequent `identify` and
    /// `track` calls carry these defaults under nested `custom_properties`.
    public func updateDefaultUserCustomProperties(_ properties: [String: OursPrivacyType]) {
        readWriteLock.write {
            for (k, v) in properties { userCustomProperties[k] = v }
        }
    }

    /// Merge `properties` into the store-level default
    /// `userProperties.consent`. Subsequent `identify` and `track` calls
    /// carry these defaults under nested `consent`.
    public func updateDefaultUserConsentProperties(_ properties: [String: OursPrivacyType]) {
        readWriteLock.write {
            for (k, v) in properties { userConsentProperties[k] = v }
        }
    }

    /// Method-style toggle for SDK logging. Equivalent to setting
    /// ``loggingEnabled``.
    public func setLoggingEnabled(_ enabled: Bool) {
        loggingEnabled = enabled
    }
}

extension OursPrivacy {
    // MARK: - Deep links

    /// Parse a deep-link URL for marketing attribution and record a
    /// `$deep_link_opened` event with the raw URL.
    ///
    /// UTM parameters and ad-network click IDs are extracted and stored as
    /// store-level attribution defaults — every subsequent event sends them
    /// under `defaultProperties`. Calling `trackDeepLink` again **replaces**
    /// the prior attribution (rather than merging) so stale UTM keys from
    /// an earlier link don't leak into events triggered by a later one.
    ///
    /// If the URL carries an `ours_visitor_id` parameter, the SDK calls
    /// ``setVisitorId(_:)`` so cross-platform sessions stitch to the same
    /// visitor.
    public func trackDeepLink(_ url: String) {
        guard !url.isEmpty else {
            OursPrivacyLogger.info(message: "trackDeepLink called with empty URL, skipping")
            return
        }
        if hasOptedOutTracking() {
            OursPrivacyLogger.info(message: "trackDeepLink skipped: visitor is opted out")
            return
        }

        let attribution = parseAttributionFromURL(url)
        if let stitched = attribution.oursVisitorId {
            setVisitorId(stitched)
        }
        var combined: InternalProperties = [:]
        if let utms = attribution.utmParams {
            for (k, v) in utms { combined[k] = v }
        }
        if let clickIds = attribution.clickIds {
            for (k, v) in clickIds { combined[k] = v }
        }
        readWriteLock.write {
            attributionDefaultProperties = combined
        }

        track(event: "$deep_link_opened",
              properties: ["url": attribution.rawURL])
    }
}

extension OursPrivacy {
    // MARK: - Flush

    /// Drains the local event queue to `/ingest`. The flush timer and the
    /// background hook also call this; the host rarely needs to.
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

extension OursPrivacy {
    // MARK: - Track

    /// Record an event. `properties` becomes `eventProperties` on the wire
    /// (after merging the store-level default event properties).
    /// `userProperties` is per-call only — not sticky across subsequent
    /// tracks (server stitches by `visitor_id`).
    public func track(event: String?,
                      properties: Properties? = nil,
                      userProperties: OursPrivacyUserProperties? = nil) {
        trackUntyped(event: event,
                     properties: properties,
                     userProperties: userProperties?.toWireProperties())
    }

    /// Internal entry point used by AutomaticEvents and the typed
    /// ``track(event:properties:userProperties:)`` overload. Accepts the
    /// untyped per-call userProperties dict the composer consumes.
    func trackUntyped(event: String?,
                      properties: Properties? = nil,
                      userProperties: Properties? = nil) {
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

        if OursPrivacy.isiOSAppExtension() {
            flush()
        }
    }
}

extension OursPrivacy {
    // MARK: - Opt-out

    /// Stops all tracking. Pending events are dropped; `visitor_id` is
    /// regenerated; the local event queue is cleared.
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
            self.oursprivacyPersistence.resetEntities()
            self.archive()
            self.readWriteLock.write {
                self.optOutStatus = true
            }
            self.readWriteLock.read {
                OursPrivacyPersistence.saveOptOutStatusFlag(value: self.optOutStatus!, instanceName: self.name)
            }
        }
    }

    /// Re-enable tracking for an opted-out visitor and fire `$opt_in`. If
    /// `userProperties` is supplied, identify the visitor in the same flow.
    public func optInTracking(userProperties: OursPrivacyUserProperties? = nil,
                              properties: Properties? = nil) {
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            self.readWriteLock.write {
                self.optOutStatus = false
            }
            self.readWriteLock.read {
                OursPrivacyPersistence.saveOptOutStatusFlag(value: self.optOutStatus!, instanceName: self.name)
            }
            if let userProperties = userProperties {
                self.identify(userProperties)
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

    func track(event: String?, properties: Properties?, userProperties: Properties?) {
        trackUntyped(event: event, properties: properties, userProperties: userProperties)
    }

    func increment(property: String, by: Double) {
        // People profile increments are not supported.
    }

    func setOnce(properties: Properties) {
        // People profile setOnce is not supported.
    }
}
