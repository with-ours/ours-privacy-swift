import Foundation

struct MobileTimePoint: Sendable {
    let epochMs: Int64
    let monotonicMs: Int64

    static func capture(epochMillis: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) },
                        monotonicMillis: () -> Int64 = { Int64(ProcessInfo.processInfo.systemUptime * 1_000) }) -> MobileTimePoint {
        MobileTimePoint(epochMs: epochMillis(), monotonicMs: monotonicMillis())
    }
}

private func mobileISOTime(_ epochMs: Int64) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: Date(timeIntervalSince1970: Double(epochMs) / 1_000))
}

private enum MobileValue: Codable {
    case text(String)
    case milliseconds(Int64)

    var wireValue: Any {
        switch self {
        case let .text(value): return value
        case let .milliseconds(value): return value
        }
    }
}

struct MobileSessionSnapshot {
    let sid: String
    let visitorId: String
    let startedAtMs: Int64
    let occurredAtMs: Int64
    let appVersion: String?
    let appBuild: String?
    var isManuallySetId: Bool?

    var startedAtISO: String { mobileISOTime(startedAtMs) }
    var occurredAtISO: String { mobileISOTime(occurredAtMs) }

    var defaultProperties: [String: Any] {
        ["sid": sid]
    }

    var eventProperties: [String: Any] {
        var properties: [String: Any] = [
            "mobile_occurred_at": occurredAtISO,
            "mobile_contract_version": 1
        ]
        if let appVersion = appVersion { properties["app_version"] = appVersion }
        if let appBuild = appBuild { properties["app_build"] = appBuild }
        return properties
    }
}

struct MobileFact: Codable {
    let name: String
    let distinctId: String
    let visitorId: String
    let appVersion: String?
    let appBuild: String?
    var sid: String
    let startedAtMs: Int64
    let occurredAtMs: Int64
    let isManuallySetId: Bool?
    private let values: [String: MobileValue]

    fileprivate init(name: String, distinctId: String, snapshot: MobileSessionSnapshot,
                     values: [String: MobileValue] = [:]) {
        self.name = name
        self.distinctId = distinctId
        visitorId = snapshot.visitorId
        appVersion = snapshot.appVersion
        appBuild = snapshot.appBuild
        sid = snapshot.sid
        startedAtMs = snapshot.startedAtMs
        occurredAtMs = snapshot.occurredAtMs
        isManuallySetId = snapshot.isManuallySetId
        self.values = values
    }

    var startedAtISO: String { mobileISOTime(startedAtMs) }
    var occurredAtISO: String { mobileISOTime(occurredAtMs) }
    var properties: [String: Any] {
        var properties = values.mapValues(\.wireValue)
        properties += MobileSessionSnapshot(sid: sid, visitorId: visitorId, startedAtMs: startedAtMs,
                                            occurredAtMs: occurredAtMs, appVersion: appVersion,
                                            appBuild: appBuild).eventProperties
        return properties
    }

    var defaultProperties: [String: Any] {
        MobileSessionSnapshot(sid: sid, visitorId: visitorId, startedAtMs: startedAtMs,
                              occurredAtMs: occurredAtMs, appVersion: appVersion,
                              appBuild: appBuild).defaultProperties
    }
}

final class MobileSession {
    private let sessionTimeoutMs: Int64 = 30 * 60 * 1_000
    private let engagedThresholdMs: Int64 = 10 * 1_000
    private let rollbackToleranceMs: Int64 = 5 * 60 * 1_000

    static func isValidScreenName(_ name: String) -> Bool {
        guard name == name.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        guard let match = name.range(of: "^[A-Za-z][A-Za-z0-9 _-]{0,79}$",
                                     options: .regularExpression) else { return false }
        return match == name.startIndex ..< name.endIndex
    }

