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

private struct PropertySnapshot: Sendable {
    let data: Data?

    init(_ properties: Properties?) {
        assertPropertyTypes(properties)
        data = properties.flatMap { JSONHandler.serializeJSONObject($0) }
    }

    func decode() -> Properties? {
        guard let data, let raw = JSONHandler.deserializeData(data) as? [String: Any] else { return nil }
        var properties: Properties = [:]
        for (key, value) in raw {
            guard let property = Self.decodeValue(value) else { return nil }
            properties[key] = property
        }
        return properties
    }

    private static func decodeValue(_ value: Any) -> OursPrivacyType? {
        if let dictionary = value as? [String: Any] {
            var decoded: Properties = [:]
            for (key, nested) in dictionary {
                guard let property = decodeValue(nested) else { return nil }
                decoded[key] = property
            }
            return decoded
        }
        if let array = value as? [Any] {
            var decoded: [OursPrivacyType] = []
            for nested in array {
                guard let property = decodeValue(nested) else { return nil }
                decoded.append(property)
            }
            return decoded
        }
        return value as? OursPrivacyType
    }
}

// Persisted events are freshly decoded values that the SDK alone owns.
private struct PersistedEventTransfer: @unchecked Sendable {
    let value: Queue
}

private struct PendingTrackingItem {
    let event: InternalProperties
    let completion: (@Sendable () -> Void)?
}

protocol AppLifecycle {
    func applicationDidBecomeActive()
    func applicationWillResignActive()
}

private enum MobileAppState {
    case unknown
    case active
    case inactive
    case background
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
/// hold the reference for the lifetime of the app. The public surface is
/// aligned across the Ours Privacy SDKs so cross-platform integrations
/// share a vocabulary.
/// Queued event state and identity snapshots use queues and locks.
/// Configure mutable public options before concurrent tracking.
///
/// ```swift
/// let op = OursPrivacy(token: "TOKEN", trackAutomaticEvents: true)
/// await op.initialize()
/// op.identify(OursPrivacyUserProperties(email: "u@example.com",
///                                       externalId: "user-123"))
/// op.track(event: "Sign Up")
/// ```
open class OursPrivacy: CustomDebugStringConvertible, FlushDelegate, AEDelegate, @unchecked Sendable {

    /// The project token. Set at construction.
    open var apiToken = ""

    /// Optional delegate that can veto a flush attempt.
    open weak var delegate: OursPrivacyDelegate?

    /// Called on the network queue after an indexed rejection leaves durable storage.
    /// Receives only the event's `distinct_id` and a code, without event properties.
    open var onIngestRejected: (@Sendable (String, String) -> Void)? {
        get {
            var callback: (@Sendable (String, String) -> Void)?
            readWriteLock.read { callback = _onIngestRejected }
            return callback
        }
        set { readWriteLock.write { _onIngestRejected = newValue } }
    }
    private var _onIngestRejected: (@Sendable (String, String) -> Void)?

    /// Stable per-install identifier sent as `visitor_id` on every event.
    /// Generated lazily on first launch and persisted in NSUserDefaults
    /// under the OursPrivacy suite. Reset by ``reset(completion:)``.
    open internal(set) var visitorId: String {
        get {
            var value = ""
            readWriteLock.read { value = _visitorId }
            return value
        }
        set { readWriteLock.write { _visitorId = newValue } }
    }
    private var _visitorId = ""

    /// True only when the host explicitly called ``setVisitorId(_:)``.
    /// Forwarded as the top-level `is_manually_set_id` envelope field.
    open internal(set) var isManuallySetId: Bool {
        get {
            var value = false
            readWriteLock.read { value = _isManuallySetId }
            return value
        }
        set { readWriteLock.write { _isManuallySetId = newValue } }
    }
    private var _isManuallySetId = false

    let oursprivacyPersistence: OursPrivacyPersistence

    /// Enables automatic-event tracking. Forwarded to `AutomaticEvents`.
    open var trackAutomaticEventsEnabled: Bool

