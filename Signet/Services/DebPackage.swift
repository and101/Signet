import Foundation
import SWCompression

/// Unpacks the file tree of a Debian package (`ar` archive → `data.tar.*`).
enum DebPackage {
    /// Extracts the package's `data.tar` into `destination`. Symlinks and special files are skipped,
    /// and entries that would land outside `destination` are rejected.
    static func extract(_ deb: URL, to destination: URL) throws {
        let name = deb.lastPathComponent
        let (member, payload) = try dataMember(of: Data(contentsOf: deb, options: .mappedIfSafe), name: name)
        let tar: Data
        do {
            switch member {
            case "data.tar": tar = payload
            case "data.tar.gz": tar = try GzipArchive.unarchive(archive: payload)
            case "data.tar.xz": tar = try XZArchive.unarchive(archive: payload)
            case "data.tar.lzma": tar = try LZMA.decompress(data: payload)
            case "data.tar.bz2": tar = try BZip2.decompress(data: payload)
            case "data.tar.zst":
                throw AppError("\(name) uses zstd compression, which isn't supported.")
            default:
                throw AppError("\(name) uses an unknown archive format (\(member)).")
            }
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError("Couldn't decompress \(name): \(error.localizedDescription)")
        }

        let entries: [TarEntry]
        do { entries = try TarContainer.open(container: tar) } catch {
            throw AppError("Couldn't read the files in \(name): \(error.localizedDescription)")
        }

        let fm = FileManager.default
        for entry in entries {
            guard let relative = safeRelativePath(entry.info.name) else {
                if !entry.info.name.trimmingCharacters(in: CharacterSet(charactersIn: "./")).isEmpty {
                    throw AppError("\(name) contains an unsafe path: \(entry.info.name)")
                }
                continue
            }
            let target = destination.appendingPathComponent(relative)
            switch entry.info.type {
            case .directory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case .regular:
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (entry.data ?? Data()).write(to: target)
            default:
                continue
            }
        }
    }

    /// Finds the `data.tar*` member of an `ar` archive.
    private static func dataMember(of archive: Data, name: String) throws -> (String, Data) {
        let magic = Data("!<arch>\n".utf8)
        guard archive.count >= magic.count, archive.prefix(magic.count) == magic else {
            throw AppError("\(name) isn't a valid .deb package.")
        }
        var cursor = archive.startIndex + magic.count
        while cursor + 60 <= archive.endIndex {
            let header = archive[cursor..<(cursor + 60)]
            func field(_ start: Int, _ length: Int) -> String {
                let bytes = header[(cursor + start)..<(cursor + start + length)]
                return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            }
            guard let size = Int(field(48, 10)), size >= 0, cursor + 60 + size <= archive.endIndex else {
                throw AppError("\(name) is truncated or corrupt.")
            }
            var member = field(0, 16)
            var body = cursor + 60
            var bodySize = size
            if member.hasPrefix("#1/"), let nameLength = Int(member.dropFirst(3)), nameLength <= size {
                // BSD ar stores long names at the start of the member data.
                let raw = archive[body..<(body + nameLength)].prefix { $0 != 0 }
                member = String(decoding: raw, as: UTF8.self)
                body += nameLength
                bodySize -= nameLength
            } else {
                // GNU ar terminates names with "/".
                member = member.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            if member.hasPrefix("data.tar") {
                return (member, archive.subdata(in: body..<(body + bodySize)))
            }
            cursor += 60 + size + (size % 2) // members are 2-byte aligned
        }
        throw AppError("\(name) has no data archive.")
    }

    /// Normalizes a tar entry name (`./var/jb/x` → `var/jb/x`); nil for empty or escaping paths.
    static func safeRelativePath(_ path: String) -> String? {
        let parts = path.split(separator: "/").filter { $0 != "." && !$0.isEmpty }
        guard !parts.isEmpty, !parts.contains("..") else { return nil }
        return parts.joined(separator: "/")
    }
}
