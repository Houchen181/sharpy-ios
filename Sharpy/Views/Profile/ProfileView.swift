import SwiftData
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var settings: AppSettings
    @Query private var logs: [DayLog]
    @State private var showingAbout = false

    var body: some View {
        let stats = Stats(logs: logs)
        NavigationStack {
            List {
                Section {
                    statsGrid(stats)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section("Last five weeks") {
                    StreakCalendar(goalDays: stats.goalDays)
                        .padding(.vertical, 6)
                }
                Section {
                    NavigationLink {
                        ProviderSettingsView()
                    } label: {
                        LabeledContent("Provider", value: settings.providerConfig?.displayName ?? "Not set up")
                            .lineLimit(1)
                    }
                } header: {
                    Text("AI provider")
                } footer: {
                    Text("Sharpy runs on your own API key, straight from this iPhone.")
                }
                Section("Practice") {
                    NavigationLink {
                        TopicsEditor()
                    } label: {
                        LabeledContent("Topics", value: settings.topics.joined(separator: ", "))
                            .lineLimit(1)
                    }
                    Picker("Level", selection: $settings.level) {
                        ForEach(Level.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Daily goal", selection: $settings.dailyGoal) {
                        ForEach(AppSettings.goals, id: \.self) { Text("\($0) questions").tag($0) }
                    }
                }
                Section {
                    Toggle("Daily reminder", isOn: $settings.remindersOn)
                    if settings.remindersOn {
                        DatePicker("Time", selection: $settings.reminderTime, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    Text("One reminder a day, plus an evening nudge when your streak is at risk.")
                }
                Section {
                    Button("How Sharpy checks its facts") { showingAbout = true }
                } footer: {
                    Text("Sharpy \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
            .navigationTitle("You")
            .sheet(isPresented: $showingAbout) { AboutSheet() }
            .onChange(of: settings.remindersOn) { _, on in
                if on {
                    Task {
                        if await Reminders.requestPermission() {
                            reschedule(stats)
                        } else {
                            settings.remindersOn = false
                        }
                    }
                } else {
                    reschedule(stats)
                }
            }
            .onChange(of: settings.reminderHour) { _, _ in reschedule(stats) }
            .onChange(of: settings.reminderMinute) { _, _ in reschedule(stats) }
        }
    }

    private func reschedule(_ stats: Stats) {
        Reminders.reschedule(
            enabled: settings.remindersOn,
            hour: settings.reminderHour,
            minute: settings.reminderMinute,
            topics: settings.topics,
            streak: stats.currentStreak,
            doneToday: stats.doneToday
        )
    }

    private func statsGrid(_ s: Stats) -> some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                tile("\(s.currentStreak)", "Day streak", "flame.fill", Palette.flame)
                tile("\(s.longestStreak)", "Longest streak", "trophy.fill", .yellow)
            }
            GridRow {
                tile("\(s.totalXP)", "Total XP", "bolt.fill", Palette.trap)
                tile(s.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", "Accuracy", "target", Palette.correct)
            }
            GridRow {
                tile("\(s.trapsCaught)", "Traps caught", "shield.lefthalf.filled", Palette.brand)
                tile("\(s.answered)", "Questions answered", "checkmark.circle", .secondary)
            }
        }
    }

    private func tile(_ value: String, _ label: String, _ icon: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).foregroundStyle(color)
            Text(value).font(.title.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// Five rows of seven days, today in the bottom-right; filled days met the goal.
struct StreakCalendar: View {
    let goalDays: Set<String>

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let days: [Date] = (0..<35).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
            ForEach(days, id: \.self) { day in
                let met = goalDays.contains(DayKey.string(for: day))
                let isToday = day == today
                RoundedRectangle(cornerRadius: 6)
                    .fill(met ? Palette.flame : Color.secondary.opacity(0.12))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        Text("\(calendar.component(.day, from: day))")
                            .font(.caption2.weight(isToday ? .bold : .regular))
                            .foregroundStyle(met ? .white : .secondary)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(isToday ? Palette.brand : .clear, lineWidth: 2))
            }
        }
    }
}

struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Your AI, your key",
                            "Sharpy has no server. It calls the AI provider you chose (Anthropic, OpenRouter, OpenCode or another) directly from this iPhone with your own API key, which stays in the Keychain. Your topics and progress never leave the phone except as part of those requests.")
                    section("Where questions come from",
                            "With Claude, the model searches a fixed list of trusted sites (encyclopedias, peer-reviewed journals, government and university pages, official documentation), and each fact keeps the exact excerpt the search returned. With other models, Sharpy fetches Wikipedia articles itself, and a fact is kept only if its quote appears word for word in the article.")
                    section("How answers are checked",
                            "A second, independent pass answers every question using only those excerpts. If it doesn't reach the same answer, or the excerpt doesn't settle it, the question is thrown away.")
                    section("Why some statements are wrong on purpose",
                            "Traps are convincing statements with one real error: a swapped date, a wrong attribution, reversed cause and effect, or a popular misconception. Catching them trains the habit you need when reading anything, including AI answers.")
                    section("Daily discoveries",
                            "Discover cards are written once a day from Wikipedia's featured content, NASA's Astronomy Picture of the Day, Quanta Magazine and the field of the day, and every card quotes its source word for word. Field updates summarize new papers from their abstracts; preprints are labelled because they haven't been peer reviewed.")
                    section("If something looks wrong",
                            "Tap “Something's wrong” under any answer to remove that question from your phone for good. No model is perfect, which is exactly why every answer shows its source.")
                }
                .padding(20)
            }
            .navigationTitle("How Sharpy checks facts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func section(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(body).foregroundStyle(.secondary)
        }
    }
}