    private struct StoredState: Codable {
        var sid: String?
        var startedAtMs: Int64?
        var lastSessionEpochMs: Int64?
        var lastIssuedSessionMs: Int64?
        var lastActiveAtMs: Int64?
        var lastObservedWallMs: Int64?
        var sessionVisitorId: String?
        var sessionAppVersion: String?
        var sessionAppBuild: String?
        var sessionIsManuallySetId: Bool?
        var automaticStartSid: String?
        var foregroundDurationMs: Int64?
        var pendingFacts: [MobileFact] = []
        var firstOpenAccepted = false
        var observedAppVersion: String?
        var observedAppBuild: String?
    }

    private let lock = NSLock()
    private let defaults: UserDefaults?
    private let stateKey: String
    private let uuid: () -> UUID
    private var state: StoredState
    private var replayPendingOnForeground: Bool

    private var isForeground = false
    private var isPaused = false
    private var handledAutomaticForeground = false
    private var checkpointMonotonicMs: Int64?
    private var activeScreen: String?
    private var activeVisitorId: String?
    private var activeAppVersion: String?
    private var activeAppBuild: String?
    private var activeIsManuallySetId: Bool?

    init(instanceName: String, uuid: @escaping () -> UUID = UUID.init) {
        self.uuid = uuid
        defaults = UserDefaults(suiteName: OursPrivacyUserDefaultsKeys.suiteName)
        stateKey = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-OPMobileSession"
        if let data = defaults?.data(forKey: stateKey),
           let restored = try? JSONDecoder().decode(StoredState.self, from: data) {
            state = restored
        } else {
            state = StoredState()
            let prefix = "\(OursPrivacyUserDefaultsKeys.prefix)-\(instanceName)-"
            let visitorId = defaults?.string(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.visitorId)")
            let distinctId = defaults?.string(forKey: "\(prefix)\(OursPrivacyUserDefaultsKeys.legacyDistinctID)")
            let hasPersistedIdentity = visitorId?.isEmpty == false || distinctId?.isEmpty == false
            if defaults?.bool(forKey: "OPFirstOpen-\(instanceName)") == true ||
                defaults?.bool(forKey: "OPFirstOpen") == true || hasPersistedIdentity {
                state.firstOpenAccepted = true
                state.observedAppVersion = defaults?.string(forKey: "OPAppVersion")
            }
        }
        replayPendingOnForeground = !state.pendingFacts.isEmpty
        if state.lastSessionEpochMs == nil { state.lastSessionEpochMs = state.startedAtMs }
        if state.lastIssuedSessionMs == nil { state.lastIssuedSessionMs = state.startedAtMs }
        if let sid = state.sid, sid != state.startedAtMs.map(String.init) {
            clearSession()
        }
        state.pendingFacts = state.pendingFacts.map { fact in
            var migrated = fact
            migrated.sid = String(fact.startedAtMs)
            return migrated
        }
        persist()
    }

    var pendingFacts: [MobileFact] {
        withLock { state.pendingFacts }
    }

    var hasAcceptedFirstOpen: Bool {
        withLock { state.firstOpenAccepted }
    }

    var remainingEngagementThresholdMs: Int64 {
        withLock {
            engagedThresholdMs - (state.foregroundDurationMs ?? 0) % engagedThresholdMs
        }
    }

