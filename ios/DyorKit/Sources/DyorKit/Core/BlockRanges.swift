import Foundation

/// Sets of blocks as merged, ascending ranges.
enum BlockRanges {
    /// `ranges` within `bound`.
    static func intersect(_ ranges: [ClosedRange<UInt64>], _ bound: ClosedRange<UInt64>) -> [ClosedRange<UInt64>] {
        LogsRead.merge(ranges).compactMap { range in
            let low = max(range.lowerBound, bound.lowerBound), high = min(range.upperBound, bound.upperBound)
            return low <= high ? low...high : nil
        }
    }

    /// `ranges` without any block of `cuts`.
    static func subtract(_ ranges: [ClosedRange<UInt64>], _ cuts: [ClosedRange<UInt64>]) -> [ClosedRange<UInt64>] {
        let cuts = LogsRead.merge(cuts)
        var out: [ClosedRange<UInt64>] = []
        for range in LogsRead.merge(ranges) {
            var low = range.lowerBound
            var whole = true
            for cut in cuts where cut.upperBound >= low && cut.lowerBound <= range.upperBound {
                if cut.lowerBound > low { out.append(low...(cut.lowerBound - 1)) }
                guard cut.upperBound < range.upperBound else { whole = false; break }
                low = cut.upperBound + 1
            }
            if whole { out.append(low...range.upperBound) }
        }
        return out
    }

    /// Whether `block` lies in one of `ranges`.
    static func contains(_ ranges: [ClosedRange<UInt64>], _ block: UInt64) -> Bool {
        ranges.contains { $0.contains(block) }
    }
}
