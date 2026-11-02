import SwiftData
import SwiftUI

struct SessionResult {
    var answered = 0
    var correct = 0
    var xp = 0
    var trapsSeen = 0
    var trapsCaught = 0
    var metGoalNow = false
}

/// Loads a session (due reviews + new questions), runs it, then shows the summary.
struct SessionFlowView: View {
    let mode: SessionMode

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case loading, running, summary
        case failed(String)
    }

    @State private var phase: Phase = .loading
    @State private var status = "Getting your questions ready…"
    @State private var items: [QuizItem] = []
    @State private var index = 0
    /// The submitted answer for the current item; nil while the learner is choosing.
    @State private var answer: Set<Int>?
    /// Ticked choices on a "select all" item before Check is tapped.
    @State private var picks: Set<Int> = []
    @State private var result = SessionResult()
    @State private var reported: Set<String> = []

    var body: some View {
        Group {
            switch phase {
            case .loading: loading
            case .running: running
            case .summary: SessionSummaryView(result: result, streak: currentStreak, close: { dismiss() })
            case .failed(let message): failed(message)
            }
        }
        .background(Palette.page)
        .animation(.snappy, value: phase)
        .task { await load() }
    }

    // MARK: Loading

    private var loading: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(Palette.brand.gradient)
                .symbolEffect(.pulse)
            Text(status)
                .font(.headline)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
                .animation(.default, value: status)
            Text("Questions come from trusted sources and are double-checked before you see them. A brand-new topic can take a minute or two the first time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button("Cancel") { dismiss() }.foregroundStyle(.secondary)
        }
        .padding(32)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.bubble").font(.system(size: 48)).foregroundStyle(.secondary)
            Text(message).font(.headline).multilineTextAlignment(.center)
            Spacer()
            Button("Try again") {
                phase = .loading
                Task { await load() }
            }
            .buttonStyle(PrimaryButtonStyle())
            Button("Close") { dismiss() }.foregroundStyle(.secondary)
        }
        .padding(32)
    }

    // MARK: Running

    private var running: some View {
        let item = items[index]
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                Button { finishEarly() } label: {
                    Image(systemName: "xmark").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                }
                .accessibilityLabel("End session")
                ProgressView(value: Double(index + (answer == nil ? 0 : 1)), total: Double(items.count))
                    .tint(Palette.correct)
                Label("\(result.xp)", systemImage: "bolt.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Palette.trap)
                    .monospacedDigit()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ItemCardView(item: item, answer: answer, picks: picks, onTap: tap)
                        if let answer {
                            FeedbackView(
                                item: item,
                                correct: answer == item.correctAnswers,
                                reported: reported.contains(item.id),
                                onReport: { reason in report(item, reason: reason) }
                            )
                            .id("feedback")
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(20)
                }
                .onChange(of: answer) { _, new in
                    if new != nil { withAnimation(.snappy.delay(0.15)) { proxy.scrollTo("feedback", anchor: .top) } }
                }
            }

            if let answer {
                Button(index + 1 < items.count ? "Continue" : "Finish") { next() }
                    .buttonStyle(PrimaryButtonStyle(color: answer == item.correctAnswers ? Palette.correct : Palette.brand))
                    .padding(20)
                    .transition(.move(edge: .bottom))
            } else if item.kind == .selectAll {
                Button("Check") { submit(picks) }
                    .buttonStyle(PrimaryButtonStyle(color: picks.isEmpty ? .gray : Palette.brand))
                    .disabled(picks.isEmpty)
                    .padding(20)
            }
        }
        .animation(.snappy, value: answer)
        .sensoryFeedback(trigger: answer) { _, new in
            guard let new else { return nil }
            return new == item.correctAnswers ? .success : .error
        }
    }

    // MARK: Logic

    private var currentStreak: Int {
        Stats(logs: (try? context.fetch(FetchDescriptor<DayLog>())) ?? []).currentStreak
    }

    private func load() async {
        let now = Date()
        let records = (try? context.fetch(FetchDescriptor<ItemRecord>())) ?? []
        let due = records.filter { $0.isDue(at: now) }.sorted { ($0.due ?? now) < ($1.due ?? now) }
        var reviews = due.prefix(mode == .review ? 15 : 3).compactMap(\.item)
        var fresh: [QuizItem] = []

        if mode == .daily {
            let need = max(3, settings.dailyGoal - reviews.count)
            let seen = records.sorted { $0.firstSeen > $1.firstSeen }.prefix(2000).map(\.id)
            do {
                fresh = try await settings.api.sessionItems(
                    topics: settings.topics, level: settings.level, count: need, seen: Array(seen)
                ) { message in status = message }
                let reviewIDs = Set(reviews.map(\.id))
                fresh.removeAll { reviewIDs.contains($0.id) }
            } catch {
                if reviews.isEmpty {
                    phase = .failed(error.localizedDescription)
                    return
                }
            }
        }

        if !Launch.isDemo { reviews.shuffle() }
        // Spread reviews through the new questions rather than front-loading them.
        var queue = fresh
        for (i, review) in reviews.enumerated() {
            queue.insert(review, at: min(queue.count, i * 3 + 1))
        }
        if Launch.isDemo { queue = DemoData.items }
        guard !queue.isEmpty else {
            phase = .failed("Nothing to review right now. Nice work.")
            return
        }
        items = queue
        index = 0
        answer = nil
        picks = []
        phase = .running
        if Launch.tab == "answered" { submit(queue[0].correctAnswers) }
    }

    /// Single-answer kinds submit on tap; "select all" toggles until Check.
    private func tap(_ choice: Int) {
        guard answer == nil else { return }
        if items[index].kind == .selectAll {
            if picks.contains(choice) { picks.remove(choice) } else { picks.insert(choice) }
        } else {
            submit([choice])
        }
    }

    /// Scores the answer: all or nothing, so a partly right "select all" counts as a miss.
    private func submit(_ choices: Set<Int>) {
        guard answer == nil, !choices.isEmpty else { return }
        answer = choices
        let item = items[index]
        let correct = choices == item.correctAnswers

        let gained = (correct ? 10 : 0) + (correct && item.isTrap ? 5 : 0)
        result.answered += 1
        result.xp += gained
        if correct { result.correct += 1 }
        if item.isTrap {
            result.trapsSeen += 1
            if correct { result.trapsCaught += 1 }
        }

        let id = item.id
        let record = (try? context.fetch(FetchDescriptor<ItemRecord>(predicate: #Predicate { $0.id == id })))?.first
            ?? { let r = ItemRecord(item: item); context.insert(r); return r }()
        record.record(correct: correct)

        let key = DayKey.string()
        let log = (try? context.fetch(FetchDescriptor<DayLog>(predicate: #Predicate { $0.day == key })))?.first
            ?? { let l = DayLog(day: key); context.insert(l); return l }()
        log.answered += 1
        log.xp += gained
        if correct { log.correct += 1 }
        if item.isTrap {
            log.trapsSeen += 1
            if correct { log.trapsCaught += 1 }
        }
        if !log.goalMet && log.answered >= settings.dailyGoal {
            log.goalMet = true
            result.metGoalNow = true
        }
        try? context.save()
    }

    private func next() {
        if index + 1 < items.count {
            index += 1
            answer = nil
            picks = []
        } else {
            finish()
        }
    }

    private func finishEarly() {
        if result.answered > 0 { finish() } else { dismiss() }
    }

    private func finish() {
        let stats = Stats(logs: (try? context.fetch(FetchDescriptor<DayLog>())) ?? [])
        Reminders.reschedule(
            enabled: settings.remindersOn,
            hour: settings.reminderHour,
            minute: settings.reminderMinute,
            topics: settings.topics,
            streak: stats.currentStreak,
            doneToday: stats.doneToday
        )
        phase = .summary
    }

    private func report(_ item: QuizItem, reason: String) {
        reported.insert(item.id)
        Task { await settings.api.report(itemID: item.id, reason: reason) }
    }
}
