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
    /// Filters and scores candidates according to the priority:
    /// exact full match > exact prefix > word boundary match > consecutive character match > substring match.
    /// Case-insensitive.
    public static func match<T>(
        query: String,
        candidates: [T],
        extractTarget: (T) -> String
    ) -> [T] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return candidates
        }

        var scored: [FuzzyMatchResult<T>] = []
        for candidate in candidates {
            let target = extractTarget(candidate)
            if let s = score(query: trimmed, target: target) {
                scored.append(FuzzyMatchResult(item: candidate, score: s))
            }
        }

        scored.sort { a, b in
            if a.score != b.score {
                return a.score > b.score
            }
            return extractTarget(a.item).localizedCaseInsensitiveCompare(extractTarget(b.item)) == .orderedAscending
        }

        return scored.map { $0.item }
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

        // 2. Exact prefix match: (50,000 tier)
        // Shorter target names or exact length matches get higher score
        if t.hasPrefix(q) {
            let lengthDiff = t.count - q.count
            return 50_000 + max(0, 5_000 - lengthDiff * 50)
        }

        // 3. Word boundary matches: (30,000 tier)
        let words = target.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }

        // 3a. Any individual word prefix
        for (i, word) in words.enumerated() {
            let w = word.lowercased()
            if w.hasPrefix(q) {
                let lengthDiff = w.count - q.count
                return 30_000 - (i * 200) + max(0, 2_000 - lengthDiff * 30)
            }
        }

        // 3b. Word boundary initials / acronym match (e.g. "gc" for "Google Chrome")
        let initials = words.compactMap { $0.first?.lowercased() }.joined()
        if initials.hasPrefix(q) {
            let diff = initials.count - q.count
            return 25_000 + max(0, 1_000 - diff * 100)
        }

        // 4. Consecutive character match / substring match: (15,000 tier)
        if let range = t.range(of: q) {
            let distance = t.distance(from: t.startIndex, to: range.lowerBound)
            return 15_000 - (distance * 100) + max(0, 1_000 - t.count * 10)
        }

        // 5. Fuzzy subsequence match: (1,000 - 10,000 tier)
        var qIndex = q.startIndex
        var tIndex = t.startIndex
        var subScore = 0
        var consecutiveCount = 0
        var prevMatched = false

        while qIndex < q.endIndex && tIndex < t.endIndex {
            let qChar = q[qIndex]
            let tChar = t[tIndex]

            if qChar == tChar {
                qIndex = q.index(after: qIndex)
                var charScore = 100

                let isWordStart = (tIndex == t.startIndex) ||
                    CharacterSet.alphanumerics.inverted.contains(
                        UnicodeScalar(t[t.index(before: tIndex)].unicodeScalars.first!.value)!
                    )
                if isWordStart {
                    charScore += 250
                }

                if prevMatched {
                    consecutiveCount += 1
                    charScore += consecutiveCount * 100
                } else {
                    consecutiveCount = 0
                }

                let dist = t.distance(from: t.startIndex, to: tIndex)
                charScore -= min(dist * 5, 100)

                subScore += charScore
                prevMatched = true
            } else {
                prevMatched = false
                consecutiveCount = 0
            }

            tIndex = t.index(after: tIndex)
        }

        if qIndex == q.endIndex {
            return max(1, subScore)
        }

        return nil
    }
}
