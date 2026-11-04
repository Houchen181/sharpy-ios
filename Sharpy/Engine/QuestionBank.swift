import SwiftData
import SwiftUI
import UIKit

/// A checked question waiting on the phone to be practiced.
@Model
final class BankItem {
    @Attribute(.unique) var id: String
    /// Lower-cased, single-spaced topic, so "Immunology" and "immunology " share a bank.
    var topicKey: String
    var level: String
    /// The full QuizItem as JSON.
    var payload: Data
    var created: Date

    init(item: QuizItem, level: Level, now: Date = .now) {
        id = item.id
        topicKey = QuestionBank.key(item.topic)
        self.level = level.rawValue
        payload = (try? JSONEncoder().encode(item)) ?? Data()
        created = now
    }

    var item: QuizItem? { try? JSONDecoder().decode(QuizItem.self, from: payload) }
}

/// The on-device question bank. Sessions draw from it; a topic that runs low is
/// refilled with the learner's own AI provider, ideally before they need it.
@MainActor
final class QuestionBank: ObservableObject {
    /// Topic → what's happening while its questions are being prepared.
    @Published private(set) var preparing: [String: String] = [:]

    private let context: ModelContext
    private var running: [String: Task<Void, Error>] = [:]

    /// Below this many waiting questions, a topic is refilled after a session.
    static let lowWater = 8

    init(context: ModelContext) {
        self.context = context
    }

    nonisolated static func key(_ topic: String) -> String {
        topic.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Questions waiting for a topic, oldest first.
    func waiting(_ topic: String, level: Level) -> [BankItem] {
        let key = Self.key(topic)
        let raw = level.rawValue
        let descriptor = FetchDescriptor<BankItem>(
            predicate: #Predicate { $0.topicKey == key && $0.level == raw },
            sortBy: [SortDescriptor(\.created)])
        return (try? context.fetch(descriptor)) ?? []
    }

    func readyCount(topics: [String], level: Level) -> Int {
        topics.reduce(0) { $0 + waiting($1, level: level).count }
    }

    /// New questions for a session, interleaved across topics. Topics that can't fill
    /// their share are refilled first (two at a time), which takes a minute or two.
    func freshItems(topics: [String], level: Level, count: Int, config: ProviderConfig?) async throws -> [QuizItem] {
        if Launch.isDemo { return await demoItems(topics) }
        guard !topics.isEmpty else { throw GenerationError(message: "Add at least one topic first.") }

        let perTopic = Int((Double(count) / Double(topics.count)).rounded(.up))
        let short = topics.map { ($0, waiting($0, level: level).count) }
            .filter { $0.1 < perTopic }
            .sorted { $0.1 < $1.1 }
            .prefix(2)
            .map { $0.0 }
        var problems: [Error] = []
        if !short.isEmpty {
            if let config {
                let jobs = short.map { topic in Task { try await self.prepare(topic: topic, level: level, config: config) } }
                for job in jobs {
                    do { try await job.value } catch { problems.append(error) }
                }
            } else {
                problems.append(LLMError.noProvider)
            }
        }

        // Oldest first, taking turns between topics; a well-stocked topic covers for one that came up short.
        var queues = topics.map { waiting($0, level: level).compactMap(\.item) }
        var items: [QuizItem] = []
        while items.count < count, queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where !queues[i].isEmpty && items.count < count {
                items.append(queues[i].removeFirst())
            }
        }
        if items.isEmpty {
            throw problems.first ?? GenerationError(message: "Couldn't prepare questions right now. Please try again.")
        }
        return items
    }

    /// Makes one batch for a topic, or waits for the batch already being made.
    func prepare(topic: String, level: Level, config: ProviderConfig) async throws {
        let key = Self.key(topic) + "|" + level.rawValue
        if let job = running[key] {
            try await job.value
            return
        }
        guard UsageStore.batchesToday() < UsageStore.dailyBatchCap else { throw LLMError.dailyLimit }
        let variety = UserDefaults.standard.integer(forKey: "variety." + key)
        let avoid = covered(topic: topic, level: level)
        preparing[topic] = "Getting started…"
        let job = Task {
            let items = try await QuestionWriter.batch(
                topic: topic, level: level, avoid: avoid, variety: variety, client: LLMClient(config: config)
            ) { @Sendable message in
                Task { @MainActor in
                    if self.running[key] != nil { self.preparing[topic] = message }
                }
            }
            UsageStore.countBatch()
            UserDefaults.standard.set(variety + 1, forKey: "variety." + key)
            for item in items { self.context.insert(BankItem(item: item, level: level)) }
            try? self.context.save()
            if items.isEmpty {
                throw GenerationError(message: "None of the new questions on “\(topic)” passed the fact check. Please try again.")
            }
        }
        running[key] = job
        defer {
            running[key] = nil
            preparing[topic] = nil
        }
        try await job.value
    }

    /// Refills topics that are running low while the learner does something else.
    func topUp(topics: [String], level: Level, config: ProviderConfig?) {
        guard let config, !Launch.isDemo else { return }
        let low = topics.filter {
            waiting($0, level: level).count < Self.lowWater && running[Self.key($0) + "|" + level.rawValue] == nil
        }
        guard !low.isEmpty else { return }
        let assertion = BackgroundAssertion()
        Task {
            for topic in low { try? await prepare(topic: topic, level: level, config: config) }
            assertion.end()
        }
    }

    /// An answered question leaves the bank; its review schedule lives on in ItemRecord.
    func consume(_ id: String) {
        let target = id
        if let item = try? context.fetch(FetchDescriptor<BankItem>(predicate: #Predicate { $0.id == target })).first {
            context.delete(item)
        }
    }

    /// A reported question goes for good: out of the bank and out of reviews.
    func discard(_ id: String) {
        consume(id)
        let target = id
        if let record = try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == target })).first {
            context.delete(record)
        }
        try? context.save()
    }

    /// What the learner already has on a topic (one line per question), so a new batch looks elsewhere.
    private func covered(topic: String, level: Level) -> [String] {
        let name = topic
        let records = (try? context.fetch(FetchDescriptor<ItemRecord>(
            predicate: #Predicate { $0.topic == name },
            sortBy: [SortDescriptor(\.firstSeen, order: .reverse)]))) ?? []
        let items = waiting(topic, level: level).compactMap(\.item) + records.prefix(30).compactMap(\.item)
        return items.map { String($0.explanation.prefix(140)) }
    }

    /// Screenshot and tour runs: sample questions, with the pauses a real batch would show.
    private func demoItems(_ topics: [String]) async -> [QuizItem] {
        if Launch.isTour {
            for message in ["Searching trusted sources for “\(topics.first ?? "")”…",
                            "Writing questions from 14 sourced facts…",
                            "Double-checking every answer against the sources…"] {
                preparing["demo"] = message
                try? await Task.sleep(for: .seconds(1.8))
            }
            preparing["demo"] = nil
        }
        return DemoData.items
    }
}

/// Asks iOS for extra time so a batch in progress can finish if the app is closed.
@MainActor
final class BackgroundAssertion {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Preparing questions") { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
