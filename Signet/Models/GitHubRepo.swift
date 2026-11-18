import Foundation

/// A GitHub repository whose releases are tracked for new IPAs.
struct TrackedRepo: Codable, Identifiable, Hashable {
    var id = UUID()
    var owner: String
    var name: String
    var summary: String?
    var avatarURL: URL?
    var dateAdded = Date()

    /// Name of the IPA to use when a release has several (e.g. `UTM.ipa` vs `UTM-SE.ipa`).
    /// Version numbers in the name are ignored when matching. Nil picks the first IPA.
    var assetName: String?
    var includePrereleases = false
    /// Download new releases into the library when they're found.
    var autoDownload = false
    /// The last IPA downloaded from this repo, so a deleted or failed download isn't fetched again automatically.
    var lastDownloadedURL: URL?
    /// The last release whose download failed or was cancelled. Automatic checks don't retry it.
    var failedDownloadURL: URL?

    // Signing defaults for apps downloaded from this repo
    var bundleID: String?
    var certificateID: UUID?

    var fullName: String { "\(owner)/\(name)" }

    /// The repo name, or the owner when the name is generic (`NeoFreeBird/app` shows as NeoFreeBird).
    var displayName: String {
        let generic: Set<String> = ["app", "apps", "ios", "ipa", "iphone", "mobile", "client", "release", "releases"]
        return generic.contains(name.lowercased()) ? owner : name
    }
    var webURL: URL { URL(string: "https://github.com/\(owner)/\(name)")! }

    /// Trimmed default bundle ID, nil when unset.
    var defaultBundleID: String? {
        let trimmed = (bundleID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    /// Decodes missing keys as defaults, so fields added later don't fail older saved repos.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        owner = try c.decode(String.self, forKey: .owner)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        avatarURL = try c.decodeIfPresent(URL.self, forKey: .avatarURL)
        dateAdded = try c.decodeIfPresent(Date.self, forKey: .dateAdded) ?? Date()
        assetName = try c.decodeIfPresent(String.self, forKey: .assetName)
        includePrereleases = try c.decodeIfPresent(Bool.self, forKey: .includePrereleases) ?? false
        autoDownload = try c.decodeIfPresent(Bool.self, forKey: .autoDownload) ?? false
        lastDownloadedURL = try c.decodeIfPresent(URL.self, forKey: .lastDownloadedURL)
        failedDownloadURL = try c.decodeIfPresent(URL.self, forKey: .failedDownloadURL)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        certificateID = try c.decodeIfPresent(UUID.self, forKey: .certificateID)
    }
}

struct GitHubRelease: Codable, Hashable, Identifiable {
    var id: Int
    var tagName: String
    var name: String?
    var body: String?
    var draft: Bool
    var prerelease: Bool
    var publishedAt: Date?
    var htmlUrl: URL?
    var assets: [GitHubAsset]

    var title: String {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? tagName : trimmed
    }

    var ipaAssets: [GitHubAsset] { assets.filter(\.isIPA) }
}

struct GitHubAsset: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var size: Int64
    var browserDownloadUrl: URL

    var isIPA: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ext == "ipa" || ext == "tipa"
    }
}

/// Last fetched releases for a repo, kept on disk so the ETag can skip unchanged responses.
struct GitHubReleaseCache: Codable {
    var releases: [GitHubRelease]
    var etag: String?
    var checkedAt: Date
}

enum GitHub {
    /// Signet's own repository. Tracking it fills in the bundle ID Signet is installed with, so signing an update
    /// installs it over the current copy and keeps its data.
    static let signetRepository = "and101/Signet"

    /// Accepts `owner/repo`, `github.com/owner/repo`, full URLs (with `.git`, `/releases`, …) and SSH remotes.
    static func parseRepository(_ input: String) -> (owner: String, name: String)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("git@github.com:") {
            text = String(text.dropFirst("git@github.com:".count))
        } else if let range = text.range(of: "github.com/", options: .caseInsensitive) {
            text = String(text[range.upperBound...])
        } else if text.contains("://") {
            return nil // some other host
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        let owner = parts[0]
        var name = parts[1].components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? ""
        if name.lowercased().hasSuffix(".git") { name = String(name.dropLast(4)) }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !owner.isEmpty, !name.isEmpty,
              owner.unicodeScalars.allSatisfy(allowed.contains),
              name.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return (owner, name)
    }

