import Foundation
import Observation

@MainActor @Observable
final class LibraryStore {
    private(set) var apps: [LibraryApp] = []
    var downloads: [Download] = []
    var lastError: String?

    private let file = JSONFile<[LibraryApp]>("library.json")
    /// True when library.json existed but couldn't be read in full. Its folders may belong to entries this store
    /// can't see, so Clean Up leaves untracked folders alone. The original file is kept as an `.unreadable` copy.
    private(set) var indexIncomplete = false

    init() {
        apps = Self.loadApps(from: file, incomplete: &indexIncomplete)
            .filter { FileManager.default.fileExists(atPath: $0.directory.path) }
    }

    /// Decodes entries one by one, so a single bad record doesn't hide the rest of the library.
    static func loadApps(from file: JSONFile<[LibraryApp]>, incomplete: inout Bool) -> [LibraryApp] {
        guard file.exists else { return [] }
        guard let data = file.readData(),
              let entries = try? JSONDecoder().decode([Lossy<LibraryApp>].self, from: data) else {
            file.preserveUnreadable()
            incomplete = true
            return []
        }
        let apps = entries.compactMap(\.value)
        if apps.count != entries.count {
            file.preserveUnreadable()
            incomplete = true
        }
        return apps
    }

    var importedApps: [LibraryApp] { apps.filter { $0.kind == .imported }.sorted { $0.dateAdded > $1.dateAdded } }
    var signedApps: [LibraryApp] { apps.filter { $0.kind == .signed }.sorted { $0.dateAdded > $1.dateAdded } }

    func app(_ id: UUID?) -> LibraryApp? { apps.first { $0.id == id } }

    @discardableResult
    func importIPA(at url: URL, sourceURL: String? = nil, securityScoped: Bool = false) async throws -> LibraryApp {
        let accessing = securityScoped && url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let app = try await Task.detached(priority: .userInitiated) {
            try AppImporter.importIPA(at: url, sourceURL: sourceURL)
        }.value
        try addOrRemove(app)
        return app
    }

    /// Adds an app, or, if the library list can't be saved, takes it back out and deletes its folder, so it doesn't
    /// look imported now and vanish (or get cleaned up as untracked) after a relaunch.
    func addOrRemove(_ app: LibraryApp) throws {
        guard add(app) else {
            apps.removeAll { $0.id == app.id }
            try? FileManager.default.removeItem(at: app.directory)
            throw AppError("Couldn't save the library, so \(app.name) wasn't added. Free up space and try again.")
        }
    }

    /// Adds an app and saves the index. Returns false if the index couldn't be saved.
    @discardableResult
    func add(_ app: LibraryApp) -> Bool {
        apps.append(app)
        return save()
    }

    func delete(_ id: UUID) {
        guard let app = app(id) else { return }
        try? FileManager.default.removeItem(at: app.directory)
        apps.removeAll { $0.id == id }
        save()
    }

    // MARK: - Storage cleanup

