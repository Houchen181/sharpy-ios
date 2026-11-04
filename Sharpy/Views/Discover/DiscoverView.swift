import SwiftUI

/// Builds the Discover tab once a day with the learner's own AI provider; the
/// result is cached on disk, so later visits are instant and free.
@MainActor
final class DiscoverModel: ObservableObject {
    @Published var feed: DiscoverFeed? = DiscoverCache.load()
    @Published var feedError: String?
    @Published var feedStatus: String?
    @Published var updates: [String: [FieldUpdate]] = [:]
    @Published var updateNotes: [String: String] = [:]
    @Published var updatesStatus: String?
    private var buildingFeed = false
    private var buildingUpdates: Set<String> = []

    func load(config: ProviderConfig?, topics: [String], force: Bool = false) async {
        if Launch.isDemo {
            feed = DemoData.feed
            for topic in topics { updates[topic] = DemoData.updates.filter { $0.topic == topic } }
            return
        }
        guard let config else {
            if feed?.date != DayKey.string() { feedError = LLMError.noProvider.localizedDescription }
            return
        }
        async let feedTask: Void = loadFeed(config: config, force: force)
        async let updatesTask: Void = loadUpdates(config: config, topics: topics, force: force)
        _ = await (feedTask, updatesTask)
    }

    private func loadFeed(config: ProviderConfig, force: Bool) async {
        let today = DayKey.string()
        guard !buildingFeed, force || feed?.date != today else { return }
        buildingFeed = true
        feedStatus = "Preparing today's cards…"
        defer {
            buildingFeed = false
            feedStatus = nil
        }
        do {
            let fresh = try await DiscoverBuilder.feed(for: .now, client: LLMClient(config: config)) { @Sendable message in
                Task { @MainActor in self.feedStatus = message }
            }
            feed = fresh
            feedError = nil
            DiscoverCache.save(fresh)
        } catch {
            if feed == nil || feed?.date != today { feedError = error.localizedDescription }
        }
    }

    private func loadUpdates(config: ProviderConfig, topics: [String], force: Bool) async {
        let today = DayKey.string()
        for topic in topics {
            if !force, let cached = DiscoverCache.updates(day: today, topic: topic) {
                updates[topic] = cached
                continue
            }
            guard !buildingUpdates.contains(topic) else { continue }
            buildingUpdates.insert(topic)
            updatesStatus = "Reading new papers on “\(topic)”…"
            do {
                let items = try await DiscoverBuilder.updates(topic: topic, client: LLMClient(config: config))
                updates[topic] = items
                updateNotes[topic] = nil
                DiscoverCache.saveUpdates(items, day: today, topic: topic)
            } catch {
                updates[topic] = []
                updateNotes[topic] = error.localizedDescription
            }
            buildingUpdates.remove(topic)
        }
        updatesStatus = nil
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

                    if let status = model.feedStatus {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text(status).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(model.feed == nil ? 40 : 8)
                    }
                    if let feed = model.feed {
                        ForEach(feed.cards) { DiscoverCardView(card: $0) }
                    } else if let error = model.feedError, model.feedStatus == nil {
                        Text(error).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(24)
                    }

                    fieldSection
                }
                .padding(16)
            }
            .background(Palette.page)
            .navigationTitle("Discover")
            .refreshable { await model.load(config: settings.providerConfig, topics: settings.topics, force: true) }
            .task(id: settings.topics + [settings.providerConfig?.model ?? ""]) {
                await model.load(config: settings.providerConfig, topics: settings.topics)
            }
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
                .foregroundStyle(Palette.brand)
            Text(card.title).font(.title3.bold())
            Text(card.body).fixedSize(horizontal: false, vertical: true)
            if !card.bullets.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(card.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 8) {
                            Circle().fill(Palette.brand).frame(width: 6, height: 6).padding(.top, 7)
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
                let color: Color = picked == nil ? Palette.brand : (isAnswer ? Palette.correct : (picked == i ? Palette.wrong : .secondary))
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
