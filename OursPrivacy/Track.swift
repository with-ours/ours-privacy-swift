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
    var mobileSnapshot: MobileSessionSnapshot?
    var isManuallySetId: Bool?
}

enum MobileEventProperties {
    static let commonKeys = ["mobile_contract_version", "mobile_occurred_at", "app_version", "app_build"]
    static let maximumCount = 200
    static let maximumSerializedLength = 1_048_576

    static func adding(_ metadata: InternalProperties, to properties: InternalProperties) -> InternalProperties {
        var properties = properties
        for key in commonKeys + ["mobile_session_started_at", "mobile_platform"] {
            properties.removeValue(forKey: key)
        }
        var enriched = properties
        enriched += metadata
        guard fits(enriched) else {
            OursPrivacyLogger.warn(message: "Mobile metadata omitted because event properties exceed capacity")
            return properties
        }
        return enriched
    }

    static func omittingMetadataIfNeeded(_ properties: InternalProperties) -> InternalProperties {
        guard !fits(properties) else { return properties }
        var ordinary = properties
        for key in commonKeys { ordinary.removeValue(forKey: key) }
        guard fits(ordinary) else { return properties }
        OursPrivacyLogger.warn(message: "Mobile metadata omitted because event properties exceed capacity")
        return ordinary
    }

    private static func fits(_ properties: InternalProperties) -> Bool {
        guard properties.count <= maximumCount,
              let encoded = JSONHandler.encodeAPIData(properties) else { return false }
        return encoded.utf16.count < maximumSerializedLength
    }
}

class Track {
    weak var oursprivacyInstance: OursPrivacy?

    init() {}

    /// Builds the inner `data[]` element for a `track()` call. Conforms to the
    /// ingest endpoint's event schema.
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
        guard !name.hasPrefix("$mobile_") else { return [:] }
        if name == "$ae_iap" {
            guard oursprivacyInstance?.trackAutomaticPurchasesEnabled == true else { return [:] }
        } else if name.hasPrefix("$ae_") && !(oursprivacyInstance?.trackAutomaticEventsEnabled ?? false) {
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

        // `$distinct_id` override lets callers pin a per-event distinct_id
        // (e.g. for replay stitching).
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
        defaultProperties += AutomaticProperties.defaultProperties
        defaultProperties += context.attributionDefaultProperties
        if let snapshot = context.mobileSnapshot {
            defaultProperties += snapshot.defaultProperties
            mergedEventProperties = MobileEventProperties.adding(snapshot.eventProperties, to: mergedEventProperties)
        }

        var item: InternalProperties = [
            "event": name,
            "visitor_id": context.visitorId,
            "distinct_id": distinctId,
            "eventProperties": mergedEventProperties.isEmpty ? NSNull() : mergedEventProperties,
            "userProperties": mergedUserProperties ?? NSNull(),
            "defaultProperties": defaultProperties
        ]
        item[OursPrivacyPersistence.localIdentityModeKey] = context.isManuallySetId
        return item
    }

    func composeIdentifyEvent(userProperties: Properties?,
                              context: EventContext) -> InternalProperties {
        assertPropertyTypes(userProperties)

        let merged = Track.mergeUserProperties(
            perCall: userProperties,
            defaultCustom: context.userCustomProperties,
            defaultConsent: context.userConsentProperties
        )

        var defaultProperties: InternalProperties = [:]
        defaultProperties += AutomaticProperties.defaultProperties
        defaultProperties += context.attributionDefaultProperties
        if let snapshot = context.mobileSnapshot {
            defaultProperties += snapshot.defaultProperties
        }

        var item: InternalProperties = [
            "event": "$identify",
            "visitor_id": context.visitorId,
            "distinct_id": UUID().uuidString,
            "eventProperties": context.mobileSnapshot?.eventProperties ?? NSNull(),
            "userProperties": merged ?? NSNull(),
            "defaultProperties": defaultProperties
        ]
        item[OursPrivacyPersistence.localIdentityModeKey] = context.isManuallySetId
        return item
    }

    func composeMobileFact(_ fact: MobileFact) -> InternalProperties {
        let allowed = Set(["device_vendor", "device_model", "device_type", "os_name",
                           "os_version", "screen_width", "screen_height", "version"])
        var defaults = AutomaticProperties.defaultProperties.filter { allowed.contains($0.key) }
        defaults += fact.defaultProperties
        var item: InternalProperties = [
            "event": fact.name,
            "visitor_id": fact.visitorId,
            "distinct_id": fact.distinctId,
            "eventProperties": fact.properties.isEmpty ? NSNull() : fact.properties,
            "userProperties": NSNull(),
            "defaultProperties": defaults
        ]
        item[OursPrivacyPersistence.localIdentityModeKey] = fact.isManuallySetId
        return item
    }

    /// Merges per-call user properties with the store-level default custom
    /// and consent bags. Top-level keys come from the per-call dict.
    /// `custom_properties` is `{...defaults, ...perCall}` (per-call wins).
    /// `consent` follows the same rule, but the key is **omitted entirely**
    /// when neither side has consent data — emitting `consent: {}` races
    /// with the CMP's `$consent_init` and would overwrite real consent data.
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
            // Fast path — no store-level defaults configured. Keep per-call
            // properties except empty consent (still null if nothing remains).
            guard let perCall = perCall, !perCall.isEmpty else { return nil }
            var out: InternalProperties = [:]
            for (k, v) in perCall { out[k] = v }
            if !havePerCallConsent { out.removeValue(forKey: "consent") }
            return out.isEmpty ? nil : out
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

        // Only emit `consent` when there's actual consent data — see doc above.
        if haveDefaultConsent || havePerCallConsent {
            var mergedConsent: InternalProperties = [:]
            for (k, v) in defaultConsent { mergedConsent[k] = v }
            for (k, v) in perCallConsent { mergedConsent[k] = v }
            merged["consent"] = mergedConsent
        }

        return merged.isEmpty ? nil : merged
    }
}
