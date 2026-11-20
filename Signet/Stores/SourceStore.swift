import Foundation
import Observation

@MainActor @Observable
final class SourceStore {
    private(set) var sources: [SavedSource] = []
    private(set) var repositories: [UUID: SourceRepository] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []
    private var lastRefresh: Date?

    /// Sources are checked for updates when Signet opens, at most this often.
    static let automaticRefreshInterval: TimeInterval = 15 * 60

    private let file = JSONFile<[SavedSource]>("sources.json")

    /// Signet's own source, added once on first launch so Signet's updates show up like any other app's.
    static let signetSourceURL = URL(string: "https://and101.github.io/Signet/source.json")!
    private static let seededKey = "addedSignetSource"

    init() {
        sources = file.load() ?? []
        addSignetSourceOnce()
    }

    /// Adds Signet's source the first time Signet runs (or after an update from a version without it). If the user
    /// deletes it, it stays deleted.
    private func addSignetSourceOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.seededKey) else { return }
        defaults.set(true, forKey: Self.seededKey)
        guard !sources.contains(where: { $0.url == Self.signetSourceURL }) else { return }
        sources.insert(SavedSource(url: Self.signetSourceURL, name: "Signet",
                                   iconURL: URL(string: "https://and101.github.io/Signet/icon.png")), at: 0)
        save()
    }

    func add(_ urlString: String) async throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        // Saved as typed; fetch resolves it, so an http source works again if Allow HTTP is turned on later.
        guard let url = URL(string: trimmed), DownloadPolicy.allows(DownloadPolicy.resolved(url)) else {
            throw AppError(DownloadPolicy.httpAllowed ? "Enter a valid web URL." : "Enter a valid HTTPS URL.")
        }
        guard !sources.contains(where: { DownloadPolicy.upgraded($0.url) == DownloadPolicy.upgraded(url) }) else {
            throw AppError("That source is already added.")
        }
        let repo = try await Self.fetch(url)
        // Another add may have finished while this one was fetching.
        guard !sources.contains(where: { DownloadPolicy.upgraded($0.url) == DownloadPolicy.upgraded(url) }) else {
            throw AppError("That source is already added.")
        }
        let source = SavedSource(url: url, name: repo.name ?? url.host ?? "Source", iconURL: repo.iconURL)
        sources.append(source)
        repositories[source.id] = repo
        save()
    }

    /// Adds sources restored from a backup, skipping URLs that are already added. Returns how many were added.
    @discardableResult
    func restore(_ restored: [SavedSource]) -> Int {
        // Compared as https, and against what this restore has already accepted, so a backup holding both the http
        // and https spelling of a source adds it once.
        var urls = Set(sources.map { DownloadPolicy.upgraded($0.url) })
        var ids = Set(sources.map(\.id))
        let new = restored.filter { source in
            let url = DownloadPolicy.upgraded(source.url)
            // Check both before reserving either, so a rejected record doesn't block a later valid one.
            guard !urls.contains(url), !ids.contains(source.id) else { return false }
            urls.insert(url)
            ids.insert(source.id)
            return true
        }
        guard !new.isEmpty else { return 0 }
        sources.append(contentsOf: new)
        save()
        return new.count
    }

    func delete(_ id: UUID) {
        sources.removeAll { $0.id == id }
        repositories[id] = nil
        save()
    }

    func refresh(_ source: SavedSource) async {
        loading.insert(source.id)
        defer { loading.remove(source.id) }
        do {
            repositories[source.id] = try await Self.fetch(source.url)
            errors[source.id] = nil
        } catch {
            errors[source.id] = error.localizedDescription
        }
    }

    /// Refreshes every source unless that was done within `automaticRefreshInterval`.
    func refreshIfStale() async {
        if let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.automaticRefreshInterval { return }
        await refreshAll()
    }

    func refreshAll() async {
        lastRefresh = Date()
        await withTaskGroup(of: Void.self) { group in
            for source in sources {
                group.addTask { await self.refresh(source) }
            }
        }
    }

    var allApps: [(source: SavedSource, app: SourceApp)] {
        sources.flatMap { source in
            (repositories[source.id]?.apps ?? []).map { (source, $0) }
        }
    }

    /// Newer versions of library apps offered by these sources, sorted by name. Apps tracked through a
    /// GitHub repo are left out; the repo reports their updates.
    func updates(for library: LibraryStore, github: GitHubStore) -> [SourceUpdate] {
        let tracked = Set(library.apps.filter { github.repo(for: $0) != nil }.map(SourceUpdates.key(for:)))
        let offers = allApps.map { (sourceName: $0.source.name, app: $0.app) }
        return SourceUpdates.find(library: library.apps, offers: offers, excluded: tracked).values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Off the main actor: the body is read a byte at a time to enforce the limit, which on the main actor costs a
    /// hop per byte (seconds for a few megabytes). The decoded repository is published by the callers.
    nonisolated private static func fetch(_ saved: URL) async throws -> SourceRepository {
        let url = DownloadPolicy.resolved(saved)
        guard DownloadPolicy.allows(url) else { throw AppError("Sources require an HTTPS URL.") }
        var data = Data()
        let response: URLResponse
        do {
            // Read with a limit: a misconfigured source serving something huge would otherwise fill memory.
            let (bytes, received) = try await DownloadPolicy.session.bytes(from: url)
            response = received
            guard received.expectedContentLength <= Self.responseLimit else { throw AppError("This source is too large.") }
            if received.expectedContentLength > 0 { data.reserveCapacity(Int(received.expectedContentLength)) }
            for try await byte in bytes {
                guard data.count < Self.responseLimit else { throw AppError("This source is too large.") }
                data.append(byte)
            }
        } catch let error as URLError where url != saved && DownloadPolicy.httpsUnavailable.contains(error.code) {
            // Only failures that suggest the server has no working HTTPS; offline and the like pass through.
            throw AppError("Couldn't reach this source over HTTPS. To use HTTP, turn on Allow HTTP in Settings.")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError("HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(SourceRepository.self, from: data)
        } catch {
            throw AppError("Not a valid AltStore-style source.")
        }
    }

    /// Far above any real source (large ones are a few megabytes of JSON).
    nonisolated static let responseLimit = 32 * 1024 * 1024


    private func save() { file.save(sources) }
}
