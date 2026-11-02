import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        if settings.onboarded {
            MainTabs()
        } else {
            OnboardingView()
        }
    }
}

enum AppTab: String {
    case train, discover, profile
}

struct MainTabs: View {
    @State private var tab: AppTab = {
        switch Launch.tab {
        case "discover": .discover
        case "profile": .profile
        default: .train
        }
    }()

    var body: some View {
        TabView(selection: $tab) {
            TrainView()
                .tabItem { Label("Train", systemImage: "brain.head.profile") }
                .tag(AppTab.train)
            DiscoverView()
                .tabItem { Label("Discover", systemImage: "sparkles") }
                .tag(AppTab.discover)
            ProfileView()
                .tabItem { Label("You", systemImage: "person.crop.circle") }
                .tag(AppTab.profile)
        }
    }
}
