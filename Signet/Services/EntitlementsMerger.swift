import Foundation
import CoreFoundation

/// Builds the entitlements to sign with when "Merge App Entitlements" is on: the profile's entitlements,
/// with the app's own values swapped in wherever the profile allows them.
///
/// A signature may only claim what the profile grants, so keys the profile lacks are dropped, and app
/// values are kept only if they match the profile (a trailing `*` in a profile value is a wildcard).
/// App values that start with the app's original team ID are moved to the signing team first, so an app's
/// `OLDTEAM.com.app.shared` keychain group becomes `NEWTEAM.com.app.shared` under a `NEWTEAM.*` profile.
enum EntitlementsMerger {
    /// Left as the profile has them: zsign expands a wildcard application identifier per executable,
    /// which a concrete value from the main app would break for extensions.
    private static let profileOwned: Set<String> = [
        "application-identifier", "com.apple.developer.team-identifier", "get-task-allow",
        "aps-environment", "beta-reports-active",
    ]

    static func merge(profile: [String: Any], app: [String: Any], teamID: String) -> [String: Any] {
        let appTeam = (app["com.apple.developer.team-identifier"] as? String)
            ?? (app["application-identifier"] as? String)?.split(separator: ".").first.map(String.init)
        func moveTeam(_ value: String) -> String {
            guard let appTeam, !appTeam.isEmpty, appTeam != teamID, value.hasPrefix(appTeam + ".") else { return value }
            return teamID + value.dropFirst(appTeam.count)
        }

        var result = profile
        for (key, appValue) in app where !profileOwned.contains(key) {
            guard let profileValue = profile[key] else { continue }
            let patterns = (profileValue as? [String]) ?? (profileValue as? String).map { [$0] }
            guard let patterns else { continue } // booleans and dictionaries stay as the profile grants them

            if let values = appValue as? [String] {
                let merged = values.map(moveTeam).filter { allowed($0, by: patterns) }
                    .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                if !merged.isEmpty { result[key] = merged }
            } else if let value = appValue as? String {
                let moved = moveTeam(value)
                if allowed(moved, by: patterns) { result[key] = moved }
            }
        }
        return result
    }

    /// Reads an entitlements plist picked by the user, or remembered with an app (possibly from a backup). Only a regular
    /// file within the plist limit is read, before decoding; zsign reads the same file later.
    static func read(_ url: URL) throws -> [String: Any] {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= AppImporter.plistLimit else {
            throw AppError("\(url.lastPathComponent) isn't a readable entitlements file, or it's too large.")
        }
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw AppError("\(url.lastPathComponent) isn't an entitlements file. It should be a plist dictionary.")
        }
        guard isSignable(plist) else {
            throw AppError("\(url.lastPathComponent) has a date, decimal or data value, which entitlements can't hold.")
        }
        return plist
    }

    /// Whether a value is a kind entitlements can hold: text, true/false, whole numbers, arrays and dictionaries.
    private static func isSignable(_ value: Any) -> Bool {
        switch value {
        case is String: return true
        case let number as NSNumber:
            return CFGetTypeID(number) == CFBooleanGetTypeID() || !CFNumberIsFloatType(number)
        case let array as [Any]: return array.allSatisfy(isSignable)
        case let dictionary as [String: Any]: return dictionary.values.allSatisfy(isSignable)
        default: return false
        }
    }

    /// Entitlements a custom file claims that the profile doesn't grant. iOS refuses to install an app that claims
    /// more than its profile allows. A key turned off (`false`) claims nothing, so it's left out.
    static func ungranted(_ custom: [String: Any], profile: [String: Any]) -> [String] {
        custom.compactMap { key, value in
            if let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID(), !flag.boolValue { return nil }
            guard let grant = profile[key], permitted(value, by: grant) else { return key }
            return nil
        }
        .sorted()
    }

    private static func permitted(_ value: Any, by grant: Any) -> Bool {
        // A bare "*" grants any string; profiles use it for keys like associated-domains and icloud-services.
        if let requested = value as? [String], grant is String {
            return requested.allSatisfy { permitted($0, by: grant) }
        }
        if value is [Any], grant is String { return false } // only a flat list of strings can match a pattern
        if let requested = value as? String, let grants = grant as? [Any] {
            return grants.contains { permitted(requested, by: $0) }
        }
        if let requested = value as? String, let pattern = grant as? String {
            return allowed(requested, by: [pattern])
        }
        if let requested = value as? [Any], let grants = grant as? [Any] {
            // Patterns only match strings, so against a list of strings every requested item must be a string.
            if grants is [String], !(requested is [String]) { return false }
            return requested.allSatisfy { item in grants.contains { permitted(item, by: $0) } }
        }
        if let requested = value as? [String: Any], let grants = grant as? [String: Any] {
            return requested.allSatisfy { key, item in grants[key].map { permitted(item, by: $0) } ?? false }
        }
        if let requested = value as? NSNumber, let granted = grant as? NSNumber {
            guard CFGetTypeID(requested) == CFGetTypeID(granted) else { return false }
            return requested == granted
        }
        return false
    }

    static func allowed(_ value: String, by patterns: [String]) -> Bool {
        patterns.contains { pattern in
            pattern.hasSuffix("*") ? value.hasPrefix(pattern.dropLast()) : value == pattern
        }
    }
}