    func foreground(automaticEnabled: Bool, visitorId: String,
                    appVersion: String? = nil, appBuild: String? = nil,
                    isManuallySetId: Bool? = nil,
                    at point: MobileTimePoint) -> [MobileFact] {
        withLock {
            if isForeground && (!automaticEnabled || handledAutomaticForeground) {
                return []
            }

            let expired = ensureSession(at: point, visitorId: visitorId,
                                        appVersion: appVersion, appBuild: appBuild,
                                        isManuallySetId: isManuallySetId)
            isForeground = true
            checkpointMonotonicMs = point.monotonicMs
            activeVisitorId = visitorId
            activeAppVersion = appVersion
            activeAppBuild = appBuild
            activeIsManuallySetId = isManuallySetId
            state.lastActiveAtMs = max(point.epochMs, state.startedAtMs ?? point.epochMs)

            guard automaticEnabled else {
                persist()
                return []
            }

            var facts: [MobileFact] = []
            if replayPendingOnForeground {
                let expiredIds = Set(expired.map(\.distinctId))
                facts.append(contentsOf: state.pendingFacts.filter { !expiredIds.contains($0.distinctId) })
                replayPendingOnForeground = false
            }
            facts.append(contentsOf: expired)
            let snapshot = currentSnapshot(visitorId: visitorId, appVersion: appVersion,
                                           appBuild: appBuild, isManuallySetId: isManuallySetId, at: point.epochMs)
            if !state.firstOpenAccepted &&
                !state.pendingFacts.contains(where: { $0.name == "$mobile_first_open" }) {
                facts.append(record("$mobile_first_open", snapshot: snapshot))
            }
            facts.append(record("$mobile_app_open", snapshot: snapshot))
            if state.automaticStartSid != snapshot.sid {
                facts.append(record("$mobile_session_start", snapshot: snapshot))
                state.automaticStartSid = snapshot.sid
            }
            if appVersion != nil || appBuild != nil {
                let versionChanged = appVersion != nil && state.observedAppVersion != nil &&
                    state.observedAppVersion != appVersion
                let buildChanged = appBuild != nil && state.observedAppBuild != nil &&
                    state.observedAppBuild != appBuild
                if versionChanged || buildChanged {
                    var values: [String: MobileValue] = [:]
                    if let previous = state.observedAppVersion { values["previous_app_version"] = .text(previous) }
                    if let previous = state.observedAppBuild { values["previous_app_build"] = .text(previous) }
                    facts.append(record("$mobile_app_update", snapshot: snapshot, values: values))
                }
                if let appVersion { state.observedAppVersion = appVersion }
                if let appBuild { state.observedAppBuild = appBuild }
            }
            handledAutomaticForeground = true
            persist()
            return facts
        }
    }

    func background(at point: MobileTimePoint) -> [MobileFact] {
        withLock {
            guard isForeground else { return [] }
            var facts = isPaused ? [] : engagement(at: point, force: true)
            if isLargeRollback(at: point.epochMs) {
                if let ended = endStartedSession(at: point) { facts.append(ended) }
                clearSession()
                persist()
                return facts
            }
            isForeground = false
            let wasPaused = isPaused
            isPaused = false
            handledAutomaticForeground = false
            checkpointMonotonicMs = nil
            activeScreen = nil
            if !wasPaused {
                state.lastActiveAtMs = max(point.epochMs, state.startedAtMs ?? point.epochMs)
            }
            state.lastObservedWallMs = max(state.lastObservedWallMs ?? point.epochMs, point.epochMs)
            persist()
            return facts
        }
    }

    func pauseActive(at point: MobileTimePoint) -> [MobileFact] {
        withLock {
            guard isForeground, !isPaused else { return [] }
            var facts = engagement(at: point, force: true)
            if isLargeRollback(at: point.epochMs) {
                facts.append(contentsOf: ensureActiveSession(at: point))
            }
            isPaused = true
            checkpointMonotonicMs = nil
            state.lastActiveAtMs = max(point.epochMs, state.startedAtMs ?? point.epochMs)
            state.lastObservedWallMs = max(state.lastObservedWallMs ?? point.epochMs, point.epochMs)
            persist()
            return facts
        }
    }

    func resumeActive(at point: MobileTimePoint) -> Bool {
        withLock {
            guard isForeground, isPaused else { return false }
            if isLargeRollback(at: point.epochMs) {
                _ = ensureActiveSession(at: point)
            }
            isPaused = false
            checkpointMonotonicMs = point.monotonicMs
            state.lastActiveAtMs = max(point.epochMs, state.startedAtMs ?? point.epochMs)
            state.lastObservedWallMs = max(state.lastObservedWallMs ?? point.epochMs, point.epochMs)
            persist()
            return true
        }
    }