    /// Removes library entries whose files were deleted elsewhere (e.g. in the Files app) and folders
    /// in Library that no entry refers to. Returns how many entries were removed.
    ///
    /// Signing and importing create their folder before the entry is added, so untracked folders
    /// modified within `gracePeriod` are left alone.
    @discardableResult
    func cleanUp(gracePeriod: TimeInterval = 60 * 60) async -> Int {
        let fm = FileManager.default
        let broken = apps.filter { app in
            switch app.kind {
            case .signed: !fm.fileExists(atPath: app.ipaURL.path)
            case .imported: !fm.fileExists(atPath: app.appURL.path)
            }
        }
        for app in broken { delete(app.id) }

        // Folders of entries that couldn't be decoded look untracked; never delete them. That holds on later
        // launches too, for as long as a preserved copy of the damaged index is around to recover them from.
        guard !indexIncomplete, !hasPreservedIndex else { return broken.count }
        let tracked = Set(apps.map { $0.directory.standardizedFileURL })
        await Task.detached(priority: .utility) {
            let fm = FileManager.default
            let folders = (try? fm.contentsOfDirectory(at: Paths.library, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for folder in folders where !tracked.contains(folder.standardizedFileURL) && folder.isOlder(than: gracePeriod) {
                try? fm.removeItem(at: folder)
            }
        }.value
        return broken.count
    }

    // MARK: - Downloads

    @MainActor @Observable
    final class Download: Identifiable {
        let id = UUID()
        let url: URL
        var name: String
        var progress: Double = 0
        var received: Int64 = 0
        var expected: Int64 = 0
        var status = "Downloading…"
        @ObservationIgnored var task: URLSessionDownloadTask?
        @ObservationIgnored var observation: NSKeyValueObservation?
        /// Called once the IPA is imported into the library. Not called if the download or import fails.
        @ObservationIgnored var onImported: ((LibraryApp) -> Void)?
        /// Called if the download fails, is cancelled, or its IPA can't be imported.
        @ObservationIgnored var onFailed: (() -> Void)?
        var isImporting = false

        init(url: URL, name: String) {
            self.url = url
            self.name = name
        }
    }

    func download(from url: URL, name: String? = nil, onImported: ((LibraryApp) -> Void)? = nil,
                  onFailed: (() -> Void)? = nil) {
        // Sources may list http links; they're fetched over https unless Allow HTTP is on. The download keeps the
        // published link, which the Get buttons and update matching look it up by.
        let request = DownloadPolicy.resolved(url)
        guard DownloadPolicy.allows(request) else {
            lastError = "App downloads require an HTTPS URL."
            onFailed?()
            return
        }
        let download = Download(url: url, name: name ?? url.lastPathComponent)
        download.onImported = onImported
        download.onFailed = onFailed
        downloads.append(download)

        let task = DownloadPolicy.session.downloadTask(with: request) { [weak self] location, response, error in
            // Move the file before this callback returns; URLSession deletes it afterwards.
            var saved: URL?
            if let location {
                let destination = Paths.temp.appendingPathComponent(UUID().uuidString + ".ipa")
                try? FileManager.default.moveItem(at: location, to: destination)
                saved = destination
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            Task { @MainActor in
                await self?.finish(download, file: saved, status: status, error: error)
            }
        }
        download.task = task
        download.observation = task.progress.observe(\.fractionCompleted) { progress, _ in
            Task { @MainActor in
                download.progress = progress.fractionCompleted
                download.received = task.countOfBytesReceived
                download.expected = task.countOfBytesExpectedToReceive
            }
        }
        task.resume()
    }

    /// The download in progress for a URL, if any.
    func download(for url: URL) -> Download? {
        downloads.first { $0.url == url }
    }

    func cancel(_ download: Download) {
        download.onFailed?()
        download.onFailed = nil
        download.task?.cancel()
        downloads.removeAll { $0.id == download.id }
    }

    private func finish(_ download: Download, file: URL?, status: Int, error: Error?) async {
        defer {
            if let file { try? FileManager.default.removeItem(at: file) }
            downloads.removeAll { $0.id == download.id }
        }
        if let error = error as? URLError, error.code == .cancelled { return }
        guard let file, error == nil, (200..<300).contains(status) else {
            download.onFailed?()
            if let urlError = error as? URLError, download.url.scheme?.lowercased() == "http", !DownloadPolicy.httpAllowed,
               DownloadPolicy.httpsUnavailable.contains(urlError.code) {
                lastError = "Couldn't download \(download.name) over HTTPS. To use HTTP, turn on Allow HTTP in Settings."
            } else {
                lastError = "Download of \(download.name) failed: \(error?.localizedDescription ?? "HTTP \(status)")"
            }
            return
        }
        download.isImporting = true
        download.status = "Importing…"
        do {
            let app = try await importIPA(at: file, sourceURL: download.url.absoluteString)
            download.onImported?(app)
        } catch {
            download.onFailed?()
            lastError = "Couldn't import \(download.name): \(error.localizedDescription)"
        }
    }

    /// A `library.unreadable-*.json` copy left by an earlier launch.
    var hasPreservedIndex: Bool {
        let folder = file.url.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return items.contains { $0.hasPrefix("library.unreadable-") }
    }

    /// Deletes saved copies of a damaged index, letting Clean Up remove untracked folders again.
    func removePreservedIndex() {
        let folder = file.url.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in items where name.hasPrefix("library.unreadable-") {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
        indexIncomplete = false
    }

    @discardableResult
    private func save() -> Bool { file.save(apps) }
}
