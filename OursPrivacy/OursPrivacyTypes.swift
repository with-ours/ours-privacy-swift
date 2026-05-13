//
//  OursPrivacyTypes.swift
//  OursPrivacy
//
//  Copyright © 2026 Ours Wellness Inc. All rights reserved.
//

import Foundation

/// Typed visitor properties accepted by ``OursPrivacy/identify(distinctId:userProperties:completion:)``
/// and ``OursPrivacy/track(event:properties:userProperties:)``.
///
/// Named fields use Swift's camelCase convention and are serialized to the
/// canonical snake_case wire shape (`externalId` → `external_id`, etc.).
/// Ad-hoc visitor metadata that doesn't match a named field belongs under
/// ``customProperties``.
public struct OursPrivacyUserProperties {
    public var email: String?
    public var externalId: String?
    public var phoneNumber: String?
    public var firstName: String?
    public var lastName: String?
    public var gender: String?
    public var dateOfBirth: String?
    public var city: String?
    public var state: String?
    public var zip: String?
    public var country: String?
    public var companyName: String?
    public var jobTitle: String?
    public var ip: String?
    public var customProperties: [String: OursPrivacyType]?
    public var consent: [String: OursPrivacyType]?

    public init(email: String? = nil,
                externalId: String? = nil,
                phoneNumber: String? = nil,
                firstName: String? = nil,
                lastName: String? = nil,
                gender: String? = nil,
                dateOfBirth: String? = nil,
                city: String? = nil,
                state: String? = nil,
                zip: String? = nil,
                country: String? = nil,
                companyName: String? = nil,
                jobTitle: String? = nil,
                ip: String? = nil,
                customProperties: [String: OursPrivacyType]? = nil,
                consent: [String: OursPrivacyType]? = nil) {
        self.email = email
        self.externalId = externalId
        self.phoneNumber = phoneNumber
        self.firstName = firstName
        self.lastName = lastName
        self.gender = gender
        self.dateOfBirth = dateOfBirth
        self.city = city
        self.state = state
        self.zip = zip
        self.country = country
        self.companyName = companyName
        self.jobTitle = jobTitle
        self.ip = ip
        self.customProperties = customProperties
        self.consent = consent
    }

    /// Maps the typed struct to the dictionary shape the composer expects.
    /// Named fields are renamed camelCase → snake_case. Nested
    /// `customProperties` / `consent` pass through untouched (the composer
    /// merges them with store defaults).
    func toWireProperties() -> Properties {
        var out: Properties = [:]
        if let email = email { out["email"] = email }
        if let externalId = externalId { out["external_id"] = externalId }
        if let phoneNumber = phoneNumber { out["phone_number"] = phoneNumber }
        if let firstName = firstName { out["first_name"] = firstName }
        if let lastName = lastName { out["last_name"] = lastName }
        if let gender = gender { out["gender"] = gender }
        if let dateOfBirth = dateOfBirth { out["date_of_birth"] = dateOfBirth }
        if let city = city { out["city"] = city }
        if let state = state { out["state"] = state }
        if let zip = zip { out["zip"] = zip }
        if let country = country { out["country"] = country }
        if let companyName = companyName { out["company_name"] = companyName }
        if let jobTitle = jobTitle { out["job_title"] = jobTitle }
        if let ip = ip { out["ip"] = ip }
        if let customProperties = customProperties { out["custom_properties"] = customProperties }
        if let consent = consent { out["consent"] = consent }
        return out
    }
}

/// Initialization-time options for ``OursPrivacy/initialize(optOutTrackingDefault:options:)``.
/// All fields are optional; pass only what you want to override at boot.
public struct OursPrivacyInitOptions {
    /// Base URL for the canonical `/ingest` endpoint. Defaults to the SDK's
    /// production CDN when omitted.
    public var serverURL: String?

    /// Override the per-install visitor ID. Equivalent to calling
    /// `setVisitorId(_:)` immediately after construction; also flips the
    /// envelope's `is_manually_set_id` flag to true.
    public var visitorId: String?

    /// URL to parse for marketing attribution at boot. The SDK runs the
    /// same UTM / click-ID extraction as ``OursPrivacy/trackDeepLink(_:)``
    /// and fires a `$deep_link_opened` event.
    public var initialURL: String?

    /// Default event properties merged into every subsequent `track` call.
    public var defaultEventProperties: [String: OursPrivacyType]?

    /// Default `userProperties.custom_properties` merged into every
    /// subsequent `identify` and `track` call.
    public var defaultUserCustomProperties: [String: OursPrivacyType]?

    /// Default `userProperties.consent` merged into every subsequent
    /// `identify` and `track` call.
    public var defaultUserConsentProperties: [String: OursPrivacyType]?

    /// If `true`, opts the visitor out on first launch. Ignored when a
    /// prior opt-in / opt-out decision is already persisted.
    public var optedOutByDefault: Bool?

    public init(serverURL: String? = nil,
                visitorId: String? = nil,
                initialURL: String? = nil,
                defaultEventProperties: [String: OursPrivacyType]? = nil,
                defaultUserCustomProperties: [String: OursPrivacyType]? = nil,
                defaultUserConsentProperties: [String: OursPrivacyType]? = nil,
                optedOutByDefault: Bool? = nil) {
        self.serverURL = serverURL
        self.visitorId = visitorId
        self.initialURL = initialURL
        self.defaultEventProperties = defaultEventProperties
        self.defaultUserCustomProperties = defaultUserCustomProperties
        self.defaultUserConsentProperties = defaultUserConsentProperties
        self.optedOutByDefault = optedOutByDefault
    }
}

/// Marketing attribution parsed from a URL by ``parseAttributionFromURL(_:)``.
public struct AttributionResult: Equatable {
    /// `utm_*` parameters present on the URL, or nil if none were found.
    public let utmParams: [String: String]?
    /// Ad-network click ID parameters present on the URL, or nil if none.
    public let clickIds: [String: String]?
    /// Cross-platform visitor ID extracted from the `ours_visitor_id` query
    /// parameter. nil when the URL has no such param.
    public let oursVisitorId: String?
    /// The original URL passed in, echoed unchanged. Empty string for nil
    /// or non-string inputs.
    public let rawURL: String

    public init(utmParams: [String: String]?,
                clickIds: [String: String]?,
                oursVisitorId: String?,
                rawURL: String) {
        self.utmParams = utmParams
        self.clickIds = clickIds
        self.oursVisitorId = oursVisitorId
        self.rawURL = rawURL
    }
}