    func checkpoint(at point: MobileTimePoint) -> [MobileFact] {
        withLock {
            guard isForeground, !isPaused else { return [] }
            let rolledBack = isLargeRollback(at: point.epochMs)
            var facts = engagement(at: point, force: rolledBack)
            if rolledBack {
                facts.append(contentsOf: ensureActiveSession(at: point))
                persist()
                return facts
            }
            state.lastActiveAtMs = max(point.epochMs, state.startedAtMs ?? point.epochMs)
            state.lastObservedWallMs = max(state.lastObservedWallMs ?? point.epochMs, point.epochMs)
            persist()
            return facts
        }
    }

    func screen(_ name: String, visitorId: String,
                appVersion: String? = nil, appBuild: String? = nil,
                isManuallySetId: Bool? = nil,
                at point: MobileTimePoint) -> [MobileFact] {
        withLock {
            guard Self.isValidScreenName(name), name != activeScreen else { return [] }
            let previous = isForeground
                ? engagement(at: point, force: true) : []
            let expired = ensureSession(at: point, visitorId: visitorId,
                                        appVersion: appVersion, appBuild: appBuild,
                                        isManuallySetId: isManuallySetId)
            activeScreen = name
            state.lastActiveAtMs = max(point.epochMs, state.startedAtMs ?? point.epochMs)
            let snapshot = currentSnapshot(visitorId: visitorId, appVersion: appVersion,
                                           appBuild: appBuild, isManuallySetId: isManuallySetId, at: point.epochMs)
            let fact = record("$mobile_screen_view", snapshot: snapshot,
                              values: ["screen_name": .text(name)])
            persist()
            return previous + expired + [fact]
        }
    }

    func snapshot(visitorId: String, appVersion: String? = nil, appBuild: String? = nil,
                  isManuallySetId: Bool? = nil,
                  at point: MobileTimePoint) -> MobileSessionSnapshot {
        withLock {
            if isForeground && isLargeRollback(at: point.epochMs) {
                _ = engagement(at: point, force: true)
            }
            _ = ensureSession(at: point, visitorId: visitorId,
                              appVersion: appVersion, appBuild: appBuild,
                              isManuallySetId: isManuallySetId)
            state.lastActiveAtMs = max(point.epochMs, state.startedAtMs ?? point.epochMs)
            let result = currentSnapshot(visitorId: visitorId, appVersion: appVersion,
                                         appBuild: appBuild, isManuallySetId: isManuallySetId, at: point.epochMs)
            persist()
            return result
        }
    }

    func rotate(at point: MobileTimePoint) -> [MobileFact] {
        withLock {
            var facts = isForeground
                ? engagement(at: point, force: true) : []
            if let ended = endStartedSession(at: point) { facts.append(ended) }
            clearSession()
            persist()
            return facts
        }
    }

    func setIdentityMode(_ isManuallySetId: Bool, at point: MobileTimePoint) -> [MobileFact] {
        withLock {
            guard state.sessionIsManuallySetId != isManuallySetId else { return [] }
            let facts = isForeground ? engagement(at: point, force: true) : []
            activeIsManuallySetId = isManuallySetId
            state.sessionIsManuallySetId = isManuallySetId
            persist()
            return facts
        }
    }

    func rotate(to visitorId: String, appVersion: String?, appBuild: String?,
                isManuallySetId: Bool? = nil,
                at point: MobileTimePoint) -> [MobileFact] {
        withLock {
            let wasForeground = isForeground
            let wasPaused = isPaused
            let wasAutomatic = handledAutomaticForeground
            var facts = isForeground ? engagement(at: point, force: true) : []
            if let ended = endStartedSession(at: point) { facts.append(ended) }
            clearSession()
            if wasForeground {
                _ = ensureSession(at: point, visitorId: visitorId,
                                  appVersion: appVersion, appBuild: appBuild,
                                  isManuallySetId: isManuallySetId)
                state.lastActiveAtMs = point.epochMs
                isForeground = true
                isPaused = wasPaused
                handledAutomaticForeground = wasAutomatic
                checkpointMonotonicMs = wasPaused ? nil : point.monotonicMs
                activeVisitorId = visitorId
                activeAppVersion = appVersion
                activeAppBuild = appBuild
                activeIsManuallySetId = isManuallySetId
                if wasAutomatic {
                    let snapshot = currentSnapshot(visitorId: visitorId, appVersion: appVersion,
                                                   appBuild: appBuild, isManuallySetId: isManuallySetId,
                                                   at: point.epochMs)
                    facts.append(record("$mobile_session_start", snapshot: snapshot))
                    state.automaticStartSid = snapshot.sid
                }
            }
            persist()
            return facts
        }
    }

