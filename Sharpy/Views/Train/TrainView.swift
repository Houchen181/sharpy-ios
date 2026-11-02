import SwiftData
import SwiftUI

enum SessionMode: String, Identifiable {
    /// Due reviews plus new questions up to the daily goal.
    case daily
    /// Only items due for review.
    case review
    var id: String { rawValue }
}

struct TrainView: View {
    @EnvironmentObject private var settings: AppSettings
    @Query private var logs: [DayLog]
    @Query private var records: [ItemRecord]
    @State private var mode: SessionMode? = Launch.tab == "session" || Launch.tab == "answered" ? .daily : nil

    private var stats: Stats { Stats(logs: logs) }
    private var dueCount: Int { records.filter { $0.isDue() }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    todayCard
                    if dueCount > 0 { reviewCard }
                    topicsCard
                    honestyNote
                }
                .padding(16)
            }
            .background(Palette.page)
            .navigationTitle(greeting)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { StreakBadge(streak: stats.currentStreak) }
            }
            .fullScreenCover(item: $mode) { mode in
                SessionFlowView(mode: mode)
            }
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<18: "Good afternoon"
        default: "Good evening"
        }
    }

    private var todayCard: some View {
        let s = stats
        let progress = min(1, Double(s.todayAnswered) / Double(max(settings.dailyGoal, 1)))
        return VStack(spacing: 18) {
            HStack(spacing: 20) {
                ZStack {
                    Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(s.doneToday ? Palette.correct : Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 0) {
                        Text("\(min(s.todayAnswered, settings.dailyGoal))").font(.title.bold()).monospacedDigit()
                        Text("of \(settings.dailyGoal)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.doneToday ? "Goal met today" : "Today's workout").font(.title3.bold())
                    Text(s.doneToday
                         ? "Nice. Your streak is safe. Keep going if you're curious."
                         : "Mixed questions from your topics. Watch for traps.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label("\(s.todayXP) XP today", systemImage: "bolt.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Palette.trap)
                }
                Spacer(minLength: 0)
            }
            Button(s.doneToday ? "Practice more" : (s.todayAnswered > 0 ? "Keep going" : "Start")) {
                mode = .daily
            }
            .buttonStyle(PrimaryButtonStyle(color: s.doneToday ? Palette.correct : .accentColor))
        }
        .padding(18)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var reviewCard: some View {
        Button { mode = .review } label: {
            HStack(spacing: 14) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Palette.trap)
                    .frame(width: 44, height: 44)
                    .background(Palette.trap.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(dueCount) to review").font(.headline)
                    Text("Revisit what tripped you up, right before you'd forget it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
        }
        .buttonStyle(.plain)
    }

    private var topicsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your topics").font(.headline)
                Spacer()
                NavigationLink("Edit") { TopicsEditor() }.font(.subheadline)
            }
            FlowLayout {
                ForEach(settings.topics, id: \.self) { Chip(text: $0) }
            }
            Text(settings.level.title + " level").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private var honestyNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(Color.accentColor)
            Text("Questions are written by AI from trusted sources, then independently re-checked against the cited text. Some statements are deliberately wrong: your job is to catch them.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }
}

struct TopicsEditor: View {
    var body: some View {
        ScrollView { TopicPicker().padding(16) }
            .background(Palette.page)
            .navigationTitle("Topics")
            .navigationBarTitleDisplayMode(.inline)
    }
}