    /// Enables legacy StoreKit `$ae_iap` collection. Defaults to false.
    open internal(set) var trackAutomaticPurchasesEnabled: Bool

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
    open weak var proxyServerDelegate: OursPrivacyProxyServerDelegate?

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
    var mobileSession: MobileSession?
    var mobileRuntimeEnabled: Bool
    var captureMobileTime: @Sendable () -> MobileTimePoint = { MobileTimePoint.capture() }
    var mobileQueueNowMs: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    var mobileCheckpointIntervalMs = 10_000
    var mobilePendingRetryIntervalMs = 10_000
    private let trackingQueueKey = DispatchSpecificKey<Bool>()
    private var mobileLifecycleReady = false
    private var mobileAppState = MobileAppState.unknown
    private var deferredMobileForeground: MobileTimePoint?
    private var mobileCheckpointTimer: DispatchSourceTimer?
    private var mobilePendingRetryTimer: DispatchSourceTimer?
    private var pendingTrackingItems: [PendingTrackingItem] = []

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
    public convenience init(token: String, trackAutomaticEvents: Bool,
                            trackAutomaticPurchases: Bool = false) {
        self.init(apiToken: token,
                  flushInterval: 10,
                  name: token,
                  trackAutomaticEvents: trackAutomaticEvents,
                  trackAutomaticPurchases: trackAutomaticPurchases,
                  optOutTrackingByDefault: false,
                  serverURL: nil,
                  proxyServerDelegate: nil,
                  startFlushTimer: false)
    }

    /// Construct a new SDK instance bound to `token` with a custom proxy
    /// configuration. Call
    /// ``initialize(options:)`` immediately after.
    public convenience init(token: String, trackAutomaticEvents: Bool,
                            trackAutomaticPurchases: Bool = false,
                            proxyServerConfig: ProxyServerConfig) {
        self.init(apiToken: token,
                  flushInterval: 10,
                  name: token,
                  trackAutomaticEvents: trackAutomaticEvents,
                  trackAutomaticPurchases: trackAutomaticPurchases,
                  optOutTrackingByDefault: false,
                  serverURL: proxyServerConfig.serverUrl,
                  proxyServerDelegate: proxyServerConfig.delegate,
                  startFlushTimer: false)
    }

    private init(apiToken: String?,
                 flushInterval: Double,
                 name: String,
                 trackAutomaticEvents: Bool,
                 trackAutomaticPurchases: Bool,
                 optOutTrackingByDefault: Bool = false,
                 serverURL: String? = nil,
                 proxyServerDelegate: OursPrivacyProxyServerDelegate? = nil,
                 startFlushTimer: Bool = true) {
        if let apiToken = apiToken, !apiToken.isEmpty {
            self.apiToken = apiToken
        }
        trackAutomaticEventsEnabled = trackAutomaticEvents
        trackAutomaticPurchasesEnabled = trackAutomaticPurchases
        if let serverURL = serverURL {
            self.serverURL = serverURL
        }
        self.proxyServerDelegate = proxyServerDelegate
        let label = "com.oursprivacy.\(self.apiToken)"
        trackingQueue = DispatchQueue(label: "\(label).tracking)", qos: .utility, autoreleaseFrequency: .workItem)
        networkQueue = DispatchQueue(label: "\(label).network)", qos: .utility, autoreleaseFrequency: .workItem)
        trackingQueue.setSpecific(key: trackingQueueKey, value: true)
        self.name = name
        #if os(iOS) && !targetEnvironment(macCatalyst)
            mobileRuntimeEnabled = !OursPrivacy.isiOSAppExtension() && !AutomaticProperties.isiOSAppOnMac()
        #else
            mobileRuntimeEnabled = false
        #endif

        oursprivacyPersistence = OursPrivacyPersistence(instanceName: name)
        oursprivacyPersistence.wipeLegacyStateIfNeeded()
        if mobileRuntimeEnabled {
            mobileSession = MobileSession(instanceName: name)
        }

        readWriteLock = ReadWriteLock(label: "com.oursprivacy.globallock")
        flushInstance = Flush(serverURL: self.serverURL)
        trackInstance = Track()
        trackInstance.oursprivacyInstance = self
#if os(iOS) || os(tvOS) || os(visionOS)
        AutomaticProperties.prepareUIProperties(beforeProcessing: trackingQueue)
#endif
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
            automaticEvents.registerLifecycleListeners()
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
        mobileCheckpointTimer?.cancel()
        mobilePendingRetryTimer?.cancel()
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
        if mobileRuntimeEnabled {
            mobileForeground(at: captureMobileTime())
        }
        flushInstance.applicationDidBecomeActive()
    }

