import Foundation

enum TextSearch {
    static let matchLimit = 20_000

    static func matches(in text: String, query: String, matchCase: Bool) -> [NSRange] {
        let needle = query
        guard !needle.isEmpty else { return [] }

        let haystack = text as NSString
        let length = haystack.length
        var ranges: [NSRange] = []
        ranges.reserveCapacity(64)
        var location = 0
        var options: NSString.CompareOptions = []
        if !matchCase {
            options.insert(.caseInsensitive)
        }

        while location < length {
            let remaining = NSRange(location: location, length: length - location)
            let found = haystack.range(of: needle, options: options, range: remaining)
            if found.location == NSNotFound { break }
            ranges.append(found)
            if ranges.count >= matchLimit { break }
            location = found.location + max(found.length, 1)
        }
        return ranges
    }

    static func replacing(
        in text: String,
        query: String,
        replacement: String,
        matchCase: Bool
    ) -> (text: String, count: Int) {
        let hits = matches(in: text, query: query, matchCase: matchCase)
        guard !hits.isEmpty else { return (text, 0) }
        var result = text as NSString
        for range in hits.reversed() {
            result = result.replacingCharacters(in: range, with: replacement) as NSString
        }
        return (result as String, hits.count)
    }

    static func snippet(in text: String, range: NSRange, radius: Int = 16) -> String {
        let ns = text as NSString
        let start = max(0, range.location - radius)
        let end = min(ns.length, NSMaxRange(range) + radius)
        guard end > start else { return "" }
        var snippet = ns.substring(with: NSRange(location: start, length: end - start))
        snippet = snippet
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return snippet
    }

    static func index(nearestTo offset: Int, in hits: [NSRange]) -> Int {
        guard !hits.isEmpty else { return 0 }
        var best = 0
        var bestDistance = Int.max
        for (index, hit) in hits.enumerated() {
            let distance = abs(hit.location - offset)
            if distance < bestDistance {
                best = index
                bestDistance = distance
            }
            if hit.location >= offset { break }
        }
        return best
    }

    static func index(atOrAfter offset: Int, in hits: [NSRange]) -> Int {
        guard !hits.isEmpty else { return 0 }
        if let index = hits.firstIndex(where: { $0.location >= offset }) {
            return index
        }
        return hits.count - 1
    }
}
