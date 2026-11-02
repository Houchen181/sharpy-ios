import SwiftUI

/// Keeps the last Discover feed on disk so the tab opens instantly (and offline).
enum DiscoverCache {
    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("discover.json")
    }

    static func load() -> DiscoverFeed? {
        guard !Launch.isDemo, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DiscoverFeed.self, from: data)
    }

    static func save(_ feed: DiscoverFeed) {
        guard !Launch.isDemo, let data = try? JSONEncoder().encode(feed) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Called from the background refresh task.
    @MainActor
    static func prefetch() async {
        let installID = UserDefaults.standard.string(forKey: "installID") ?? UUID().uuidString
        if let feed = try? await APIClient(installID: installID).discover(date: DayKey.string()) {
            save(feed)
        }
    }
}

@MainActor
final class DiscoverModel: ObservableObject {
    @Published var feed: DiscoverFeed? = DiscoverCache.load()
    @Published var feedError: String?
    @Published var loadingFeed = false
    @Published var updates: [String: [FieldUpdate]] = [:]
    @Published var updateNotes: [String: String] = [:]
    @Published var updatesStatus: String?
    private var updatesDay: String?
    private var updatesTopics: [String] = []

    func load(api: APIClient, topics: [String], force: Bool = false) async {
        let today = DayKey.string()
        async let feedTask: Void = loadFeed(api: api, today: today, force: force)
        async let updatesTask: Void = loadUpdates(api: api, topics: topics, today: today, force: force)
        _ = await (feedTask, updatesTask)
    }

    private func loadFeed(api: APIClient, today: String, force: Bool) async {
        if !force, feed?.date == today { return }
        loadingFeed = feed == nil
        defer { loadingFeed = false }
        do {
            let fresh = try await api.discover(date: today)
            feed = fresh
            feedError = nil
            DiscoverCache.save(fresh)
        } catch {
            if feed == nil { feedError = error.localizedDescription }
        }
    }

    private func loadUpdates(api: APIClient, topics: [String], today: String, force: Bool) async {
        if !force, updatesDay == today, updatesTopics == topics { return }
        updatesStatus = "Checking new papers…"
        defer { updatesStatus = nil }
        do {
            try await api.fieldUpdates(topics: topics) { [weak self] message in
                self?.updatesStatus = message
            } onTopic: { [weak self] topic, items, note in
                self?.updates[topic] = items
                self?.updateNotes[topic] = note
            }
            updatesDay = today
            updatesTopics = topics
        } catch {
            updatesStatus = nil
        }
    }
}

struct DiscoverView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = DiscoverModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    Text("Something new to learn today, from sources you can check.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    if let feed = model.feed {
                        ForEach(feed.cards) { DiscoverCardView(card: $0) }
                    } else if model.loadingFeed {
                        ProgressView("Loading today's cards…").frame(maxWidth: .infinity).padding(40)
                    } else if let error = model.feedError {
                        Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
                    }

                    fieldSection
                }
                .padding(16)
            }
            .background(Palette.page)
            .navigationTitle("Discover")
            .refreshable { await model.load(api: settings.api, topics: settings.topics, force: true) }
            .task(id: settings.topics) { await model.load(api: settings.api, topics: settings.topics) }
        }
    }

    private var fieldSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("New in your fields").font(.title2.bold())
                Spacer()
                if let status = model.updatesStatus {
                    ProgressView().controlSize(.small)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.top, 8)
            Text("Recent papers, summarized from their abstracts. Preprints are marked: they haven't been peer reviewed yet.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(settings.topics, id: \.self) { topic in
                if let items = model.updates[topic] {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(topic).font(.headline)
                        if items.isEmpty {
                            Text(model.updateNotes[topic] ?? "Nothing new and notable in the last few weeks.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(items) { FieldUpdateRow(update: $0) }
                    }
                }
            }
        }
    }
}

struct DiscoverCardView: View {
    let card: DiscoverCard
    @State private var picked: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let raw = card.imageURL, let url = URL(string: raw) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Rectangle().fill(Color.secondary.opacity(0.1))
                }
                .frame(height: 180)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            Text(card.eyebrow)
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .foregroundStyle(Color.accentColor)
            Text(card.title).font(.title3.bold())
            Text(card.body).fixedSize(horizontal: false, vertical: true)
            if !card.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(card.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Color.accentColor).frame(width: 6, height: 6).padding(.top, 7)
                            Text(bullet).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if !card.whyItMatters.isEmpty {
                Label(card.whyItMatters, systemImage: "lightbulb")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let check = card.check { checkView(check) }
            ForEach(card.sources, id: \.url) { SourceRow(source: $0) }
        }
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func checkView(_ check: CheckQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Check yourself").font(.caption.weight(.bold)).textCase(.uppercase).foregroundStyle(.secondary)
            Text(check.question).font(.subheadline.weight(.semibold))
            ForEach(check.choices.indices, id: \.self) { i in
                let isAnswer = i == check.answerIndex
                let color: Color = picked == nil ? .accentColor : (isAnswer ? Palette.correct : (picked == i ? Palette.wrong : .secondary))
                Button { picked = i } label: {
                    HStack {
                        Text(check.choices[i]).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if picked != nil && isAnswer { Image(systemName: "checkmark.circle.fill") }
                        if picked == i && !isAnswer { Image(systemName: "xmark.circle.fill") }
                    }
                    .font(.subheadline)
                    .padding(10)
                    .foregroundStyle(color)
                    .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(picked != nil)
            }
            if picked != nil {
                Text(check.explanation).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .sensoryFeedback(trigger: picked) { _, new in
            guard let new else { return nil }
            return new == check.answerIndex ? .success : .error
        }
    }
}

struct FieldUpdateRow: View {
    let update: FieldUpdate
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(update.peerReviewed ? "Peer reviewed" : "Preprint")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background((update.peerReviewed ? Palette.correct : Palette.trap).opacity(0.15), in: Capsule())
                        .foregroundStyle(update.peerReviewed ? Palette.correct : Palette.trap)
                    Text("\(update.venue) · \(update.date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(update.headline).font(.headline).multilineTextAlignment(.leading)
                Text(update.summary).font(.subheadline).multilineTextAlignment(.leading)
                if !update.whyItMatters.isEmpty {
                    Text(update.whyItMatters).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Text("From the abstract: “\(update.quote)”")
                    .font(.footnote)
                    .italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                if !update.authors.isEmpty {
                    Text(update.authors).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showing) {
            if let url = URL(string: update.url) { SafariView(url: url).ignoresSafeArea() }
        }
    }
}
