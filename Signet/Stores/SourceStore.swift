import Foundation
import Observation

@MainActor @Observable
final class SourceStore {
    private(set) var sources: [SavedSource] = []
    private(set) var repositories: [UUID: SourceRepository] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []

    private let file = JSONFile<[SavedSource]>("sources.json")

    init() {
        sources = file.load() ?? []
    }

    func add(_ urlString: String) async throws {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.hasPrefix("http") == true else {
            throw AppError("Enter a valid http(s) URL.")
        }
        guard !sources.contains(where: { $0.url == url }) else {
            throw AppError("That source is already added.")
        }
        let repo = try await Self.fetch(url)
        let source = SavedSource(url: url, name: repo.name ?? url.host ?? "Source", iconURL: repo.iconURL)
        sources.append(source)
        repositories[source.id] = repo
        save()
    }

    /// Adds sources restored from a backup, skipping URLs that are already added. Returns how many were added.
    @discardableResult
    func restore(_ restored: [SavedSource]) -> Int {
        let new = restored.filter { source in !sources.contains { $0.url == source.url || $0.id == source.id } }
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

    func refreshAll() async {
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

    private static func fetch(_ url: URL) async throws -> SourceRepository {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AppError("HTTP \(http.statusCode)")
        }
        do {
            return try JSONDecoder().decode(SourceRepository.self, from: data)
        } catch {
            throw AppError("Not a valid AltStore-style source.")
        }
    }

    private func save() { file.save(sources) }
}
