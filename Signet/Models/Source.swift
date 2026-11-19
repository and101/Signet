import Foundation

/// AltStore-compatible source (the format used by most public app repos).
struct SourceRepository: Codable, Hashable {
    var name: String?
    var identifier: String?
    var subtitle: String?
    var iconURL: URL?
    var tintColor: String?
    var apps: [SourceApp]
    var news: [SourceNews] = []
    /// Bundle IDs the source highlights.
    var featuredApps: [String] = []
    var headerURL: URL?
    var website: URL?
    var description: String?

    enum CodingKeys: String, CodingKey {
        case name, identifier, subtitle, iconURL, tintColor, apps, news, featuredApps, headerURL, website, description
    }

    /// The featured apps in the source's order, then nothing else.
    var featured: [SourceApp] {
        featuredApps.compactMap { id in apps.first { $0.bundleIdentifier == id } }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        identifier = try? c.decodeIfPresent(String.self, forKey: .identifier)
        subtitle = try? c.decodeIfPresent(String.self, forKey: .subtitle)
        iconURL = try? c.decodeIfPresent(URL.self, forKey: .iconURL)
        tintColor = try? c.decodeIfPresent(String.self, forKey: .tintColor)
        // Skip individual malformed apps instead of failing the whole source.
        let lossy = (try? c.decodeIfPresent([Lossy<SourceApp>].self, forKey: .apps)) ?? []
        apps = lossy.compactMap(\.value)
        news = ((try? c.decodeIfPresent([Lossy<SourceNews>].self, forKey: .news)) ?? []).compactMap(\.value)
        featuredApps = (try? c.decodeIfPresent([String].self, forKey: .featuredApps)) ?? []
        headerURL = try? c.decodeIfPresent(URL.self, forKey: .headerURL)
        website = try? c.decodeIfPresent(URL.self, forKey: .website)
        description = try? c.decodeIfPresent(String.self, forKey: .description)
    }
}

/// A news item a source shows above its apps.
struct SourceNews: Codable, Hashable, Identifiable {
    var identifier: String?
    var title: String
    var caption: String?
    var date: String?
    var tintColor: String?
    var imageURL: URL?
    var url: URL?
    /// The bundle ID of an app the item is about.
    var appID: String?

    var id: String { identifier ?? title + (date ?? "") }
}

/// App screenshots in any of the forms sources use: a list of URLs, a list of `{imageURL}` objects, or the same
/// split by device (`{"iphone": […], "ipad": […]}`). Never fails to decode; unreadable entries are skipped.
struct SourceScreenshots: Codable, Hashable {
    var iphone: [URL] = []
    var ipad: [URL] = []

    private enum DeviceKeys: String, CodingKey { case iphone, ipad }
    private struct Item: Decodable {
        let url: URL?
        init(from decoder: Decoder) throws {
            if let string = try? decoder.singleValueContainer().decode(String.self) {
                url = URL(string: string)
            } else {
                url = try? decoder.container(keyedBy: Keys.self).decode(URL.self, forKey: .imageURL)
            }
        }
        enum Keys: String, CodingKey { case imageURL }
    }

    init(iphone: [URL] = [], ipad: [URL] = []) {
        self.iphone = iphone
        self.ipad = ipad
    }

    init(from decoder: Decoder) throws {
        if let list = try? decoder.singleValueContainer().decode([Lossy<Item>].self) {
            iphone = list.compactMap { $0.value?.url }
        } else if let devices = try? decoder.container(keyedBy: DeviceKeys.self) {
            iphone = ((try? devices.decodeIfPresent([Lossy<Item>].self, forKey: .iphone)) ?? []).compactMap { $0.value?.url }
            ipad = ((try? devices.decodeIfPresent([Lossy<Item>].self, forKey: .ipad)) ?? []).compactMap { $0.value?.url }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DeviceKeys.self)
        try container.encode(iphone, forKey: .iphone)
        try container.encode(ipad, forKey: .ipad)
    }
}

struct SourceApp: Codable, Hashable, Identifiable {
    var name: String
    var bundleIdentifier: String?
    var developerName: String?
    var subtitle: String?
    var localizedDescription: String?
    var iconURL: URL?
    var tintColor: String?
    var versions: [SourceAppVersion]?
    // Legacy flat fields
    var version: String?
    var versionDate: String?
    var downloadURL: URL?
    var size: Int64?
    var screenshots: SourceScreenshots?
    /// Older sources list screenshots here (as plain URLs; decoded leniently the same way).
    var screenshotURLs: SourceScreenshots?

    var id: String { (bundleIdentifier ?? name) + (latestVersion ?? "") }

    var latestVersion: String? { versions?.first?.version ?? version }
    var latestDownloadURL: URL? { versions?.first?.downloadURL ?? downloadURL }
    var latestSize: Int64? { versions?.first?.size ?? size }

    /// Screenshots for this device, falling back to the others when a source only has one kind.
    func screenshotList(iPad: Bool) -> [URL] {
        let modern = screenshots.map { iPad ? ($0.ipad.isEmpty ? $0.iphone : $0.ipad) : ($0.iphone.isEmpty ? $0.ipad : $0.iphone) } ?? []
        return modern.isEmpty ? (screenshotURLs?.iphone ?? []) : modern
    }
}

struct SourceAppVersion: Codable, Hashable {
    var version: String?
    var date: String?
    var localizedDescription: String?
    var downloadURL: URL?
    var size: Int64?
}

struct SavedSource: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var name: String
    var iconURL: URL?
    var dateAdded = Date()
}

/// Decodes a value or nil, so one bad element doesn't fail an array.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

extension Lossy: Encodable where T: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }
}