    func disable() {
        withLock {
            clearSession()
            state.pendingFacts.removeAll()
            replayPendingOnForeground = false
            persist()
        }
    }

    func discardPendingFacts() {
        withLock {
            state.pendingFacts.removeAll()
            replayPendingOnForeground = false
            persist()
        }
    }

    func acknowledgeQueuedFacts(_ distinctIds: Set<String>, firstOpenQueueEvidence: Bool) {
        withLock {
            let previousCount = state.pendingFacts.count
            let wasAccepted = state.firstOpenAccepted
            state.pendingFacts.removeAll { fact in
                if fact.name == "$mobile_first_open" { return firstOpenQueueEvidence }
                return distinctIds.contains(fact.distinctId)
            }
            if firstOpenQueueEvidence { state.firstOpenAccepted = true }
            if state.pendingFacts.count != previousCount || state.firstOpenAccepted != wasAccepted {
                persist()
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults?.set(data, forKey: stateKey)
    }

    private func isLargeRollback(at epochMs: Int64) -> Bool {
        guard let observed = state.lastObservedWallMs else { return false }
        return observed - epochMs > rollbackToleranceMs
    }

    private func clearSession() {
        state.sid = nil
        state.startedAtMs = nil
        state.lastActiveAtMs = nil
        state.lastObservedWallMs = nil
        state.sessionVisitorId = nil
        state.sessionAppVersion = nil
        state.sessionAppBuild = nil
        state.sessionIsManuallySetId = nil
        state.automaticStartSid = nil
        state.foregroundDurationMs = nil
        isForeground = false
        isPaused = false
        handledAutomaticForeground = false
        checkpointMonotonicMs = nil
        activeScreen = nil
        activeVisitorId = nil
        activeAppVersion = nil
        activeAppBuild = nil
        activeIsManuallySetId = nil
    }

    private func ensureSession(at point: MobileTimePoint, visitorId: String,
                               appVersion: String?, appBuild: String?,
                               isManuallySetId: Bool?) -> [MobileFact] {
        var facts: [MobileFact] = []
        let timedOut = !isForeground && state.lastActiveAtMs.map {
            point.epochMs - $0 >= sessionTimeoutMs
        } ?? false
        if state.sid == nil || timedOut || isLargeRollback(at: point.epochMs) {
            let wasForeground = isForeground
            let wasPaused = isPaused
            let wasAutomatic = handledAutomaticForeground
            let previousScreen = activeScreen
            if let ended = endStartedSession(at: point) { facts.append(ended) }
            clearSession()
            let startedAtMs: Int64
            if let lastEpoch = state.lastSessionEpochMs, let lastIssued = state.lastIssuedSessionMs,
               lastEpoch - point.epochMs <= rollbackToleranceMs {
                startedAtMs = max(point.epochMs, lastIssued + 1)
            } else {
                startedAtMs = point.epochMs
            }
            state.lastSessionEpochMs = point.epochMs
            state.lastIssuedSessionMs = startedAtMs
            state.sid = String(startedAtMs)
            state.startedAtMs = startedAtMs
            state.sessionVisitorId = visitorId
            state.sessionAppVersion = appVersion
            state.sessionAppBuild = appBuild
            state.sessionIsManuallySetId = isManuallySetId
            if wasForeground {
                isForeground = true
                isPaused = wasPaused
                handledAutomaticForeground = wasAutomatic
                checkpointMonotonicMs = wasPaused ? nil : point.monotonicMs
                activeScreen = previousScreen
                activeVisitorId = visitorId
                activeAppVersion = appVersion
                activeAppBuild = appBuild
                activeIsManuallySetId = isManuallySetId
                state.lastActiveAtMs = startedAtMs
                if wasAutomatic {
                    let snapshot = currentSnapshot(visitorId: visitorId, appVersion: appVersion,
                                                   appBuild: appBuild, isManuallySetId: isManuallySetId,
                                                   at: point.epochMs)
                    facts.append(record("$mobile_session_start", snapshot: snapshot))
                    state.automaticStartSid = snapshot.sid
                }
            }
        }
        state.lastObservedWallMs = max(state.lastObservedWallMs ?? point.epochMs, point.epochMs)
        return facts
    }

    private func ensureActiveSession(at point: MobileTimePoint) -> [MobileFact] {
        guard let visitorId = activeVisitorId else { return [] }
        return ensureSession(at: point, visitorId: visitorId,
                             appVersion: activeAppVersion, appBuild: activeAppBuild,
                             isManuallySetId: activeIsManuallySetId)
    }

    private func endStartedSession(at point: MobileTimePoint) -> MobileFact? {
        guard let sid = state.sid, state.automaticStartSid == sid,
              let startedAtMs = state.startedAtMs, let visitorId = state.sessionVisitorId else { return nil }
        if isForeground, !isPaused {
            state.lastActiveAtMs = max(state.lastActiveAtMs ?? startedAtMs, point.epochMs)
        }
        let snapshot = MobileSessionSnapshot(sid: sid, visitorId: visitorId, startedAtMs: startedAtMs,
                                             occurredAtMs: max(startedAtMs, state.lastActiveAtMs ?? startedAtMs),
                                             appVersion: state.sessionAppVersion, appBuild: state.sessionAppBuild,
                                             isManuallySetId: state.sessionIsManuallySetId)
        return record("$mobile_session_end", snapshot: snapshot)
    }

    private func currentSnapshot(visitorId: String, appVersion: String?,
                                 appBuild: String?, isManuallySetId: Bool?, at epochMs: Int64) -> MobileSessionSnapshot {
        let startedAtMs = state.startedAtMs ?? epochMs
        return MobileSessionSnapshot(sid: state.sid ?? "", visitorId: visitorId,
                                     startedAtMs: startedAtMs,
                                     occurredAtMs: max(epochMs, startedAtMs),
                                     appVersion: appVersion, appBuild: appBuild,
                                     isManuallySetId: isManuallySetId)
    }

    private func record(_ name: String, snapshot: MobileSessionSnapshot,
                        values: [String: MobileValue] = [:]) -> MobileFact {
        let fact = MobileFact(name: name, distinctId: uuid().uuidString,
                              snapshot: snapshot, values: values)
        state.pendingFacts.append(fact)
        return fact
    }

    private func engagement(at point: MobileTimePoint, force: Bool) -> [MobileFact] {
        guard handledAutomaticForeground, let previous = checkpointMonotonicMs,
              let visitorId = activeVisitorId else { return [] }
        let duration = max(0, point.monotonicMs - previous)
        let priorDuration = state.foregroundDurationMs ?? 0
        guard duration > 0,
              force || (priorDuration + duration) / engagedThresholdMs > priorDuration / engagedThresholdMs else {
            return []
        }
        checkpointMonotonicMs = point.monotonicMs
        state.foregroundDurationMs = priorDuration + duration
        var values: [String: MobileValue] = ["engagement_duration_ms": .milliseconds(duration)]
        if let activeScreen = activeScreen { values["screen_name"] = .text(activeScreen) }
        let snapshot = currentSnapshot(visitorId: visitorId,
                                       appVersion: activeAppVersion, appBuild: activeAppBuild,
                                       isManuallySetId: activeIsManuallySetId,
                                       at: point.epochMs)
        return [record("$mobile_session_engagement", snapshot: snapshot, values: values)]
    }
}
