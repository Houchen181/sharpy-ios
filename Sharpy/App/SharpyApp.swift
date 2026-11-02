import BackgroundTasks
import SwiftData
import SwiftUI

@main
struct SharpyApp: App {
    static let refreshTaskID = "com.houchenli.sharpy.refresh"

    @StateObject private var settings = Launch.isDemo ? AppSettings.demo() : AppSettings()
    @Environment(\.scenePhase) private var scenePhase
    private let container: ModelContainer

    init() {
        let schema = Schema([ItemRecord.self, DayLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: Launch.isDemo)
        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Could not open Sharpy's store: \(error)")
        }
        if Launch.isDemo { DemoData.seed(container.mainContext) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
        }
        .modelContainer(container)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: refreshReminders()
            case .background: Self.scheduleRefresh()
            default: break
            }
        }
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            // Pre-load today's Discover cards so they're there when the reminder is tapped.
            await DiscoverCache.prefetch()
            Self.scheduleRefresh()
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

    /// Asks iOS to wake the app early tomorrow morning.
    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now)) ?? .now
        request.earliestBeginDate = calendar.date(bySettingHour: 6, minute: 0, second: 0, of: tomorrow)
        try? BGTaskScheduler.shared.submit(request)
    }
}
