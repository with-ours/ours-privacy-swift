//
//  Track.swift
//  OursPrivacy
//
//  Copyright © 2025 Ours Wellness Inc.  All rights reserved.
//

import Foundation

func += <K, V>(left: inout [K: V], right: [K: V]) {
    for (k, v) in right {
        left.updateValue(v, forKey: k)
    }
}

/// State the composer needs at call time to build a canonical event item.
struct EventContext {
    let visitorId: String
    let defaultEventProperties: [String: Any]
    let userCustomProperties: [String: Any]
    let userConsentProperties: [String: Any]
    let attributionDefaultProperties: [String: Any]
}

class Track {
    weak var oursprivacyInstance: OursPrivacy?

    init() {}

    /// Builds the inner `data[]` element for a `track()` call. Mirrors the wire
    /// shape pinned by the server's `eventSchema` in
    /// `martech/packages/types/src/event.ts` and the web-cdp composer in
    /// `martech/apps/web-cdp/src/lib/format-track.ts`.
    ///
    /// `eventProperties` is `{...defaultEventProperties, ...callerEventProperties}`
    /// (per-call wins on key collision). `userProperties` is per-call only, merged
    /// with default custom/consent bags via `Track.mergeUserProperties`.
    func composeTrackEvent(event: String?,
                           eventProperties: Properties?,
                           userProperties: Properties?,
                           context: EventContext) -> InternalProperties {
        var name = "op_event"
        if let event = event {
            name = event
        } else {
            OursPrivacyLogger.info(message: "oursprivacy track called with empty event parameter. using 'op_event'")
        }
        if !(oursprivacyInstance?.trackAutomaticEventsEnabled ?? false) && name.hasPrefix("$ae_") {
            // Caller has automatic events disabled — drop the AE event silently.
            return [:]
        }
        assertPropertyTypes(eventProperties)
        assertPropertyTypes(userProperties)

        var mergedEventProperties: InternalProperties = [:]
        mergedEventProperties += context.defaultEventProperties
        if let eventProperties = eventProperties {
            for (k, v) in eventProperties {
                mergedEventProperties[k] = v
            }
        }

        // `$distinct_id` override matches web-cdp/format-track.ts:62 — lets
        // callers pin a per-event distinct_id (e.g. for replay stitching).
        let distinctId: String
        if let override = mergedEventProperties["$distinct_id"] as? String, !override.isEmpty {
            distinctId = override
            mergedEventProperties.removeValue(forKey: "$distinct_id")
        } else {
            distinctId = UUID().uuidString
        }

        let mergedUserProperties = Track.mergeUserProperties(
            perCall: userProperties,
            defaultCustom: context.userCustomProperties,
            defaultConsent: context.userConsentProperties
        )

        var defaultProperties: InternalProperties = [:]
        AutomaticProperties.automaticPropertiesLock.read {
            defaultProperties += AutomaticProperties.defaultProperties
        }
        defaultProperties += context.attributionDefaultProperties

        let item: InternalProperties = [
            "event": name,
            "visitor_id": context.visitorId,
            "distinct_id": distinctId,
            "eventProperties": mergedEventProperties.isEmpty ? NSNull() : mergedEventProperties,
            "userProperties": mergedUserProperties ?? NSNull(),
            "defaultProperties": defaultProperties,
        ]
        return item
    }

    /// Builds the inner `data[]` element for an `identify()` call. Mirrors
    /// `oursprivacy-main.js:212` — `event: "$identify"`, `eventProperties: null`,
    /// `userProperties` carries the typed visitor profile with `external_id`
    /// set from the caller's `distinctId`.
    func composeIdentifyEvent(distinctId: String,
                              userProperties: Properties?,
                              context: EventContext) -> InternalProperties {
        assertPropertyTypes(userProperties)

        var identifyUserProps: Properties = ["external_id": distinctId]
        if let userProperties = userProperties {
            for (k, v) in userProperties {
                identifyUserProps[k] = v
            }
        }

        let merged = Track.mergeUserProperties(
            perCall: identifyUserProps,
            defaultCustom: context.userCustomProperties,
            defaultConsent: context.userConsentProperties
        )

        var defaultProperties: InternalProperties = [:]
        AutomaticProperties.automaticPropertiesLock.read {
            defaultProperties += AutomaticProperties.defaultProperties
        }
        defaultProperties += context.attributionDefaultProperties

        return [
            "event": "$identify",
            "visitor_id": context.visitorId,
            "distinct_id": UUID().uuidString,
            "eventProperties": NSNull(),
            "userProperties": merged ?? NSNull(),
            "defaultProperties": defaultProperties,
        ]
    }

    /// Mirrors `formatUserProperties` in
    /// `martech/apps/web-cdp/src/lib/format-track.ts`. Top-level keys come from
    /// the per-call dict. `custom_properties` is `{...defaults, ...perCall}`
    /// (per-call wins). `consent` is the same, but the key is **omitted
    /// entirely** when neither side has consent data — emitting `consent: {}`
    /// races with the CMP's `$consent_init` and overwrites real consent data
    /// (OUR-3669).
    static func mergeUserProperties(perCall: Properties?,
                                    defaultCustom: [String: Any],
                                    defaultConsent: [String: Any]) -> InternalProperties? {
        let haveDefaultCustom = !defaultCustom.isEmpty
        let haveDefaultConsent = !defaultConsent.isEmpty
        let perCallCustom = (perCall?["custom_properties"] as? Properties) ?? [:]
        let perCallConsent = (perCall?["consent"] as? Properties) ?? [:]
        let havePerCall = (perCall?.isEmpty == false)
        let havePerCallConsent = !perCallConsent.isEmpty

        if !haveDefaultCustom && !haveDefaultConsent {
            // Fast path — no store-level defaults configured. Pass per-call
            // through unchanged (still null if caller passed nothing).
            guard let perCall = perCall, !perCall.isEmpty else { return nil }
            var out: InternalProperties = [:]
            for (k, v) in perCall { out[k] = v }
            return out
        }

        if !havePerCall && !haveDefaultCustom && !haveDefaultConsent {
            return nil
        }

        var merged: InternalProperties = [:]
        if let perCall = perCall {
            for (k, v) in perCall where k != "custom_properties" && k != "consent" {
                merged[k] = v
            }
        }

        var mergedCustom: InternalProperties = [:]
        for (k, v) in defaultCustom { mergedCustom[k] = v }
        for (k, v) in perCallCustom { mergedCustom[k] = v }
        if !mergedCustom.isEmpty {
            merged["custom_properties"] = mergedCustom
        }

        // OUR-3669 guard: only emit `consent` when there's actual consent data.
        if haveDefaultConsent || havePerCallConsent {
            var mergedConsent: InternalProperties = [:]
            for (k, v) in defaultConsent { mergedConsent[k] = v }
            for (k, v) in perCallConsent { mergedConsent[k] = v }
            merged["consent"] = mergedConsent
        }

        return merged.isEmpty ? nil : merged
    }
}
