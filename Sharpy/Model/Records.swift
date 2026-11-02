import Foundation
import SwiftData

/// Every item the learner has answered, with its review schedule.
@Model
final class ItemRecord {
    @Attribute(.unique) var id: String
    var topic: String
    /// The full QuizItem as JSON, so reviews work offline.
    var payload: Data
    var firstSeen: Date
    var lastAnswered: Date?
    var timesCorrect: Int
    var timesWrong: Int
    /// Leitner box: 1 = review tomorrow … 5 = review in five weeks; past 5 it has graduated.
    var box: Int
    var due: Date?

    init(item: QuizItem, now: Date = .now) {
        id = item.id
        topic = item.topic
        payload = (try? JSONEncoder().encode(item)) ?? Data()
        firstSeen = now
        timesCorrect = 0
        timesWrong = 0
        box = 0
    }

    var item: QuizItem? { try? JSONDecoder().decode(QuizItem.self, from: payload) }

    /// Days until the next review for boxes 1…5.
    static let intervals = [1, 3, 7, 16, 35]

    /// A miss sends the item back to tomorrow. A first-try hit skips ahead to a week;
    /// each later hit moves it one box further out.
    func record(correct: Bool, now: Date = .now) {
        let firstTime = lastAnswered == nil
        lastAnswered = now
        if correct {
            timesCorrect += 1
            box = firstTime ? 3 : box + 1
        } else {
            timesWrong += 1
            box = 1
        }
        if box > Self.intervals.count {
            due = nil
        } else {
            let calendar = Calendar.current
            due = calendar.date(byAdding: .day, value: Self.intervals[box - 1], to: calendar.startOfDay(for: now))
        }
    }

    func isDue(at now: Date = .now) -> Bool {
        guard let due else { return false }
        return due <= now
    }
}

/// One row per local calendar day the learner practiced.
@Model
final class DayLog {
    /// yyyy-MM-dd in the learner's time zone.
    @Attribute(.unique) var day: String
    var answered: Int
    var correct: Int
    var xp: Int
    var trapsSeen: Int
    var trapsCaught: Int
    var goalMet: Bool

    init(day: String) {
        self.day = day
        answered = 0
        correct = 0
        xp = 0
        trapsSeen = 0
        trapsCaught = 0
        goalMet = false
    }
}

enum DayKey {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(for date: Date = .now) -> String {
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    static func date(from key: String) -> Date? {
        formatter.timeZone = .current
        return formatter.date(from: key)
    }
}
