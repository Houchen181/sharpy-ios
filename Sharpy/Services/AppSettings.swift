import Foundation
import SwiftUI

/// The learner's choices, kept in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var onboarded: Bool { didSet { defaults.set(onboarded, forKey: "onboarded") } }
    @Published var topics: [String] { didSet { defaults.set(topics, forKey: "topics") } }
    @Published var level: Level { didSet { defaults.set(level.rawValue, forKey: "level") } }
    @Published var dailyGoal: Int { didSet { defaults.set(dailyGoal, forKey: "dailyGoal") } }
    @Published var remindersOn: Bool { didSet { defaults.set(remindersOn, forKey: "remindersOn") } }
    @Published var reminderHour: Int { didSet { defaults.set(reminderHour, forKey: "reminderHour") } }
    @Published var reminderMinute: Int { didSet { defaults.set(reminderMinute, forKey: "reminderMinute") } }

    /// Random per-install ID the server uses for fair-use limits. Not tied to the person.
    let installID: String

    static let maxTopics = 5
    static let goals = [5, 10, 15]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        onboarded = defaults.bool(forKey: "onboarded")
        topics = defaults.stringArray(forKey: "topics") ?? []
        level = Level(rawValue: defaults.string(forKey: "level") ?? "") ?? .student
        dailyGoal = defaults.object(forKey: "dailyGoal") as? Int ?? 10
        remindersOn = defaults.bool(forKey: "remindersOn")
        reminderHour = defaults.object(forKey: "reminderHour") as? Int ?? 8
        reminderMinute = defaults.object(forKey: "reminderMinute") as? Int ?? 30
        if let id = defaults.string(forKey: "installID") {
            installID = id
        } else {
            installID = UUID().uuidString
            defaults.set(installID, forKey: "installID")
        }
    }

    /// Binds a DatePicker to the reminder hour and minute.
    var reminderTime: Date {
        get {
            Calendar.current.date(bySettingHour: reminderHour, minute: reminderMinute, second: 0, of: .now) ?? .now
        }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            reminderHour = parts.hour ?? 8
            reminderMinute = parts.minute ?? 30
        }
    }

    func addTopic(_ raw: String) {
        let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard topic.count >= 2, topic.count <= 48, topics.count < Self.maxTopics,
              !topics.contains(where: { $0.caseInsensitiveCompare(topic) == .orderedSame })
        else { return }
        topics.append(topic)
    }

    var api: APIClient { APIClient(installID: installID) }

    /// Settings for screenshot runs (-ui-demo): a separate, reset defaults domain.
    static func demo() -> AppSettings {
        let suite = "sharpy.demo"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        settings.onboarded = Launch.tab != "onboarding"
        settings.topics = ["Immunology", "Quantum computing", "Macroeconomics"]
        settings.level = .student
        settings.dailyGoal = 10
        settings.remindersOn = true
        return settings
    }
}

/// Launch arguments used by CI screenshot runs.
enum Launch {
    static let arguments = ProcessInfo.processInfo.arguments
    static var isDemo: Bool { arguments.contains("-ui-demo") }
    static var tab: String? { value(after: "-ui-tab") }

    private static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}