    /// Release downloads look like `https://github.com/{owner}/{repo}/releases/download/{tag}/{file}`.
    static func repository(ofDownloadURL url: String) -> (owner: String, name: String)? {
        guard let components = URLComponents(string: url),
              components.host?.lowercased() == "github.com" else { return nil }
        let parts = components.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "releases", parts[3] == "download" else { return nil }
        return (parts[0], parts[1])
    }

    /// Picks the IPA matching `preferred` (ignoring version numbers), or the first IPA.
    /// Returns nil when a preference is set and nothing matches, so a different app isn't downloaded.
    static func preferredAsset(in release: GitHubRelease, named preferred: String?) -> GitHubAsset? {
        let ipas = release.ipaAssets
        guard let preferred, !preferred.isEmpty else { return ipas.first }
        if let exact = ipas.first(where: { $0.name.caseInsensitiveCompare(preferred) == .orderedSame }) {
            return exact
        }
        let key = assetKey(preferred)
        return ipas.first { assetKey($0.name) == key }
    }

    /// `MyApp_v1.2.3.ipa` → `myapp_#.ipa`, so a renamed-per-version asset still matches.
    static func assetKey(_ name: String) -> String {
        name.lowercased().replacingOccurrences(of: #"v?\d+(\.\d+)*"#, with: "#", options: .regularExpression)
    }

    /// Whether an app downloaded from `url` came from `repo`. When the repo follows one of several IPAs,
    /// only that IPA counts, so a sibling app (e.g. UTM SE next to UTM) doesn't get its signing defaults.
    static func isDownload(_ url: String, from repo: TrackedRepo) -> Bool {
        guard let parsed = repository(ofDownloadURL: url),
              parsed.owner.caseInsensitiveCompare(repo.owner) == .orderedSame,
              parsed.name.caseInsensitiveCompare(repo.name) == .orderedSame else { return false }
        guard let preferred = repo.assetName, !preferred.isEmpty else { return true }
        let file = URL(string: url)?.lastPathComponent.removingPercentEncoding ?? ""
        return assetKey(file) == assetKey(preferred)
    }

    enum UpdateState: Equatable {
        /// The newest release is in the library or was already downloaded.
        case upToDate
        /// An older release was downloaded before.
        case updateAvailable
        /// Nothing from this repo has been downloaded yet.
        case notDownloaded
        /// No release has a matching IPA.
        case noIPA
    }

    /// - Parameters:
    ///   - latest: download URL of the newest matching IPA.
    ///   - lastDownloaded: the repo's last downloaded IPA.
    ///   - inLibrary: whether the newest IPA is in the library or downloading.
    ///   - hasOlderInLibrary: whether any app from this repo is in the library.
    static func updateState(latest: URL?, lastDownloaded: URL?, inLibrary: Bool, hasOlderInLibrary: Bool) -> UpdateState {
        guard let latest else { return .noIPA }
        if inLibrary || lastDownloaded == latest { return .upToDate }
        return lastDownloaded != nil || hasOlderInLibrary ? .updateAvailable : .notDownloaded
    }

    /// Auto-download fetches each new release once; deleting it from the library doesn't bring it back, and a
    /// release that failed to download or import isn't retried until a newer one comes out.
    static func shouldAutoDownload(_ repo: TrackedRepo, latest: URL?, inLibrary: Bool) -> Bool {
        guard repo.autoDownload, let latest else { return false }
        return !inLibrary && repo.lastDownloadedURL != latest && repo.failedDownloadURL != latest
    }

    /// Releases worth showing for a repo, newest first.
    static func visibleReleases(_ releases: [GitHubRelease], for repo: TrackedRepo) -> [GitHubRelease] {
        releases
            .filter { !$0.draft && (repo.includePrereleases || !$0.prerelease) && !$0.ipaAssets.isEmpty }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
    }

    /// The newest release that has the repo's chosen IPA.
    static func latest(in releases: [GitHubRelease], for repo: TrackedRepo) -> (release: GitHubRelease, asset: GitHubAsset)? {
        for release in visibleReleases(releases, for: repo) {
            if let asset = preferredAsset(in: release, named: repo.assetName) { return (release, asset) }
        }
        return nil
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Decodes a releases response, skipping malformed entries.
    static func decodeReleases(_ data: Data) throws -> [GitHubRelease] {
        try decoder.decode([Lossy<GitHubRelease>].self, from: data).compactMap(\.value)
    }
}
