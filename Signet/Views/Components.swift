import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let ipa = UTType(filenameExtension: "ipa") ?? .data
    static let mobileProvision = UTType(filenameExtension: "mobileprovision") ?? .data
    static let dylib = UTType(filenameExtension: "dylib") ?? .data
    static let framework = UTType(filenameExtension: "framework") ?? .folder
}

extension View {
    /// Trailing swipe with `primary` on the outer edge, the slot a full swipe triggers, and any other
    /// actions next to the row so they come first. Avoids `.destructive`: SwiftUI removes a destructive
    /// row immediately, before the confirmation can answer.
    func swipeToDelete<Actions: View>(
        _ title: String = "Delete",
        systemImage: String = "trash",
        primary: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(action: primary) { Label(title, systemImage: systemImage) }
                .tint(.red)
            actions()
        }
    }

    /// Asks before a destructive action. Presented while `item` is non-nil.
    func destructiveConfirmation<Item>(
        item: Binding<Item?>,
        title: (Item) -> String,
        message: (Item) -> String,
        confirm: String = "Delete",
        cancel: String = "Cancel",
        perform: @escaping (Item) -> Void
    ) -> some View {
        alert(
            item.wrappedValue.map(title) ?? "",
            isPresented: Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } }),
            presenting: item.wrappedValue
        ) { value in
            Button(confirm, role: .destructive) { perform(value) }
            Button(cancel, role: .cancel) {}
        } message: { value in
            Text(message(value))
        }
    }

    /// A full-width primary action pinned above the content, with scroll-edge glass on iOS 26 and later.
    /// Hides the tab bar so the two don't stack.
    @ViewBuilder
    func bottomActionBar<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26, *) {
            toolbar(.hidden, for: .tabBar)
                .safeAreaBar(edge: .bottom) { content().padding(.horizontal).padding(.vertical, 8) }
        } else {
            toolbar(.hidden, for: .tabBar)
                .safeAreaInset(edge: .bottom) {
                    content().padding(.horizontal).padding(.vertical, 8).background(.bar)
                }
        }
    }

    @ViewBuilder
    func prominentAction() -> some View {
        if #available(iOS 26, *) {
            buttonStyle(.glassProminent).controlSize(.large)
        } else {
            buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}

/// Sheet toolbar buttons that use the system's glass icon buttons on iOS 26 and later.
struct SheetCloseButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(role: .close, action: action)
        } else {
            Button("Close", action: action)
        }
    }
}

struct SheetCancelButton: View {
    let action: () -> Void

    var body: some View {
        if #available(iOS 26, *) {
            Button(role: .cancel, action: action)
        } else {
            Button("Cancel", role: .cancel, action: action)
        }
    }
}

struct AppIcon: View {
    let url: URL?
    private let baseSize: CGFloat
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    init(url: URL?, size: CGFloat = 52) {
        self.url = url
        baseSize = size
    }

    private var size: CGFloat { baseSize * scale }

    var body: some View {
        Group {
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable()
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: "app.dashed").resizable().scaledToFit()
                        .frame(width: size * 0.45).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).stroke(.quaternary, lineWidth: 0.5))
    }
}

struct RemoteIcon: View {
    let url: URL?
    private let baseSize: CGFloat
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    init(url: URL?, size: CGFloat = 52) {
        self.url = url
        baseSize = size
    }

    private var size: CGFloat { baseSize * scale }

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable()
        } placeholder: {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "app.dashed").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

struct AppRow: View {
    let app: LibraryApp

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: app.iconURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).lineLimit(1)
                Text("\(app.version) · \(app.bundleID)")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if app.kind == .signed, let cert = app.certificateName {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                            Text("\(cert) ·")
                        }
                    }
                    Text(app.size.formattedBytes)
                }
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

/// A Settings-app style row icon: a white symbol on a coloured rounded square.
struct SettingsIcon: View {
    let systemImage: String
    let color: Color
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 29

    init(_ systemImage: String, color: Color) {
        self.systemImage = systemImage
        self.color = color
    }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.55, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    /// Hides a navigation link's chevron where the row already has its own action, like App Store lists.
    @ViewBuilder
    func hidesNavigationIndicator() -> some View {
        if #available(iOS 26, *) {
            navigationLinkIndicatorVisibility(.hidden)
        } else {
            self
        }
    }
}

