import Foundation

/// A newer version of a library app offered by one of the user's sources.
struct SourceUpdate: Identifiable, Hashable {
    /// The app's original bundle ID, which stays the same however it was re-signed.
    let bundleID: String
    let name: String
    let localVersion: String
    let remoteVersion: String
    let downloadURL: URL
    let sourceName: String
    let iconURL: URL?
    var id: String { bundleID }
}

/// Matches library apps to source apps and finds newer versions.
enum SourceUpdates {
    /// Compares version strings numerically, so 1.10 is newer than 1.9 and "v2.0" equals "2.0".
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        normalize(lhs).compare(normalize(rhs), options: [.numeric, .caseInsensitive])
    }

    private static func normalize(_ version: String) -> String {
        var trimmed = version.trimmingCharacters(in: .whitespaces)
        if trimmed.first == "v" || trimmed.first == "V" { trimmed.removeFirst() }
        // "2.0" and "2" are the same version.
        while trimmed.hasSuffix(".0") { trimmed.removeLast(2) }
        return trimmed
    }

    /// The bundle ID an app is grouped under: the one it was imported with, before any re-signing.
    static func key(for app: LibraryApp) -> String {
        app.originalBundleID ?? app.bundleID
    }

    /// Finds updates for library apps.
    /// - Parameters:
    ///   - library: every library app; versions of the same app (imported or signed) are grouped by original bundle ID.
    ///   - offers: apps from the user's sources, with the source they came from.
    ///   - excluded: original bundle IDs to skip, e.g. apps tracked through GitHub instead.
    /// - Returns: one update per app, keyed by original bundle ID.
    static func find(library: [LibraryApp], offers: [(sourceName: String, app: SourceApp)],
                     excluded: Set<String> = []) -> [String: SourceUpdate] {
        let groups = Dictionary(grouping: library, by: key(for:))
        var byBundleID: [String: [(sourceName: String, app: SourceApp)]] = [:]
        for offer in offers {
            guard let id = offer.app.bundleIdentifier, offer.app.latestDownloadURL != nil, offer.app.latestVersion != nil else { continue }
            byBundleID[id, default: []].append(offer)
        }

        var updates: [String: SourceUpdate] = [:]
        for (bundleID, apps) in groups where !excluded.contains(bundleID) {
            guard let candidates = byBundleID[bundleID],
                  let local = apps.map(\.version).max(by: { compare($0, $1) == .orderedAscending }) else { continue }
            // Prefer the source the app was downloaded from; otherwise the one offering the newest version.
            let sourceURLs = Set(apps.compactMap(\.sourceURL))
            let fromSameSource = candidates.filter { offer in
                (offer.app.versions ?? []).contains { $0.downloadURL.map { sourceURLs.contains($0.absoluteString) } ?? false }
                    || offer.app.downloadURL.map { sourceURLs.contains($0.absoluteString) } ?? false
            }
            let pool = fromSameSource.isEmpty ? candidates : fromSameSource
            guard let best = pool.max(by: { compare($0.app.latestVersion!, $1.app.latestVersion!) == .orderedAscending }),
                  let remote = best.app.latestVersion, let url = best.app.latestDownloadURL,
                  compare(remote, local) == .orderedDescending else { continue }
            updates[bundleID] = SourceUpdate(
                bundleID: bundleID, name: best.app.name, localVersion: local, remoteVersion: remote,
                downloadURL: url, sourceName: best.sourceName, iconURL: best.app.iconURL)
        }
        return updates
    }
}