    @objc private func applicationWillResignActive(_ notification: Notification) {
        if mobileRuntimeEnabled {
            mobilePause(at: captureMobileTime())
        }
        flushInstance.applicationWillResignActive()
#if os(OSX)
        if flushOnBackground {
            flushAutomatically()
        }
#endif
    }

#if !os(OSX) && !os(watchOS)
    @objc private func applicationDidEnterBackground(_ notification: Notification) {
        if mobileRuntimeEnabled {
            mobileBackground(at: captureMobileTime())
        }
        guard let sharedApplication = OursPrivacy.sharedUIApplication() else {
            return
        }
        if hasOptedOutTracking() {
            return
        }
        let completionHandler: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let application = OursPrivacy.sharedUIApplication() else { return }
                if self.taskId != UIBackgroundTaskIdentifier.invalid {
                    application.endBackgroundTask(self.taskId)
                    self.taskId = UIBackgroundTaskIdentifier.invalid
                }
            }
        }
        taskId = sharedApplication.beginBackgroundTask(expirationHandler: completionHandler)
        if flushOnBackground {
            flushAutomatically(performFullFlush: true, completion: completionHandler)
        }
    }

    @objc private func applicationWillEnterForeground(_ notification: Notification) {
        guard let sharedApplication = OursPrivacy.sharedUIApplication() else {
            return
        }
        if taskId != UIBackgroundTaskIdentifier.invalid {
            sharedApplication.endBackgroundTask(taskId)
            taskId = UIBackgroundTaskIdentifier.invalid
        }
    }
