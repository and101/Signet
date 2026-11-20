import Foundation
import ImageIO

/// Limits for icon images Signet didn't make itself (inside IPAs, remembered with signing options, from backups).
/// A small PNG can still decode to gigabytes, so the pixel size is read from the header before decoding.
enum IconImage {
    /// Custom icons are stored at this size: the largest an iOS icon is drawn at is 1024 pixels.
    static let customIconSide = 1024
    /// Photos and picked files may be far larger than an icon, so they're scaled down with ImageIO's thumbnailing,
    /// which doesn't decode the whole image first. This only rules out absurd dimensions.
    static let sourceFileLimit: Int64 = 100 * 1024 * 1024
    static let sourcePixelLimit = 30_000

    /// Scales any readable image (a camera photo, a picked file, an icon saved by 1.1) to a PNG no larger than
    /// `customIconSide`. Nil if it isn't an image or is beyond the source limits.
    static func normalizedCustomIcon(_ data: Data) -> Data? {
        guard Int64(data.count) <= sourceFileLimit,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= sourcePixelLimit, height <= sourcePixelLimit else { return nil }
        // Already an icon-sized PNG: kept as it is, so a remembered icon round-trips unchanged.
        if CGImageSourceGetType(source) as String? == "public.png", max(width, height) <= customIconSide { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(customIconSide, max(width, height)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// A remembered custom icon (possibly saved by 1.1 as the original photo), normalised. A file that needed scaling
    /// is rewritten at icon size once, so later loads are cheap pass-throughs.
    static func loadCustomIcon(_ url: URL) -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= sourceFileLimit,
              let data = try? Data(contentsOf: url), let icon = normalizedCustomIcon(data) else { return nil }
        if icon != data { try? icon.write(to: url, options: .atomic) }
        return icon
    }

    static let fileLimit: Int64 = 10 * 1024 * 1024
    static let pixelLimit = 4096

    /// The pixel width of an image file within the limits, read from its header without decoding it; nil otherwise.
    /// For icons inside IPAs and library thumbnails restored from backups.
    static func acceptableWidth(of url: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value <= fileLimit,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelSize(of: source)?.width
    }

    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= pixelLimit, height <= pixelLimit else { return nil }
        return (width, height)
    }
}
