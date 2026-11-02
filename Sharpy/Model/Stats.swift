import Foundation

/// Streaks, XP and accuracy derived from the day logs.
struct Stats {
    var currentStreak = 0
    var longestStreak = 0
    var totalXP = 0
    var answered = 0
    var correct = 0
    var trapsSeen = 0
    var trapsCaught = 0
    var doneToday = false
    var todayAnswered = 0
    var todayXP = 0
    /// Days (yyyy-MM-dd) on which the daily goal was met.
    var goalDays: Set<String> = []

    var accuracy: Double? { answered > 0 ? Double(correct) / Double(answered) : nil }

    init(logs: [DayLog], now: Date = .now) {
        let today = DayKey.string(for: now)
        for log in logs {
            totalXP += log.xp
            answered += log.answered
            correct += log.correct
            trapsSeen += log.trapsSeen
            trapsCaught += log.trapsCaught
            if log.goalMet { goalDays.insert(log.day) }
            if log.day == today {
                doneToday = log.goalMet
                todayAnswered = log.answered
                todayXP = log.xp
            }
        }

        // The streak survives until the end of today even if today isn't done yet.
        let calendar = Calendar.current
        var cursor = calendar.startOfDay(for: now)
        if !goalDays.contains(today) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        while goalDays.contains(DayKey.string(for: cursor)) {
            currentStreak += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }

        var run = 0
        var previous: Date?
        for key in goalDays.sorted() {
            guard let date = DayKey.date(from: key) else { continue }
            if let previous, calendar.dateComponents([.day], from: previous, to: date).day == 1 {
                run += 1
            } else {
                run = 1
            }
            longestStreak = max(longestStreak, run)
            previous = date
        }
    }
}
