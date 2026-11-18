import Foundation

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

    static func allowed(_ value: String, by patterns: [String]) -> Bool {
        patterns.contains { pattern in
            pattern.hasSuffix("*") ? value.hasPrefix(pattern.dropLast()) : value == pattern
        }
    }
}