/// App Store-style download progress: a ring that fills as the file arrives, with a stop square to cancel.
/// Spins while the size is unknown or the IPA is being imported.
struct DownloadRing: View {
    let download: LibraryStore.Download
    @Environment(LibraryStore.self) private var library
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 26

    private var isDeterminate: Bool { download.expected > 0 && download.progress < 1 }

    var body: some View {
        Button { library.cancel(download) } label: {
            ZStack {
                if isDeterminate {
                    Circle().stroke(.quaternary, lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0.02, download.progress))
                        .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.2), value: download.progress)
                    RoundedRectangle(cornerRadius: 2).fill(.tint).frame(width: size * 0.3, height: size * 0.3)
                } else {
                    ProgressView()
                }
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(download.isImporting ? "Importing" : "Downloading, \(Int(download.progress * 100)) percent")
        .accessibilityHint("Double-tap to cancel")
        .disabled(download.isImporting)
    }
}

/// A list row showing a download in progress, with a bar, the amount received and a Cancel button.
struct DownloadProgressRow: View {
    let download: LibraryStore.Download
    @Environment(LibraryStore.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(download.isImporting ? "Importing…" : "Downloading…")
                Spacer()
                if !download.isImporting {
                    Button("Cancel", role: .cancel) { library.cancel(download) }
                        .buttonStyle(.borderless)
                }
            }
            if download.expected > 0, !download.isImporting {
                ProgressView(value: download.progress)
                Text("\(download.received.formattedBytes) of \(download.expected.formattedBytes)")
                    .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

struct LabeledText: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    /// Label and value on one line when they fit; otherwise the value goes on its own leading-aligned
    /// lines below, like Settings → General → About, instead of wrapping ragged against the trailing edge.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                Text(title)
                Spacer(minLength: 0)
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(value).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
    }
}

/// Copies a picked file into temp storage so it survives after security-scoped access ends.
func copyPickedFile(_ url: URL) throws -> URL {
    // The copying picker already put the file in Signet's temp folder; another copy would only use space.
    if url.standardizedFileURL.path.hasPrefix(Paths.temp.standardizedFileURL.path + "/") { return url }
    let accessing = url.startAccessingSecurityScopedResource()
    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
    let folder = try Paths.newTempDirectory()
    let destination = folder.appendingPathComponent(url.lastPathComponent)
    try FileManager.default.copyItem(at: url, to: destination)
    return destination
}

// MARK: - File picking

extension View {
    /// Like `fileImporter`, but iOS hands over a copy of each picked file instead of access to the original.
    ///
    /// The copy is placed in the app's own storage, so it works even when the app's bundle ID doesn't match its
    /// signing profile. In that case iOS refuses the access token `fileImporter` relies on, and picking does nothing.
    func copyingFileImporter(isPresented: Binding<Bool>, allowedContentTypes: [UTType],
                             allowsMultipleSelection: Bool = false,
                             onPick: @escaping ([URL]) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            CopyingDocumentPicker(types: allowedContentTypes, allowsMultipleSelection: allowsMultipleSelection) { urls in
                isPresented.wrappedValue = false
                if !urls.isEmpty { onPick(urls) }
            }
            .ignoresSafeArea()
        }
    }
}

private struct CopyingDocumentPicker: UIViewControllerRepresentable {
    let types: [UTType]
    let allowsMultipleSelection: Bool
    let onFinish: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: ([URL]) -> Void
        init(onFinish: @escaping ([URL]) -> Void) { self.onFinish = onFinish }

        /// iOS leaves its copies in a folder Signet never clears, so move them into Signet's temp folder,
        /// which is emptied at launch.
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onFinish(urls.map { url in
                guard let folder = try? Paths.newTempDirectory() else { return url }
                let destination = folder.appendingPathComponent(url.lastPathComponent)
                return (try? FileManager.default.moveItem(at: url, to: destination)) != nil ? destination : url
            })
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onFinish([])
        }
    }
}

extension Color {
    /// A colour from a source's `#RRGGBB` (or `RRGGBB`) tint. Nil for anything else.
    init?(hex: String?) {
        guard var text = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }
}
