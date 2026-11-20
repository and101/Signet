import Foundation

/// One satisfiable byte range. As RFC 9110 allows, a header this server doesn't handle (other units, several
/// ranges, invalid syntax) is ignored and the whole file is sent; only a valid range past the end is a 416.
enum HTTPByteRange: Equatable {
    case full
    case partial(start: Int64, end: Int64)
    case unsatisfiable

    static func parse(_ header: String?, size: Int64) -> Self {
        guard let header else { return .full }
        guard header.hasPrefix("bytes=") else { return .full }
        let spec = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return .full }
        func number(_ text: Substring) -> Int64? {
            guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
            return Int64(text)
        }
        if parts[0].isEmpty {
            guard let suffix = number(parts[1]) else { return .full }
            guard suffix > 0, size > 0 else { return .unsatisfiable }
            return .partial(start: max(0, size - suffix), end: size - 1)
        }
        guard let start = number(parts[0]) else { return .full }
        var end = size - 1
        if !parts[1].isEmpty {
            guard let last = number(parts[1]), last >= start else { return .full }
            end = min(last, size - 1)
        }
        guard start < size else { return .unsatisfiable }
        return .partial(start: start, end: end)
    }
}
