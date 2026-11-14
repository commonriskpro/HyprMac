import Foundation

public struct FuzzyMatchResult<T>: @unchecked Sendable {
    public let item: T
    public let score: Int

    public init(item: T, score: Int) {
        self.item = item
        self.score = score
    }
}

public enum FuzzyMatcher {
    private static let nonAlphanumericSet = CharacterSet.alphanumerics.inverted

    private struct ScoredCandidate<T> {
        let item: T
        let target: String
        let score: Int
    }

    /// Filters and scores candidates according to the priority:
    /// exact full match > exact prefix > word boundary match > consecutive character match > substring match.
    /// Case-insensitive.
    public static func match<T>(
        query: String,
        candidates: [T],
        extractTarget: (T) -> String
    ) -> [T] {
        return matchScored(query: query, candidates: candidates, extractTarget: extractTarget).map { $0.item }
    }

    /// Filters and scores candidates returning their scores.
    public static func matchScored<T>(
        query: String,
        candidates: [T],
        extractTarget: (T) -> String
    ) -> [(item: T, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return candidates.map { ($0, 0) }
        }

        var scored: [ScoredCandidate<T>] = []
        scored.reserveCapacity(candidates.count)
        for candidate in candidates {
            let target = extractTarget(candidate)
            if let s = score(query: trimmed, target: target) {
                scored.append(ScoredCandidate(item: candidate, target: target, score: s))
            }
        }

        scored.sort { a, b in
            if a.score != b.score {
                return a.score > b.score
            }
            return a.target.localizedCaseInsensitiveCompare(b.target) == .orderedAscending
        }

        return scored.map { ($0.item, $0.score) }
    }

    /// Scores a single target against a query. Returns nil if no match.
    public static func score(query: String, target: String) -> Int? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return 0 }
        let t = target.lowercased()

        // 1. Exact full match: highest priority (100,000 tier)
        if t == q {
            return 100_000
        }

        let qCount = q.count

        // 2. Exact prefix match: (50,000 tier)
        // Shorter target names or exact length matches get higher score
        if t.hasPrefix(q) {
            let lengthDiff = t.count - qCount
            return 50_000 + max(0, 5_000 - lengthDiff * 50)
        }

        // 3. Word boundary matches: (30,000 tier)
        // Traverse t to find word boundaries and acronym initials without allocating intermediate [String] arrays
        var wordIndex = 0
        var inWord = false
        var wordStart = t.startIndex
        var initials = ""
        initials.reserveCapacity(8)
        var wordPrefixScore: Int? = nil

        var scanIdx = t.startIndex
        while scanIdx < t.endIndex {
            let ch = t[scanIdx]
            let isSeparator = ch.unicodeScalars.contains { nonAlphanumericSet.contains($0) }

            if isSeparator {
                if inWord {
                    let wordSlice = t[wordStart..<scanIdx]
                    if wordPrefixScore == nil && wordSlice.hasPrefix(q) {
                        let lengthDiff = wordSlice.count - qCount
                        wordPrefixScore = 30_000 - (wordIndex * 200) + max(0, 2_000 - lengthDiff * 30)
                    }
                    wordIndex += 1
                    inWord = false
                }
            } else {
                if !inWord {
                    inWord = true
                    wordStart = scanIdx
                    initials.append(ch)
                }
            }
            scanIdx = t.index(after: scanIdx)
        }

        if inWord {
            let wordSlice = t[wordStart..<scanIdx]
            if wordPrefixScore == nil && wordSlice.hasPrefix(q) {
                let lengthDiff = wordSlice.count - qCount
                wordPrefixScore = 30_000 - (wordIndex * 200) + max(0, 2_000 - lengthDiff * 30)
            }
            wordIndex += 1
        }

        // 3a. Any individual word prefix
        if let s = wordPrefixScore {
            return s
        }

        // 3b. Word boundary initials / acronym match (e.g. "gc" for "Google Chrome")
        if initials.hasPrefix(q) {
            let diff = initials.count - qCount
            return 25_000 + max(0, 1_000 - diff * 100)
        }

        // 4. Consecutive character match / substring match: (15,000 tier)
        if let range = t.range(of: q) {
            var distance = 0
            var cur = t.startIndex
            while cur < range.lowerBound {
                distance += 1
                cur = t.index(after: cur)
            }
            var tCount = distance
            while cur < t.endIndex {
                tCount += 1
                cur = t.index(after: cur)
            }
            return 15_000 - (distance * 100) + max(0, 1_000 - tCount * 10)
        }

        // 5. Fuzzy subsequence match: (1,000 - 10,000 tier)
        var qIndex = q.startIndex
        var tIndex = t.startIndex
        var tOffset = 0
        var subScore = 0
        var consecutiveCount = 0
        var prevMatched = false
        var prevTChar: Character? = nil

        while qIndex < q.endIndex && tIndex < t.endIndex {
            let qChar = q[qIndex]
            let tChar = t[tIndex]

            if qChar == tChar {
                qIndex = q.index(after: qIndex)
                var charScore = 100

                let isWordStart: Bool
                if tOffset == 0 {
                    isWordStart = true
                } else {
                    isWordStart = prevTChar?.unicodeScalars.first.map { nonAlphanumericSet.contains($0) } ?? false
                }
                if isWordStart {
                    charScore += 250
                }

                if prevMatched {
                    consecutiveCount += 1
                    charScore += consecutiveCount * 100
                } else {
                    consecutiveCount = 0
                }

                let dist = tOffset
                charScore -= min(dist * 5, 100)

                subScore += charScore
                prevMatched = true
            } else {
                prevMatched = false
                consecutiveCount = 0
            }

            prevTChar = tChar
            tOffset += 1
            tIndex = t.index(after: tIndex)
        }

        if qIndex == q.endIndex {
            return max(1, subScore)
        }

        return nil
    }
}
