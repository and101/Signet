import Foundation

/// AltStore-compatible source (the format used by most public app repos).
struct SourceRepository: Codable, Hashable {
    var name: String?
    var identifier: String?
    var subtitle: String?
    var iconURL: URL?
    var tintColor: String?
    var apps: [SourceApp]

    enum CodingKeys: String, CodingKey { case name, identifier, subtitle, iconURL, tintColor, apps }

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

    var id: String { (bundleIdentifier ?? name) + (latestVersion ?? "") }

    var latestVersion: String? { versions?.first?.version ?? version }
    var latestDownloadURL: URL? { versions?.first?.downloadURL ?? downloadURL }
    var latestSize: Int64? { versions?.first?.size ?? size }
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
