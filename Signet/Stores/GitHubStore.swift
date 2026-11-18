import Foundation
import Observation

/// GitHub repositories tracked for new IPA releases.
@MainActor @Observable
final class GitHubStore {
    private(set) var repos: [TrackedRepo] = []
    private(set) var caches: [UUID: GitHubReleaseCache] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []

    /// Unauthenticated GitHub API calls are limited to 60 an hour, so automatic checks are spaced out.
    static let automaticRefreshInterval: TimeInterval = 30 * 60

    private let file = JSONFile<[TrackedRepo]>("github-repos.json")
    private let cacheFile = JSONFile<[UUID: GitHubReleaseCache]>("github-releases.json")
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
        repos = file.load() ?? []
        caches = (cacheFile.load() ?? [:]).filter { id, _ in repos.contains { $0.id == id } }
    }

    func repo(_ id: UUID?) -> TrackedRepo? { repos.first { $0.id == id } }

    /// The tracked repo an app was downloaded from, if any. Signed copies keep the original download URL.
    func repo(for app: LibraryApp) -> TrackedRepo? {
        guard let sourceURL = app.sourceURL else { return nil }
        return repos.first { GitHub.isDownload(sourceURL, from: $0) }
    }

    func releases(for repo: TrackedRepo) -> [GitHubRelease] {
        GitHub.visibleReleases(caches[repo.id]?.releases ?? [], for: repo)
    }

    func latest(for repo: TrackedRepo) -> (release: GitHubRelease, asset: GitHubAsset)? {
        GitHub.latest(in: caches[repo.id]?.releases ?? [], for: repo)
    }

    /// IPA names offered when choosing which one to track.
    func assetNames(for repo: TrackedRepo) -> [String] {
        var seen = Set<String>()
        return releases(for: repo).prefix(3).flatMap(\.ipaAssets).map(\.name)
            .filter { seen.insert(GitHub.assetKey($0)).inserted }
    }

    /// Whether an asset is in the library or downloading.
    func isInLibrary(_ asset: GitHubAsset, library: LibraryStore) -> Bool {
        let url = asset.browserDownloadUrl
        return library.apps.contains { $0.sourceURL == url.absoluteString } || library.downloads.contains { $0.url == url }
    }

    func status(of repo: TrackedRepo, in library: LibraryStore) -> GitHub.UpdateState {
        let latest = latest(for: repo)
        return GitHub.updateState(
            latest: latest?.asset.browserDownloadUrl,
            lastDownloaded: repo.lastDownloadedURL,
            inLibrary: latest.map { isInLibrary($0.asset, library: library) } ?? false,
            hasOlderInLibrary: library.apps.contains { $0.sourceURL.map { GitHub.isDownload($0, from: repo) } ?? false }
        )
    }

    func updateCount(in library: LibraryStore) -> Int {
        repos.filter { status(of: $0, in: library) == .updateAvailable }.count
    }

    // MARK: - Editing

    @discardableResult
    func add(_ input: String) async throws -> TrackedRepo {
        guard let parsed = GitHub.parseRepository(input) else {
            throw AppError("Enter a repo like owner/repo, or its GitHub link.")
        }
        let info = try await fetchRepository(owner: parsed.owner, name: parsed.name)
        // Use GitHub's spelling so download URLs match regardless of how the repo was typed.
        guard !repos.contains(where: { $0.fullName.caseInsensitiveCompare(info.fullName) == .orderedSame }) else {
            throw AppError("\(info.fullName) is already tracked.")
        }
        let parts = info.fullName.split(separator: "/").map(String.init)
        var repo = TrackedRepo(owner: parts.first ?? parsed.owner, name: parts.count > 1 ? parts[1] : parsed.name)
        repo.summary = info.description
        repo.avatarURL = info.owner?.avatarUrl
        if repo.fullName.caseInsensitiveCompare(GitHub.signetRepository) == .orderedSame {
            repo.bundleID = Bundle.main.bundleIdentifier
        }
        repos.append(repo)
        save()
        await refresh(repo)
        return repo
    }

    /// Adds repos restored from a backup, skipping ones already tracked. Their releases are fetched on the next check.
    @discardableResult
    func restore(_ restored: [TrackedRepo]) -> Int {
        let new = restored.filter { repo in
            !repos.contains { $0.id == repo.id || $0.fullName.caseInsensitiveCompare(repo.fullName) == .orderedSame }
        }
        guard !new.isEmpty else { return 0 }
        repos.append(contentsOf: new)
        save()
        return new.count
    }

    func update(_ repo: TrackedRepo) {
        guard let index = repos.firstIndex(where: { $0.id == repo.id }), repos[index] != repo else { return }
        repos[index] = repo
        save()
    }

    func delete(_ id: UUID) {
        repos.removeAll { $0.id == id }
        caches[id] = nil
        errors[id] = nil
        save()
        cacheFile.save(caches)
    }

    // MARK: - Checking for releases

    /// Fetches releases, then downloads the newest IPA when the repo auto-downloads and the library lacks it.
    func refresh(_ repo: TrackedRepo, library: LibraryStore? = nil) async {
        guard !loading.contains(repo.id) else { return }
        loading.insert(repo.id)
        defer { loading.remove(repo.id) }
        do {
            let cached = caches[repo.id]
            let (releases, etag) = try await fetchReleases(of: repo, etag: cached?.releases.isEmpty == false ? cached?.etag : nil)
            caches[repo.id] = GitHubReleaseCache(releases: releases ?? cached?.releases ?? [], etag: etag ?? cached?.etag, checkedAt: Date())
            errors[repo.id] = nil
            cacheFile.save(caches)
        } catch {
            errors[repo.id] = error.localizedDescription
        }
        if let library { autoDownloadIfNeeded(repo.id, library: library) }
    }

    /// Checks every repo. Without `force`, skips repos checked within `automaticRefreshInterval`.
    func refreshAll(force: Bool = false, library: LibraryStore? = nil) async {
        let due = repos.filter { repo in
            force || (caches[repo.id]?.checkedAt).map { Date().timeIntervalSince($0) >= Self.automaticRefreshInterval } ?? true
        }
        await withTaskGroup(of: Void.self) { group in
            for repo in due {
                group.addTask { await self.refresh(repo, library: library) }
            }
        }
    }

    func download(_ asset: GitHubAsset, from release: GitHubRelease, of repo: TrackedRepo, library: LibraryStore) {
        guard !library.downloads.contains(where: { $0.url == asset.browserDownloadUrl }) else { return }
        let repoID = repo.id
        library.download(from: asset.browserDownloadUrl, name: "\(repo.name) \(release.tagName)",
                         onImported: { [weak self] _ in self?.markDownloaded(asset, repoID: repoID) },
                         onFailed: { [weak self] in self?.markFailed(asset, repoID: repoID) })
    }

    /// Records a successfully imported download. Set only after the import, so a failed or cancelled download is
    /// retried by the next automatic check. Only the newest release moves the marker, so downloading an old version
    /// doesn't hide an update.
    func markDownloaded(_ asset: GitHubAsset, repoID: UUID) {
        guard var current = repo(repoID), latest(for: current)?.asset.id == asset.id else { return }
        current.lastDownloadedURL = asset.browserDownloadUrl
        current.failedDownloadURL = nil
        update(current)
    }

    /// Records a failed or cancelled download so automatic checks don't keep fetching it.
    func markFailed(_ asset: GitHubAsset, repoID: UUID) {
        guard var current = repo(repoID) else { return }
        current.failedDownloadURL = asset.browserDownloadUrl
        update(current)
    }

    private func autoDownloadIfNeeded(_ id: UUID, library: LibraryStore) {
        guard let repo = repo(id), let latest = latest(for: repo),
              GitHub.shouldAutoDownload(repo, latest: latest.asset.browserDownloadUrl,
                                        inLibrary: isInLibrary(latest.asset, library: library)) else { return }
        download(latest.asset, from: latest.release, of: repo, library: library)
    }

    // MARK: - API

    private struct RepositoryInfo: Decodable {
        struct Owner: Decodable { var avatarUrl: URL? }
        var fullName: String
        var description: String?
        var owner: Owner?
    }

    private func fetchRepository(owner: String, name: String) async throws -> RepositoryInfo {
        let (data, _) = try await get("repos/\(owner)/\(name)", etag: nil)
        guard let data else { throw AppError("GitHub returned an empty response.") }
        return try GitHub.decoder.decode(RepositoryInfo.self, from: data)
    }

    /// Returns nil releases when GitHub says nothing changed since `etag`.
    private func fetchReleases(of repo: TrackedRepo, etag: String?) async throws -> ([GitHubRelease]?, String?) {
        let (data, response) = try await get("repos/\(repo.owner)/\(repo.name)/releases?per_page=20", etag: etag)
        let newTag = response.value(forHTTPHeaderField: "ETag")
        guard let data else { return (nil, newTag) }
        do {
            return (try GitHub.decodeReleases(data), newTag)
        } catch {
            throw AppError("Couldn't read GitHub's list of releases.")
        }
    }

    /// GET against the GitHub API. Data is nil for 304 Not Modified.
    private func get(_ path: String, etag: String?) async throws -> (Data?, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: "https://api.github.com/" + path)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Signet", forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        // ETags do the caching; URLCache would hide 304s and serve stale lists.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AppError("GitHub didn't respond.") }
        switch http.statusCode {
        case 200..<300: return (data, http)
        case 304: return (nil, http)
        case 404: throw AppError("Repo not found. Private repos aren't supported.")
        case 403, 429:
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" || http.statusCode == 429 {
                let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
                let when = reset.map { " Try again after \($0.formatted(date: .omitted, time: .shortened))." } ?? " Try again later."
                throw AppError("GitHub's hourly limit was reached." + when)
            }
            throw AppError("GitHub refused the request (HTTP \(http.statusCode)).")
        default:
            throw AppError("GitHub returned HTTP \(http.statusCode).")
        }
    }

    private func save() { file.save(repos) }
}
