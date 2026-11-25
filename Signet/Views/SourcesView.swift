import SwiftUI

struct SourcesView: View {
    @Environment(SourceStore.self) private var store
    @Environment(GitHubStore.self) private var github
    @Environment(LibraryStore.self) private var library
    @State private var showAdd = false
    @State private var showAddRepo = false
    @State private var urlText = ""
    @State private var repoText = ""
    @State private var adding = false
    @State private var error: String?
    @State private var sourceToDelete: SavedSource?
    @State private var repoToDelete: TrackedRepo?

    var body: some View {
        NavigationStack {
            List {
                if !store.sources.isEmpty {
                    Section {
                        NavigationLink {
                            SourceAppsView(title: "All Apps", sourceIDs: nil)
                        } label: {
                            Label("All Apps", systemImage: "square.grid.2x2")
                        }
                    }
                }
                Section {
                    ForEach(store.sources) { source in
                        NavigationLink {
                            SourceAppsView(title: source.name, sourceIDs: [source.id])
                        } label: {
                            HStack(spacing: 12) {
                                RemoteIcon(url: store.repositories[source.id]?.iconURL ?? source.iconURL, size: 40)
                                VStack(alignment: .leading) {
                                    Text(source.name)
                                    if let error = store.errors[source.id] {
                                        Text(error).font(.footnote).foregroundStyle(.red)
                                    } else {
                                        Text(source.url.host ?? source.url.absoluteString).font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if store.loading.contains(source.id) {
                                    ProgressView()
                                } else if let count = store.repositories[source.id]?.apps.count {
                                    Text("\(count)").foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeToDelete {
                            sourceToDelete = source
                        } actions: {
                            Button { UIPasteboard.general.url = source.url } label: {
                                Label("Copy URL", systemImage: "doc.on.doc")
                            }
                            .tint(.gray)
                        }
                        .contextMenu {
                            Button { UIPasteboard.general.url = source.url } label: { Label("Copy URL", systemImage: "doc.on.doc") }
                        }
                    }
                } header: {
                    if !github.repos.isEmpty && !store.sources.isEmpty { Text("Sources") }
                }

                if !github.repos.isEmpty {
                    Section {
                        ForEach(github.repos) { repo in
                            NavigationLink {
                                GitHubRepoView(repoID: repo.id)
                            } label: {
                                GitHubRepoRow(repo: repo)
                            }
                            .swipeToDelete { repoToDelete = repo }
                            .contextMenu {
                                Button { UIPasteboard.general.url = repo.webURL } label: { Label("Copy URL", systemImage: "doc.on.doc") }
                            }
                        }
                    } header: {
                        Text("GitHub Releases")
                    } footer: {
                        Text("Checked when you open Signet. New releases appear in Library. Pull to check now.")
                    }
                }
            }
            .overlay {
                if store.sources.isEmpty && github.repos.isEmpty {
                    ContentUnavailableView {
                        Label("No Sources", systemImage: "globe")
                    } description: {
                        Text("Add an AltStore source or a GitHub repo.")
                    } actions: {
                        Button("Add Source") { showAdd = true }
                        Button("Track GitHub Repo") { showAddRepo = true }
                    }
                }
            }
            .destructiveConfirmation(
                item: $repoToDelete,
                title: { "Stop Tracking \($0.fullName)?" },
                message: { _ in "Apps you've already downloaded stay in your library." },
                confirm: "Stop Tracking",
                perform: { github.delete($0.id) }
            )
            .destructiveConfirmation(
                item: $sourceToDelete,
                title: { "Delete \($0.name)?" },
                message: { _ in "Apps you've already downloaded stay in your library." },
                perform: { store.delete($0.id) }
            )
            .navigationTitle("Sources")
            .refreshable {
                async let sources: Void = store.refreshAll()
                async let repos: Void = github.refreshAll(force: true, library: library)
                _ = await (sources, repos)
            }
            .task { if store.repositories.isEmpty { await store.refreshAll() } }
            .toolbar {
                if adding {
                    ProgressView()
                } else {
                    Menu {
                        Button { showAdd = true } label: { Label("Add Source", systemImage: "globe") }
                        Button { showAddRepo = true } label: { Label("Track GitHub Repo", systemImage: "shippingbox") }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .alert("Track GitHub Repo", isPresented: $showAddRepo) {
                TextField("owner/repo or github.com link", text: $repoText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("Track") {
                    let text = repoText
                    repoText = ""
                    Task {
                        adding = true
                        defer { adding = false }
                        do { try await github.add(text) } catch { self.error = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) { repoText = "" }
            } message: {
                Text("Get new releases that include an IPA.")
            }
            .alert("Add Source", isPresented: $showAdd) {
                TextField("https://example.com/source.json", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                Button("Add") {
                    let text = urlText
                    urlText = ""
                    Task {
                        adding = true
                        defer { adding = false }
                        do { try await store.add(text) } catch { self.error = error.localizedDescription }
                    }
                }
                Button("Cancel", role: .cancel) { urlText = "" }
            }
            .alert("Couldn't Add", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
        }
    }
}

struct SourceAppsView: View {
    let title: String
    let sourceIDs: Set<UUID>?

    @Environment(SourceStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @State private var search = ""

    private var apps: [SourceApp] {
        var seen = Set<String>()
        return store.allApps
            .filter { sourceIDs?.contains($0.source.id) ?? true }
            .map(\.app)
            .filter { seen.insert($0.bundleIdentifier ?? $0.name).inserted }
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || ($0.developerName ?? "").localizedCaseInsensitiveContains(search) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The source's own page (news, featured apps) when showing a single source and not searching.
    private var repository: SourceRepository? {
        guard search.isEmpty, let ids = sourceIDs, ids.count == 1, let id = ids.first else { return nil }
        return store.repositories[id]
    }

    var body: some View {
        List {
            if let repository {
                if let about = repository.subtitle ?? repository.description {
                    Section {
                        Text(about).font(.callout).foregroundStyle(.secondary)
                        if let website = repository.website, website.isWebLink { Link("Website", destination: website) }
                    }
                }
                if !repository.news.isEmpty {
                    Section("News") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(repository.news) { item in
                                    NewsCard(item: item, app: repository.apps.first { $0.bundleIdentifier == item.appID },
                                             fallbackTint: Color(hex: repository.tintColor))
                                }
                            }
                            .padding(.horizontal)
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.viewAligned)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    }
                }
                // With a single app, Featured would only repeat the list below.
                let featured = repository.featured
                if apps.count > 1, !featured.isEmpty {
                    Section("Featured") {
                        ForEach(featured) { app in appRow(app) }
                    }
                }
            }
            Section(repository == nil ? "" : "All Apps") {
                ForEach(apps) { app in appRow(app) }
            }
        }
        .tint(repository.flatMap { Color(hex: $0.tintColor) } ?? .accentColor)
        .overlay {
            if apps.isEmpty { ContentUnavailableView.search(text: search) }
        }
        .searchable(text: $search)
        .navigationTitle(title)
    }
}

extension SourceAppsView {
    private func appRow(_ app: SourceApp) -> some View {
        NavigationLink {
            SourceAppDetailView(app: app)
        } label: {
            HStack(spacing: 12) {
                RemoteIcon(url: app.iconURL, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).lineLimit(1)
                    Text(app.subtitle ?? app.developerName ?? app.bundleIdentifier ?? "")
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    if let version = app.latestVersion {
                        Text(version).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                GetButton(app: app)
            }
        }
        .hidesNavigationIndicator()
    }
}

/// A source's news item: an image with its title, opening the app it's about or its link.
private struct NewsCard: View {
    let item: SourceNews
    let app: SourceApp?
    let fallbackTint: Color?
    @Environment(\.openURL) private var openURL

    private var tint: Color { Color(hex: item.tintColor) ?? fallbackTint ?? .accentColor }

    var body: some View {
        Group {
            if let app {
                NavigationLink { SourceAppDetailView(app: app) } label: { card }
            } else if let url = item.url, url.isWebLink {
                Button { openURL(url) } label: { card }
            } else {
                card
            }
        }
        .buttonStyle(.plain)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let image = item.imageURL {
                AsyncImage(url: DownloadPolicy.displayURL(image)) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    tint.opacity(0.3)
                }
                .frame(width: 280, height: 140)
                .clipped()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).foregroundStyle(.white).lineLimit(2)
                if let caption = item.caption {
                    Text(caption).font(.footnote).foregroundStyle(.white.opacity(0.85)).lineLimit(3)
                }
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
            .frame(minHeight: 70, alignment: .topLeading)
        }
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

struct GetButton: View {
    let app: SourceApp
    @Environment(LibraryStore.self) private var library

    var body: some View {
        if let url = app.latestDownloadURL, let download = library.download(for: url) {
            DownloadRing(download: download)
                .frame(minWidth: 56)
        } else {
            Button("Get") {
                if let url = app.latestDownloadURL {
                    library.download(from: url, name: "\(app.name) \(app.latestVersion ?? "")")
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .font(.subheadline.bold())
            .disabled(app.latestDownloadURL == nil)
        }
    }
}

struct SourceAppDetailView: View {
    let app: SourceApp
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    RemoteIcon(url: app.iconURL, size: 80)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.name).font(.title3.bold())
                        if let developer = app.developerName { Text(developer).foregroundStyle(.secondary) }
                        GetButton(app: app)
                    }
                }
            }
            let screenshots = app.screenshotList(iPad: sizeClass == .regular)
            if !screenshots.isEmpty {
                Section("Screenshots") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(screenshots, id: \.self) { url in
                                AsyncImage(url: DownloadPolicy.displayURL(url)) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary)
                                        .aspectRatio(9 / 19.5, contentMode: .fit)
                                }
                                .frame(height: 360)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                        .padding(.horizontal)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
            }
            if let description = app.localizedDescription {
                Section("Description") { Text(description) }
            }
            Section("Information") {
                if let id = app.bundleIdentifier { LabeledText("Bundle ID", id) }
                if let version = app.latestVersion { LabeledText("Version", version) }
                if let size = app.latestSize { LabeledText("Size", size.formattedBytes) }
            }
            if let versions = app.versions, versions.count > 1 {
                Section("Versions") {
                    ForEach(Array(versions.enumerated()), id: \.offset) { _, version in
                        VersionRow(app: app, version: version)
                    }
                }
            }
        }
        .navigationTitle(app.name)
        .navigationBarTitleDisplayMode(.inline)
        .tint(Color(hex: app.tintColor) ?? .accentColor)
    }
}

private struct VersionRow: View {
    let app: SourceApp
    let version: SourceAppVersion
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(version.version ?? "Unknown")
                if let date = version.date { Text(date.prefix(10)).font(.footnote).foregroundStyle(.secondary) }
            }
            Spacer()
            if let url = version.downloadURL, let download = library.download(for: url) {
                DownloadRing(download: download)
            } else if let url = version.downloadURL {
                Button {
                    library.download(from: url, name: "\(app.name) \(version.version ?? "")")
                } label: {
                    Label("Download", systemImage: "arrow.down.circle").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            }
        }
    }
}
