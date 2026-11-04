import Foundation

/// What this phone has asked its AI provider for, per calendar month, so learners
/// can see roughly what Sharpy costs them. Kept in UserDefaults.
struct UsageTotals: Codable {
    var inputTokens = 0
    var outputTokens = 0
    var searches = 0
    var dollars = 0.0
    /// False once any request came back without a price (most non-Anthropic providers).
    var costComplete = true
}

enum UsageStore {
    private static let lock = NSLock()
    private static let defaults = UserDefaults.standard
    /// Question batches generated per day. A safety stop so a bug or a loop can't
    /// run up the learner's bill.
    static let dailyBatchCap = 12

    // Built from Calendar rather than DayKey's shared formatter: requests finish on background threads.
    private static func monthKey(_ date: Date = .now) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return String(format: "usage.%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    private static func dayKey(_ date: Date = .now) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "batches.%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func record(input: Int, output: Int, searches: Int, dollars: Double?) {
        lock.lock()
        defer { lock.unlock() }
        var totals = load(monthKey())
        totals.inputTokens += input
        totals.outputTokens += output
        totals.searches += searches
        if let dollars {
            totals.dollars += dollars
        } else {
            totals.costComplete = false
        }
        if let data = try? JSONEncoder().encode(totals) { defaults.set(data, forKey: monthKey()) }
    }

    static func thisMonth() -> UsageTotals {
        lock.lock()
        defer { lock.unlock() }
        return load(monthKey())
    }

    private static func load(_ key: String) -> UsageTotals {
        guard let data = defaults.data(forKey: key), let totals = try? JSONDecoder().decode(UsageTotals.self, from: data)
        else { return UsageTotals() }
        return totals
    }

    static func batchesToday() -> Int {
        defaults.integer(forKey: dayKey())
    }

    static func countBatch() {
        lock.lock()
        defer { lock.unlock() }
        defaults.set(defaults.integer(forKey: dayKey()) + 1, forKey: dayKey())
    }
}