#endif

    private func newVisitorId() -> String {
        return UUID().uuidString
    }

    func currentEventContext(at point: MobileTimePoint = MobileTimePoint.capture()) -> EventContext {
        var visitorIdSnapshot = ""
        var defaultEventSnapshot: InternalProperties = [:]
        var customSnapshot: InternalProperties = [:]
        var consentSnapshot: InternalProperties = [:]
        var attributionSnapshot: InternalProperties = [:]
        readWriteLock.read {
            visitorIdSnapshot = _visitorId
            defaultEventSnapshot = defaultEventProperties
            customSnapshot = userCustomProperties
            consentSnapshot = userConsentProperties
            attributionSnapshot = attributionDefaultProperties
        }
        let snapshot = mobileRuntimeEnabled
            ? mobileSession?.snapshot(visitorId: visitorIdSnapshot,
                                      appVersion: AutomaticProperties.appVersion,
                                      appBuild: AutomaticProperties.appBuild, at: point)
            : nil
        return EventContext(visitorId: visitorIdSnapshot,
                            defaultEventProperties: defaultEventSnapshot,
                            userCustomProperties: customSnapshot,
                            userConsentProperties: consentSnapshot,
                            attributionDefaultProperties: attributionSnapshot,
                            mobileSnapshot: snapshot)
    }

    private func queuePendingMobileFacts() {
        defer { drainPendingTrackingItems() }
        guard mobileRuntimeEnabled, !hasOptedOutTracking(),
              !oursprivacyPersistence.hasPendingPrivacyClear, let mobileSession else { return }
        let queued = oursprivacyPersistence.loadEntitiesInBatch(type: .events)
        let queuedIds = Set(queued.compactMap { $0["distinct_id"] as? String })
        mobileSession.acknowledgeQueuedFacts(queuedIds,
                                             firstOpenQueueEvidence: oursprivacyPersistence.hasFirstOpenQueueEvidence)
        var retryDelayMs: Int64?
        for fact in mobileSession.pendingFacts {
            let now = mobileQueueNowMs()
            if fact.occurredAtMs > now {
                let delay = min(fact.occurredAtMs - now, Int64(max(1, mobilePendingRetryIntervalMs)))
                retryDelayMs = min(retryDelayMs ?? delay, delay)
                if fact.name == "$mobile_first_open" { break }
                continue
            }
            let item = trackInstance.composeMobileFact(fact)
            let saved = oursprivacyPersistence.saveEntity(item, type: .events,
                                                            firstOpen: fact.name == "$mobile_first_open")
            if saved {
                mobileSession.acknowledgeQueuedFacts([fact.distinctId],
                    firstOpenQueueEvidence: oursprivacyPersistence.hasFirstOpenQueueEvidence)
            } else {
                let delay = Int64(max(1, mobilePendingRetryIntervalMs))
                retryDelayMs = min(retryDelayMs ?? delay, delay)
                break
            }
        }
        if let retryDelayMs {
            scheduleMobilePendingRetry(after: Int(clamping: retryDelayMs))
        } else {
            mobilePendingRetryTimer?.cancel()
            mobilePendingRetryTimer = nil
        }
    }

    private func drainPendingTrackingItems() {
        guard !pendingTrackingItems.isEmpty, !hasOptedOutTracking(),
              !oursprivacyPersistence.hasPendingPrivacyClear else { return }
        let now = mobileQueueNowMs()
        let dueOpenPending = mobileSession?.pendingFacts.contains {
            ["$mobile_first_open", "$mobile_app_open", "$mobile_session_start"].contains($0.name) &&
                $0.occurredAtMs <= now
        } ?? false
        guard !dueOpenPending else { return }

        while let pending = pendingTrackingItems.first {
            guard oursprivacyPersistence.saveEntity(pending.event, type: .events) else {
                scheduleMobilePendingRetry(after: max(1, mobilePendingRetryIntervalMs))
                return
            }
            pendingTrackingItems.removeFirst()
            if let completion = pending.completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    private func scheduleMobilePendingRetry(after milliseconds: Int) {
        guard mobilePendingRetryTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: trackingQueue)
        timer.schedule(deadline: .now() + .milliseconds(milliseconds))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.mobilePendingRetryTimer?.cancel()
            self.mobilePendingRetryTimer = nil
            self.queuePendingMobileFacts()
        }
        mobilePendingRetryTimer = timer
        timer.resume()
    }

    func mobileForeground(at point: MobileTimePoint) {
        trackingQueue.async { [weak self] in
            guard let self, self.mobileRuntimeEnabled else { return }
            guard self.mobileLifecycleReady else {
                self.mobileAppState = .active
                if self.deferredMobileForeground == nil {
                    self.deferredMobileForeground = point
                }
                return
            }
            switch self.mobileAppState {
            case .inactive:
                self.mobileAppState = .active
                if !self.hasOptedOutTracking(), self.clearPrivacyQueueIfNeeded(),
                   let mobileSession = self.mobileSession,
                   mobileSession.resumeActive(at: point) {
                    self.queuePendingMobileFacts()
                    if self.trackAutomaticEventsEnabled {
                        self.startMobileCheckpointTimer()
                    }
                } else {
                    self.processMobileForeground(at: point)
                }
            case .background, .unknown:
                self.mobileAppState = .active
                self.processMobileForeground(at: point)
            case .active:
                self.processMobileForeground(at: point)
            }
        }
    }

    private func processMobileForeground(at point: MobileTimePoint) {
        guard !hasOptedOutTracking(), clearPrivacyQueueIfNeeded(), let mobileSession else { return }
        _ = mobileSession.foreground(automaticEnabled: trackAutomaticEventsEnabled,
                                     visitorId: visitorId,
                                     appVersion: AutomaticProperties.appVersion,
                                     appBuild: AutomaticProperties.appBuild, at: point)
        queuePendingMobileFacts()
        if trackAutomaticEventsEnabled {
            startMobileCheckpointTimer()
        }
    }

    private func startMobileCheckpointTimer() {
        guard mobileCheckpointTimer == nil else { return }
        let interval = max(1, mobileCheckpointIntervalMs)
        let remaining = mobileSession?.remainingEngagementThresholdMs ?? Int64(interval)
        let firstInterval = min(interval, Int(clamping: remaining))
        let timer = DispatchSource.makeTimerSource(queue: trackingQueue)
        timer.schedule(deadline: .now() + .milliseconds(firstInterval),
                       repeating: .milliseconds(interval))
        timer.setEventHandler { [weak self] in
            guard let self, !self.hasOptedOutTracking(),
                  self.clearPrivacyQueueIfNeeded(), let mobileSession = self.mobileSession else { return }
            let point = self.captureMobileTime()
            _ = mobileSession.checkpoint(at: point)
            self.queuePendingMobileFacts()
        }
        mobileCheckpointTimer = timer
        timer.resume()
    }

    func mobilePause(at point: MobileTimePoint) {
        trackingQueue.async { [weak self] in
            guard let self, self.mobileRuntimeEnabled,
                  self.mobileAppState != .inactive, self.mobileAppState != .background else { return }
            let wasActive = self.mobileAppState == .active
            self.mobileAppState = .inactive
            self.mobileCheckpointTimer?.cancel()
            self.mobileCheckpointTimer = nil
            guard self.mobileLifecycleReady else {
                self.deferredMobileForeground = nil
                return
            }
            guard wasActive, !self.hasOptedOutTracking(), let mobileSession = self.mobileSession else { return }
            _ = mobileSession.pauseActive(at: point)
            guard self.clearPrivacyQueueIfNeeded() else { return }
            self.queuePendingMobileFacts()
        }
    }

    func mobileBackground(at point: MobileTimePoint) {
        trackingQueue.async { [weak self] in
            guard let self, self.mobileRuntimeEnabled else { return }
            guard self.mobileAppState != .background else { return }
            self.mobileAppState = .background
            self.mobileCheckpointTimer?.cancel()
            self.mobileCheckpointTimer = nil
            guard self.mobileLifecycleReady else {
                self.deferredMobileForeground = nil
                return
            }
            guard !self.hasOptedOutTracking(), let mobileSession = self.mobileSession else { return }
            _ = mobileSession.background(at: point)
            guard self.clearPrivacyQueueIfNeeded() else { return }
            self.queuePendingMobileFacts()
        }
    }

    private func clearPrivacyQueueIfNeeded() -> Bool {
        !oursprivacyPersistence.hasPendingPrivacyClear || oursprivacyPersistence.clearEntitiesForPrivacy()
    }

    func archive() {
        readWriteLock.read {
            OursPrivacyPersistence.saveIdentity(
                OursPrivacyIdentity(visitorId: _visitorId, isManuallySetId: _isManuallySetId),
                instanceName: self.name)
        }
    }

    func unarchive() {
        readWriteLock.write {
            optOutStatus = OursPrivacyPersistence.loadOptOutStatusFlag(instanceName: self.name)
            let identity = OursPrivacyPersistence.loadIdentity(instanceName: self.name)
            _visitorId = identity.visitorId
            _isManuallySetId = identity.isManuallySetId
            if _visitorId.isEmpty {
                _visitorId = newVisitorId()
            }
        }
        readWriteLock.read {
            OursPrivacyPersistence.saveIdentity(
                OursPrivacyIdentity(visitorId: _visitorId, isManuallySetId: _isManuallySetId),
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
        if let callback = options?.onIngestRejected {
            onIngestRejected = callback
        }
        if let trackAutomaticPurchases = options?.trackAutomaticPurchases {
            trackAutomaticPurchasesEnabled = trackAutomaticPurchases
        }
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
        #if os(iOS) || os(tvOS) || os(visionOS)
            if !OursPrivacy.isiOSAppExtension() {
                await MainActor.run {
                    if trackAutomaticEventsEnabled {
                        automaticEvents.initializeEvents(instanceName: name)
                    }
                    if trackAutomaticPurchasesEnabled {
                        automaticEvents.delegate = self
                        if !hasOptedOutTracking() {
                            automaticEvents.registerPurchaseObserver()
                        }
                    }
                }
            }
        #endif
        #if os(iOS)
            let activePoint = await MainActor.run {
                OursPrivacy.sharedUIApplication()?.applicationState == .active
                    ? captureMobileTime() : nil
            }
        #else
            let activePoint: MobileTimePoint? = nil
        #endif
        await withCheckedContinuation { cont in
            trackingQueue.async {
                self.mobileLifecycleReady = true
                if self.mobileRuntimeEnabled {
                    self.queuePendingMobileFacts()
                    if self.mobileAppState == .active, let point = self.deferredMobileForeground {
                        self.processMobileForeground(at: point)
                    } else if self.mobileAppState == .unknown, let point = activePoint {
                        self.mobileAppState = .active
                        self.processMobileForeground(at: point)
                    }
                }
                self.deferredMobileForeground = nil
                cont.resume()
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
        let current = visitorId
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
        let point = captureMobileTime()
        #if os(iOS) || os(tvOS) || os(visionOS)
            AutomaticProperties.primeUIPropertiesIfOnMain()
        #endif
        let update = {
            if self.visitorId != visitorId, self.mobileRuntimeEnabled,
               let mobileSession = self.mobileSession {
                _ = mobileSession.rotate(to: visitorId,
                                         appVersion: AutomaticProperties.appVersion,
                                         appBuild: AutomaticProperties.appBuild, at: point)
                self.queuePendingMobileFacts()
            }
            self.readWriteLock.write {
                self._visitorId = visitorId
                self._isManuallySetId = true
            }
            self.archive()
        }
        if DispatchQueue.getSpecific(key: trackingQueueKey) == true {
            update()
        } else {
            trackingQueue.sync(execute: update)
        }
    }

    /// Identify the current visitor. Fires a single `$identify` event
    /// carrying the visitor's typed user properties. To stitch the visitor
    /// to an external system, set ``OursPrivacyUserProperties/externalId``
    /// on the struct — it serializes as `external_id` on the wire.
    public func identify(_ userProperties: OursPrivacyUserProperties? = nil,
                         completion: (@Sendable () -> Void)? = nil) {
        if hasOptedOutTracking() {
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }
#if os(iOS) || os(tvOS) || os(visionOS)
        AutomaticProperties.primeUIPropertiesIfOnMain()
#endif
        enqueueIdentify(PropertySnapshot(userProperties?.toWireProperties()),
                        at: captureMobileTime(), completion: completion)
    }

    private func enqueueIdentify(_ snapshot: PropertySnapshot, at point: MobileTimePoint,
                                 completion: (@Sendable () -> Void)?) {
        trackingQueue.async { [weak self, snapshot, completion] in
            guard let self = self else { return }
            guard !self.hasOptedOutTracking() else { return }
            guard self.clearPrivacyQueueIfNeeded() else { return }
            let wasHeld = !self.pendingTrackingItems.isEmpty
            self.queuePendingMobileFacts()
            let context = self.currentEventContext(at: point)
            let item = self.trackInstance.composeIdentifyEvent(userProperties: snapshot.decode(),
                                                               context: context)
            if !wasHeld && self.pendingTrackingItems.isEmpty {
                self.oursprivacyPersistence.saveEntity(item, type: .events)
                if let completion {
                    DispatchQueue.main.async(execute: completion)
                }
            } else {
                self.pendingTrackingItems.append(PendingTrackingItem(event: item, completion: completion))
            }
            self.queuePendingMobileFacts()
        }

        if OursPrivacy.isiOSAppExtension() {
            flushAutomatically()
        }
    }

    /// Clears the visitor identity, the typed user bags, and the local
    /// event queue. The next event gets a fresh `visitor_id`.
    public func reset(completion: (@Sendable () -> Void)? = nil) {
        let point = captureMobileTime()
        trackingQueue.async { [weak self] in
            guard let self = self else { return }
            self.mobilePendingRetryTimer?.cancel()
            self.mobilePendingRetryTimer = nil
            self.pendingTrackingItems.removeAll()
            let nextVisitorId = self.newVisitorId()
            if self.mobileRuntimeEnabled, let mobileSession = self.mobileSession {
                _ = mobileSession.rotate(to: nextVisitorId,
                                         appVersion: AutomaticProperties.appVersion,
                                         appBuild: AutomaticProperties.appBuild, at: point)
                mobileSession.discardPendingFacts()
            }
            _ = self.oursprivacyPersistence.clearEntitiesForPrivacy()
            OursPrivacyPersistence.deleteUserDefaultsData(instanceName: self.name,
                                                           preserveEventQueue: true)
            self.readWriteLock.write {
                self._visitorId = nextVisitorId
                self._isManuallySetId = false
                self.defaultEventProperties = [:]
                self.userCustomProperties = [:]
                self.userConsentProperties = [:]
                self.attributionDefaultProperties = [:]
            }
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
    /// `$deep_link_opened` event without the raw URL.
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

        track(event: "$deep_link_opened", properties: nil)
    }
}

extension OursPrivacy {
    // MARK: - Flush

    func flushAutomatically(performFullFlush: Bool = false, completion: (@Sendable () -> Void)? = nil) {
        trackingQueue.async { [weak self, completion] in
            guard let self, self.mobileLifecycleReady else {
                if let completion {
                    DispatchQueue.main.async(execute: completion)
                }
                return
            }
            self.flush(performFullFlush: performFullFlush, completion: completion)
        }
    }

    /// Drains the local event queue to `/ingest`. The flush timer and the
    /// background hook also call this; the host rarely needs to.
    public func flush(performFullFlush: Bool = false, completion: (@Sendable () -> Void)? = nil) {
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
            guard self.clearPrivacyQueueIfNeeded() else {
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
                excludeAutomaticEvents: !self.trackAutomaticEventsEnabled,
                excludeAutomaticPurchases: !self.trackAutomaticPurchasesEnabled
            )
            let pendingEvents = PersistedEventTransfer(value: eventQueue)
            self.networkQueue.async { [weak self, completion, pendingEvents] in
                guard let self = self else {
                    if let completion = completion {
                        DispatchQueue.main.async(execute: completion)
                    }
                    return
                }
                self.flushQueue(pendingEvents.value, type: .events)
                if let completion = completion {
                    DispatchQueue.main.async(execute: completion)
                }
            }
        }
    }

    func flushQueue(_ queue: Queue, type: FlushType) {
        if hasOptedOutTracking() || oursprivacyPersistence.hasPendingPrivacyClear {
            return
        }
        guard !queue.isEmpty else { return }
        let proxyServerResource = proxyServerDelegate?.oursprivacyResourceForProxyServer(name)
        let headers: [String: String] = proxyServerResource?.headers ?? [:]
        let queryItems = proxyServerResource?.queryItems ?? []
        flushInstance.flushQueue(queue, type: type, headers: headers, queryItems: queryItems)
    }

    func canFlushBatch(type: FlushType, rows: Queue) -> Bool {
        type == .events && !hasOptedOutTracking() && oursprivacyPersistence.containsFlushRows(rows)
    }

    func acknowledgeFlush(type: FlushType, rowIDs: [String]) -> Bool {
        type == .events && oursprivacyPersistence.removeFlushedRows(rowIDs, type: .events)
    }

    func hasIndexedIngestMode() -> Bool {
        oursprivacyPersistence.hasIndexedIngestMode
    }

    func persistIndexedIngestMode() -> Bool {
        oursprivacyPersistence.persistIndexedIngestMode()
    }

    func reportIngestRejection(distinctId: String, code: String) {
        onIngestRejected?(distinctId, code)
    }

    func flushEnvelopeContext() -> (token: String, isManuallySetId: Bool) {
        var manualSnapshot = false
        readWriteLock.read {
            manualSnapshot = self._isManuallySetId
        }
        return (apiToken, manualSnapshot)
    }
}

extension OursPrivacy {
    // MARK: - Track

    /// Records an iOS app screen as `$mobile_screen_view`; other runtimes ignore it.
    /// Use fixed labels, never titles, URLs, route parameters, or patient data.
    public func trackScreen(_ name: String) {
        guard mobileRuntimeEnabled, MobileSession.isValidScreenName(name) else { return }
        let point = captureMobileTime()
        trackingQueue.async { [weak self] in
            guard let self, !self.hasOptedOutTracking(),
                  self.clearPrivacyQueueIfNeeded(),
                  let mobileSession = self.mobileSession else { return }
            self.queuePendingMobileFacts()
            _ = mobileSession.screen(name, visitorId: self.visitorId,
                                     appVersion: AutomaticProperties.appVersion,
                                     appBuild: AutomaticProperties.appBuild, at: point)
            self.queuePendingMobileFacts()
        }
    }

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
#if os(iOS) || os(tvOS) || os(visionOS)
        AutomaticProperties.primeUIPropertiesIfOnMain()
#endif
        let capturedProperties = PropertySnapshot(properties)
        let capturedUserProperties = PropertySnapshot(userProperties)
        let point = captureMobileTime()
        trackingQueue.async { [weak self, event, capturedProperties, capturedUserProperties] in
            guard let self = self else { return }
            if self.hasOptedOutTracking() {
                return
            }
            guard self.clearPrivacyQueueIfNeeded() else { return }
            let wasHeld = !self.pendingTrackingItems.isEmpty
            self.queuePendingMobileFacts()
            let context = self.currentEventContext(at: point)
            let item = self.trackInstance.composeTrackEvent(event: event,
                                                            eventProperties: capturedProperties.decode(),
                                                            userProperties: capturedUserProperties.decode(),
                                                            context: context)
            if item.isEmpty { return }
            if !wasHeld && self.pendingTrackingItems.isEmpty {
                self.oursprivacyPersistence.saveEntity(item, type: .events)
            } else {
                self.pendingTrackingItems.append(PendingTrackingItem(event: item, completion: nil))
            }
            self.queuePendingMobileFacts()
        }

        if OursPrivacy.isiOSAppExtension() {
            flushAutomatically()
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
            #if os(iOS) || os(tvOS) || os(visionOS)
                self.automaticEvents.unregisterPurchaseObserver()
            #endif
            self.mobileCheckpointTimer?.cancel()
            self.mobileCheckpointTimer = nil
            self.mobilePendingRetryTimer?.cancel()
            self.mobilePendingRetryTimer = nil
            self.pendingTrackingItems.removeAll()
            self.readWriteLock.write {
                self.optOutStatus = true
            }
            OursPrivacyPersistence.saveOptOutStatusFlag(value: true, instanceName: self.name)
            self.mobileSession?.disable()
            self.readWriteLock.write {
                self._visitorId = self.newVisitorId()
                self._isManuallySetId = false
                self.defaultEventProperties = [:]
                self.userCustomProperties = [:]
                self.userConsentProperties = [:]
                self.attributionDefaultProperties = [:]
            }
            _ = self.oursprivacyPersistence.clearEntitiesForPrivacy()
            self.archive()
        }
    }

    /// Re-enable tracking for an opted-out visitor and fire `$opt_in`. If
    /// `userProperties` is supplied, identify the visitor in the same flow.
    public func optInTracking(userProperties: OursPrivacyUserProperties? = nil,
                              properties: Properties? = nil) {
        let capturedProperties = PropertySnapshot(properties)
        let capturedUserProperties = PropertySnapshot(userProperties?.toWireProperties())
        let shouldIdentify = userProperties != nil
        let point = captureMobileTime()
        #if os(iOS) || os(tvOS) || os(visionOS)
            AutomaticProperties.primeUIPropertiesIfOnMain()
        #endif
        trackingQueue.async { [weak self, capturedProperties, capturedUserProperties, shouldIdentify] in
            guard let self = self else { return }
            guard self.clearPrivacyQueueIfNeeded() else { return }
            self.readWriteLock.write {
                self.optOutStatus = false
            }
            self.readWriteLock.read {
                OursPrivacyPersistence.saveOptOutStatusFlag(value: self.optOutStatus!, instanceName: self.name)
            }
            #if os(iOS) || os(tvOS) || os(visionOS)
                if self.trackAutomaticPurchasesEnabled && self.mobileLifecycleReady {
                    self.automaticEvents.registerPurchaseObserver()
                }
            #endif
            if self.mobileRuntimeEnabled, self.mobileLifecycleReady,
               self.mobileAppState == .active {
                self.processMobileForeground(at: point)
            }
            let context = self.currentEventContext(at: point)
            let identify = shouldIdentify
                ? self.trackInstance.composeIdentifyEvent(userProperties: capturedUserProperties.decode(),
                                                          context: context)
                : nil
            let event = self.trackInstance.composeTrackEvent(event: "$opt_in",
                                                             eventProperties: capturedProperties.decode(),
                                                             userProperties: nil, context: context)
            if let identify {
                self.pendingTrackingItems.append(PendingTrackingItem(event: identify, completion: nil))
            }
            self.pendingTrackingItems.append(PendingTrackingItem(event: event, completion: nil))
            self.queuePendingMobileFacts()
        }
        if OursPrivacy.isiOSAppExtension() {
            flushAutomatically()
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
