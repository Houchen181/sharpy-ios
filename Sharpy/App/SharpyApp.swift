import SwiftData
import SwiftUI

@main
struct SharpyApp: App {
    @StateObject private var settings = Launch.isDemo ? AppSettings.demo() : AppSettings()
    @StateObject private var bank: QuestionBank
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        let schema = Schema([ItemRecord.self, DayLog.self, BankItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: Launch.isDemo)
        let container: ModelContainer
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not open Sharpy's store: \(error)")
        }
        self.container = container
        _bank = StateObject(wrappedValue: QuestionBank(context: container.mainContext))
        if Launch.isDemo { DemoData.seed(container.mainContext) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(bank)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshReminders() }
        }
    }

    @MainActor
    private func refreshReminders() {
        let logs = (try? container.mainContext.fetch(FetchDescriptor<DayLog>())) ?? []
        let stats = Stats(logs: logs)
        Reminders.reschedule(
            enabled: settings.remindersOn && settings.onboarded,
            hour: settings.reminderHour,
            minute: settings.reminderMinute,
            topics: settings.topics,
            streak: stats.currentStreak,
            doneToday: stats.doneToday
        )
    }
}
