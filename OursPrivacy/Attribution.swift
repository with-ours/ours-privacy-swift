//
//  Attribution.swift
//  OursPrivacy
//
//  Copyright © 2026 Ours Wellness Inc. All rights reserved.
//

import Foundation

/// Marketing attribution parameters extracted from deep links. Both lists
/// match the typed fields the ingest API accepts in `defaultProperties` —
/// any other query parameters are not exposed by ``parseAttributionFromURL(_:)``.
private let utmParams: [String] = [
    "utm_campaign",
    "utm_content",
    "utm_medium",
    "utm_name",
    "utm_source",
    "utm_term",
]

private let clickIds: [String] = [
    "alart",
    "aleid",
    "axwrt",
    "basis_cid",
    "clickid",
    "clid",
    "dclid",
    "epik",
    "fbc",
    "fbclid",
    "fbp",
    "gad_source",
    "gbraid",
    "gclid",
    "im_ref",
    "irclickid",
    "li_fat_id",
    "msclkid",
    "ndclid",
    "qclid",
    "rdt_cid",
    "sacid",
    "sccid",
    "ttclid",
    "twclid",
    "wbraid",
]

private let oursVisitorIdParam = "ours_visitor_id"

/// Parse marketing-attribution parameters from a deep-link URL.
///
/// The function pulls UTM parameters, ad-network click IDs, and the
/// cross-platform `ours_visitor_id` (when present) from the query string.
/// Unknown query keys are ignored — every returned field is something the
/// ingest API stores in a dedicated column under `defaultProperties`.
///
/// `rawURL` echoes the input verbatim (empty string when the input has no
/// query component or fails to parse).
public func parseAttributionFromURL(_ url: String) -> AttributionResult {
    let query = parseQueryParams(url)
    return AttributionResult(
        utmParams: extractKeys(query, keys: utmParams),
        clickIds: extractKeys(query, keys: clickIds),
        oursVisitorId: query[oursVisitorIdParam].flatMap { $0.isEmpty ? nil : $0 },
        rawURL: url
    )
}

private func parseQueryParams(_ url: String) -> [String: String] {
    guard !url.isEmpty,
          let questionMark = url.firstIndex(of: "?") else {
        return [:]
    }
    let afterQ = url.index(after: questionMark)
    var queryString = String(url[afterQ...])
    if let hash = queryString.firstIndex(of: "#") {
        queryString = String(queryString[..<hash])
    }

    var params: [String: String] = [:]
    for pair in queryString.split(separator: "&", omittingEmptySubsequences: true) {
        guard let eq = pair.firstIndex(of: "=") else { continue }
        let key = String(pair[..<eq])
        let rawValue = String(pair[pair.index(after: eq)...])
        let spaceFixed = rawValue.replacingOccurrences(of: "+", with: " ")
        let decoded = spaceFixed.removingPercentEncoding ?? rawValue
        params[key] = decoded
    }
    return params
}

private func extractKeys(_ source: [String: String], keys: [String]) -> [String: String]? {
    var out: [String: String] = [:]
    for key in keys {
        if let value = source[key], !value.isEmpty {
            out[key] = value
        }
    }
    return out.isEmpty ? nil : out
}
