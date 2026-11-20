import SwiftUI

struct GitHubRepoRow: View {
    let repo: TrackedRepo
    @Environment(GitHubStore.self) private var github
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack(spacing: 12) {
            RemoteIcon(url: repo.avatarURL, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.fullName).lineLimit(1)
                if let error = github.errors[repo.id] {
                    Text(error).font(.footnote).foregroundStyle(.red).lineLimit(2)
                } else if let latest = github.latest(for: repo) {
                    Text("\(latest.release.tagName) · \(latest.asset.name)")
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                } else if github.caches[repo.id] != nil {
                    Text("No releases with an IPA").font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if github.loading.contains(repo.id) {
                ProgressView()
            } else if github.status(of: repo, in: library) == .updateAvailable {
                Badge(text: "Update", color: .blue)
            }
        }
    }
}

struct GitHubRepoView: View {
    let repoID: UUID

    @Environment(GitHubStore.self) private var github
    @Environment(LibraryStore.self) private var library
    @Environment(CertificateStore.self) private var certificates
    @Environment(\.dismiss) private var dismiss

    @State private var confirmDelete = false
    @FocusState private var editingBundleID: Bool

    var body: some View {
        Group {
            if let repo = github.repo(repoID) {
                form(repo)
            } else {
                ContentUnavailableView("Repository Removed", systemImage: "shippingbox")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Reads and saves straight through the store, so changes the store makes (like the last download) aren't overwritten.
    private func binding<Value>(_ keyPath: WritableKeyPath<TrackedRepo, Value>, _ repo: TrackedRepo) -> Binding<Value> {
        Binding(
            get: { (github.repo(repoID) ?? repo)[keyPath: keyPath] },
            set: { value in
                guard var current = github.repo(repoID) else { return }
                current[keyPath: keyPath] = value
                github.update(current)
            }
        )
    }

    private func form(_ repo: TrackedRepo) -> some View {
        let releases = github.releases(for: repo)
        let latest = github.latest(for: repo)
        let inLibrary = latest.map { github.isInLibrary($0.asset, library: library) } ?? false
        let assetNames = github.assetNames(for: repo)
        let defaultCertificate = certificates.certificate(repo.certificateID) ?? certificates.defaultCertificate

        return Form {
            Section {
                HStack(spacing: 14) {
                    RemoteIcon(url: repo.avatarURL, size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repo.displayName).font(.title3.bold())
                        Text(repo.displayName == repo.name ? repo.owner : repo.fullName)
                            .font(.subheadline).foregroundStyle(.secondary)
                        if let summary = repo.summary, !summary.isEmpty {
                            Text(summary).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                        }
                    }
                }
                .padding(.vertical, 4)
                // Run the divider below the header full width instead of from the title.
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
                Link(destination: repo.webURL) {
                    LabeledContent("View on GitHub") {
                        Image(systemName: "arrow.up.right").font(.footnote.weight(.semibold)).accessibilityHidden(true)
                    }
                }
                .tint(.primary)
                .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            }

            Section {
                if let latest {
                    LabeledText("Version", latest.release.tagName)
                    if let date = latest.release.publishedAt {
                        LabeledText("Released", date.formatted(date: .abbreviated, time: .omitted))
                    }
                    LabeledText("Size", latest.asset.size.formattedBytes)
                    LabeledText("File", latest.asset.name)
                    if let download = library.download(for: latest.asset.browserDownloadUrl) {
                        DownloadProgressRow(download: download)
                    } else if inLibrary {
                        Label("In Library", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    } else {
                        Button("Download to Library") {
                            github.download(latest.asset, from: latest.release, of: repo, library: library)
                        }
                    }
                } else if let error = github.errors[repo.id] {
                    Text(error).foregroundStyle(.red)
                } else if github.loading.contains(repo.id) {
                    LabeledContent("Checking…") { ProgressView() }
                } else {
                    Text(repo.assetName == nil
                         ? "No release has an IPA attached."
                         : "No release has an IPA matching \(repo.assetName ?? "").")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Latest Release")
            } footer: {
                if let checked = github.caches[repo.id]?.checkedAt {
                    Text("Checked \(checked.formatted(.relative(presentation: .named))).")
                }
            }

            Section {
                if assetNames.count > 1 || repo.assetName != nil {
                    Picker("IPA", selection: binding(\.assetName, repo)) {
                        Text("First IPA").tag(String?.none)
                        ForEach(assetNames, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                        if let current = repo.assetName, !assetNames.contains(current) {
                            Text(current).tag(Optional(current))
                        }
                    }
                }
                Toggle("Include Pre-releases", isOn: binding(\.includePrereleases, repo))
                Toggle("Download New Releases", isOn: binding(\.autoDownload, repo))
            } header: {
                Text("Tracking")
            } footer: {
                Text("New releases are added to your library automatically.")
            }

            Section {
                LabeledContent {
                    TextField("Bundle ID", text: Binding(
                        get: { binding(\.bundleID, repo).wrappedValue ?? "" },
                        set: { binding(\.bundleID, repo).wrappedValue = $0.isEmpty ? nil : $0 }
                    ), prompt: Text(latestBundleIDPlaceholder(repo)))
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($editingBundleID)
                } label: {
                    Text("Bundle ID")
                    if let bundleID = repo.defaultBundleID, let requirement = defaultCertificate?.bundleIDRequirement(for: bundleID) {
                        Text(requirement).foregroundStyle(.red)
                    }
                }
                if certificates.certificates.isEmpty {
                    LabeledContent("Certificate", value: "None Added")
                } else {
                    // A deleted certificate shows as Default, which is what signing falls back to.
                    Picker("Certificate", selection: Binding(
                        get: { certificates.certificate(binding(\.certificateID, repo).wrappedValue)?.id },
                        set: { binding(\.certificateID, repo).wrappedValue = $0 }
                    )) {
                        Text("Default").tag(UUID?.none)
                        ForEach(certificates.certificates) { cert in
                            Text(cert.nickname).tag(Optional(cert.id))
                        }
                    }
                }
            } header: {
                Text("Signing Defaults")
            } footer: {
                Text("Used when signing apps from this repo. Keep the same bundle ID to update the installed app.")
            }

            if !releases.isEmpty {
                Section("Releases") {
                    ForEach(releases) { release in
                        ReleaseRow(repo: repo, release: release)
                    }
                }
            }

            Section {
                Button("Stop Tracking", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(repo.fullName)
        .refreshable { await github.refresh(repo, library: library) }
        .task {
            if github.caches[repo.id] == nil { await github.refresh(repo, library: library) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { editingBundleID = false }
            }
        }
        .destructiveConfirmation(
            item: Binding(get: { confirmDelete ? repo : nil }, set: { if $0 == nil { confirmDelete = false } }),
            title: { "Stop Tracking \($0.fullName)?" },
            message: { _ in "Apps you've already downloaded stay in your library." },
            confirm: "Stop Tracking",
            perform: { repo in
                dismiss()
                github.delete(repo.id)
            }
        )
    }

    /// Shows the bundle ID of the last downloaded copy, so it's clear what leaving the field empty means.
    private func latestBundleIDPlaceholder(_ repo: TrackedRepo) -> String {
        library.apps
            .filter { $0.kind == .imported && $0.sourceURL.map { GitHub.isDownload($0, from: repo) } == true }
            .max { $0.dateAdded < $1.dateAdded }?
            .bundleID ?? "App's Own"
    }
}

private struct ReleaseRow: View {
    let repo: TrackedRepo
    let release: GitHubRelease
    @Environment(GitHubStore.self) private var github
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // Tags are unique; names often repeat across re-releases (v5.0.9 and v5.0.9-2).
                    Text(release.tagName).lineLimit(1)
                    if release.prerelease { Badge(text: "Pre-release", color: .orange) }
                }
                let details = [release.title == release.tagName ? nil : release.title,
                               release.publishedAt?.formatted(date: .abbreviated, time: .omitted)].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · "))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            let assets = release.ipaAssets
            if let download = assets.lazy.compactMap({ library.download(for: $0.browserDownloadUrl) }).first {
                DownloadRing(download: download)
            } else if assets.count == 1, let asset = assets.first {
                Button { github.download(asset, from: release, of: repo, library: library) } label: {
                    Label("Download \(asset.name)", systemImage: "arrow.down.circle").labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
            } else {
                Menu {
                    ForEach(assets) { asset in
                        Button { github.download(asset, from: release, of: repo, library: library) } label: {
                            Text(asset.name)
                            Text(asset.size.formattedBytes)
                        }
                    }
                } label: {
                    Label("Download", systemImage: "arrow.down.circle").labelStyle(.iconOnly)
                }
            }
        }
    }
}
