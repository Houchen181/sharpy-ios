import Foundation
import SwiftUI

/// The learner's choices, kept in UserDefaults. API keys live in the Keychain.
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

    /// Which AI service the learner's own key is for.
    @Published var provider: ProviderKind { didSet { defaults.set(provider.rawValue, forKey: "provider") } }
    /// Chosen model per provider.
    @Published var models: [String: String] { didSet { defaults.set(models, forKey: "models") } }
    /// Endpoint for the "Other (OpenAI-compatible)" provider.
    @Published var customBaseURL: String { didSet { defaults.set(customBaseURL, forKey: "customBaseURL") } }
    /// Bumped whenever a key is saved or removed, so views re-read the Keychain.
    @Published private(set) var keyRevision = 0

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
        provider = ProviderKind(rawValue: defaults.string(forKey: "provider") ?? "") ?? .anthropic
        models = defaults.dictionary(forKey: "models") as? [String: String] ?? [:]
        customBaseURL = defaults.string(forKey: "customBaseURL") ?? ""
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

    // MARK: AI provider

    /// The model chosen for the current provider.
    var model: String {
        get { models[provider.rawValue] ?? provider.defaultModel }
        set { models[provider.rawValue] = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    var baseURL: String { provider == .custom ? customBaseURL : provider.defaultBaseURL }

    func key(for kind: ProviderKind) -> String? {
        _ = keyRevision
        return Keychain.get(kind.keychainAccount)
    }

    func setKey(_ key: String?, for kind: ProviderKind) {
        Keychain.set(key?.trimmingCharacters(in: .whitespacesAndNewlines), for: kind.keychainAccount)
        keyRevision += 1
    }

    /// Everything needed to call the provider, or nil while something is missing.
    var providerConfig: ProviderConfig? {
        let key = self.key(for: provider) ?? ""
        if provider.requiresKey && key.isEmpty { return nil }
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: base.hasSuffix("/") ? String(base.dropLast()) : base), url.scheme != nil, url.host != nil,
              !model.isEmpty else { return nil }
        return ProviderConfig(kind: provider, baseURL: url, model: model, key: key)
    }

    /// Whether practice can run: a working provider, or the screenshot demo.
    var ready: Bool { Launch.isDemo || providerConfig != nil }

    /// Settings for screenshot runs (-ui-demo): a separate, reset defaults domain.
    static func demo() -> AppSettings {
        let suite = "sharpy.demo"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        settings.onboarded = Launch.tab != "onboarding"
        // The tour starts at onboarding and picks its topics on camera.
        settings.topics = Launch.tab == "onboarding" ? [] : ["Immunology", "Quantum computing", "Macroeconomics"]
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
    /// Recording the promo tour: demo mode plus realistic waits where the model would work.
    static var isTour: Bool { arguments.contains("-ui-tour") }
    static var tab: String? { value(after: "-ui-tab") }

    private static func value(after flag: String) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}
