import Foundation
import UserNotifications

/// Local notifications, Duolingo style: one reminder a day at the learner's time for the
/// next week, plus an evening nudge when a streak is on the line. Rescheduled whenever
/// the app opens or a goal is met, so a finished day never gets nagged. If the learner
/// stops opening the app, reminders stop after a week.
enum Reminders {
    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func reschedule(enabled: Bool, hour: Int, minute: Int, topics: [String], streak: Int, doneToday: Bool) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()
        guard enabled else { return }

        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday) else { continue }
            if offset == 0 && doneToday { continue }

            if let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day), fire > now {
                let dayNumber = calendar.ordinality(of: .day, in: .era, for: day) ?? offset
                add(center, id: "daily-\(offset)", at: fire, content: daily(variant: dayNumber, topics: topics))
            }

            // Evening nudge: today if the streak is alive but today isn't done yet;
            // tomorrow if today is done (the streak will be at stake again).
            let nudgeToday = offset == 0 && !doneToday && streak > 0
            let nudgeTomorrow = offset == 1 && doneToday && streak > 0
            if (nudgeToday || nudgeTomorrow), hour < 20,
               let fire = calendar.date(bySettingHour: 20, minute: 30, second: 0, of: day), fire > now {
                add(center, id: "nudge-\(offset)", at: fire, content: nudge(streak: streak))
            }
        }
    }

    private static func add(_ center: UNUserNotificationCenter, id: String, at date: Date, content: UNNotificationContent) {
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private static func daily(variant: Int, topics: [String]) -> UNNotificationContent {
        let topic = topics.isEmpty ? "your field" : topics[variant % topics.count]
        let options: [(String, String)] = [
            ("Your daily sharpening is ready", "A few questions on \(topic). One of them is a trap."),
            ("Can you spot today's trap?", "Sharpy hid a convincing wrong statement in today's set."),
            ("Five minutes, sharper mind", "Think it through yourself before you ask an AI."),
            ("Fresh questions on \(topic)", "Every answer is checked against a cited source. Ready?"),
            ("Keep your edge", "Recalling beats rereading. Quick workout?"),
        ]
        let (title, body) = options[variant % options.count]
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        return content
    }

    private static func nudge(streak: Int) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "🔥 Your \(streak)-day streak is on the line"
        content.body = "One quick set keeps it alive."
        content.sound = .default
        return content
    }
}
