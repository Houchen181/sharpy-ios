import Foundation

/// Builds the Discover tab on the phone: a field-of-the-day primer, cards from
/// Wikipedia's featured feed, NASA APOD and Quanta, and new papers in the learner's
/// topics. Every card quotes its source word for word, and each check question is
/// kept only if an independent pass reaches the same answer.
enum DiscoverBuilder {
    /// One field a day, in rotation, so learners wander outside their own expertise.
    static let fields = [
        "Linguistics", "Immunology", "Plate tectonics", "Game theory", "Cryptography", "Marine biology",
        "Thermodynamics", "Behavioral economics", "Epidemiology", "Number theory", "Materials science",
        "Cognitive psychology", "Climate science", "Archaeology", "Quantum mechanics", "Neuroscience",
        "Information theory", "Ecology", "Astrophysics", "Genetics", "Philosophy of science", "Oceanography",
        "Machine learning", "Organic chemistry", "Urban planning", "Music theory", "Statistics", "Volcanology",
        "Microbiology", "Cosmology", "Developmental biology", "Monetary economics", "Topology", "Pharmacology",
        "Paleontology", "Optics", "Anthropology", "Control theory", "Mycology", "Glaciology", "Logic",
        "Evolutionary biology", "Seismology", "Public health", "Fluid dynamics", "Botany", "Graph theory",
        "Ethology", "Atmospheric science", "Computational complexity", "Endocrinology", "Semiconductor physics",
    ]

    static func fieldOfTheDay(_ date: Date) -> String {
        let day = Calendar.current.dateComponents([.day], from: Date(timeIntervalSince1970: 0),
                                                  to: Calendar.current.startOfDay(for: date)).day ?? 0
        return fields[abs(day) % fields.count]
    }

    private static let eyebrows = [
        "field_primer": "Field of the day", "featured_article": "Wikipedia's featured article",
        "on_this_day": "On this day", "space": "NASA picture of the day", "worth_reading": "Worth reading",
    ]

    private static let cardSystem = """
        You write the daily "Discover" cards for Sharpy, a learning app. Readers want one genuinely interesting thing to learn, explained clearly and accurately.
        Use only what the given source text says. Do not add facts from memory, even well-known ones. No hype, no clickbait, no exclamation marks.
        """

    private static let checkSystem = """
        You check quiz questions before learners see them. Use only the evidence given for each question.
        Work out which choice the evidence supports without assuming the author was right. Set ok to false if the evidence does not settle it or more than one choice could be defended.
        """

    private static let questionProperties: [String: Any] = [
        "question": ["type": "string"],
        "choices": ["type": "array", "items": ["type": "string"]],
        "answer_index": ["type": "integer"],
        "explanation": ["type": "string"],
    ]

    private static var docCardsSchema: [String: Any] {
        [
            "type": "object", "additionalProperties": false, "required": ["cards"],
            "properties": [
                "cards": [
                    "type": "array",
                    "items": [
                        "type": "object", "additionalProperties": false,
                        "required": ["source", "title", "body", "why_it_matters", "quote", "question", "choices",
                                     "answer_index", "explanation"],
                        "properties": questionProperties.merging([
                            "source": ["type": "integer"], "title": ["type": "string"], "body": ["type": "string"],
                            "why_it_matters": ["type": "string"], "quote": ["type": "string"],
                        ]) { a, _ in a },
                    ],
                ],
            ],
        ]
    }

    private static var primerSchema: [String: Any] {
        [
            "type": "object", "additionalProperties": false,
            "required": ["title", "body", "bullets", "why_it_matters", "question", "choices", "answer_index", "explanation"],
            "properties": questionProperties.merging([
                "title": ["type": "string"], "body": ["type": "string"], "why_it_matters": ["type": "string"],
                "bullets": [
                    "type": "array",
                    "items": [
                        "type": "object", "additionalProperties": false, "required": ["text", "fact_id"],
                        "properties": ["text": ["type": "string"], "fact_id": ["type": "integer"]],
                    ],
                ],
            ]) { a, _ in a },
        ]
    }

    private static let checkSchema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["results"],
        "properties": [
            "results": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false, "required": ["question", "answer_index", "ok"],
                    "properties": ["question": ["type": "integer"], "answer_index": ["type": "integer"], "ok": ["type": "boolean"]],
                ],
            ],
        ],
    ]

    private struct DocCards: Decodable {
        struct Card: Decodable {
            let source: Int
            let title: String
            let body: String
            let whyItMatters: String
            let quote: String
            let question: String
            let choices: [String]
            let answerIndex: Int
            let explanation: String
        }
        let cards: [Card]
    }

    private struct Primer: Decodable {
        struct Bullet: Decodable {
            let text: String
            let factId: Int
        }
        let title: String
        let body: String
        let bullets: [Bullet]
        let whyItMatters: String
        let question: String
        let choices: [String]
        let answerIndex: Int
        let explanation: String
    }

    private struct Checks: Decodable {
        struct Result: Decodable {
            let question: Int
            let answerIndex: Int
            let ok: Bool
        }
        let results: [Result]
    }

    private static func check(_ question: String, _ choices: [String], _ answer: Int, _ explanation: String) -> CheckQuestion? {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, (2...4).contains(choices.count), choices.indices.contains(answer) else { return nil }
        return CheckQuestion(question: q, choices: choices, answerIndex: answer,
                             explanation: explanation.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: Today's cards

    static func feed(for date: Date, client: LLMClient, progress: @escaping @Sendable (String) -> Void) async throws -> DiscoverFeed {
        let field = fieldOfTheDay(date)
        progress("Gathering today's sources…")
        async let wiki = try? Feeds.wikipediaFeatured(on: date)
        async let apod = try? Feeds.nasaApod()
        async let quanta = try? Feeds.quantaLatest(limit: 3)
        async let primerFacts = try? facts(for: field, client: client)
        let featured = await wiki ?? []
        let space = await apod
        let stories = await quanta ?? []
        let docs = featured + (space.map { [$0] } ?? []) + stories
        let evidence = await primerFacts ?? []

        var cards: [DiscoverCard] = []
        var pending: [(card: Int, evidence: String)] = []

        if !docs.isEmpty {
            progress("Writing today's cards…")
            let sources = docs.enumerated()
                .map { "S\($0.offset + 1) [\($0.element.label)] \"\($0.element.title)\" (\($0.element.publisher))\n\($0.element.text)" }
                .joined(separator: "\n\n")
            let draft = try await client.json(DocCards.self, schemaName: "cards", system: cardSystem, user: """
                Sources (kind in brackets):
                \(sources)

                Write one card for each kind present: featured_article, the single most interesting on_this_day event, space, and the single best worth_reading story.
                - source: the S number the card is based on (just the number).
                - title: up to 8 words.
                - body: 50–80 words that teach something specific, in plain language.
                - why_it_matters: one sentence.
                - quote: an exact, word-for-word excerpt of 8–30 words from that source's text, copied verbatim.
                - A check question about the card with 3 or 4 choices, answerable from the source; explanation in one sentence.
                """, schema: docCardsSchema, effort: .medium)
            for c in draft.cards {
                guard c.source >= 1, c.source <= docs.count else { continue }
                let doc = docs[c.source - 1]
                // The quote must really be in the source; otherwise the card is suspect.
                let quote = trim(c.quote)
                guard !quote.isEmpty, Research.normalize(doc.text).contains(Research.normalize(quote)),
                      !cards.contains(where: { $0.kind == doc.label }) else { continue }
                cards.append(DiscoverCard(
                    id: UUID().uuidString, kind: doc.label, eyebrow: eyebrows[doc.label] ?? "", title: trim(c.title),
                    body: trim(c.body), bullets: [], whyItMatters: trim(c.whyItMatters), imageURL: doc.imageURL,
                    sources: [ItemSource(url: doc.url, title: doc.title, publisher: doc.publisher, quote: quote)],
                    check: check(c.question, c.choices, c.answerIndex, c.explanation)))
                if cards[cards.count - 1].check != nil { pending.append((card: cards.count - 1, evidence: doc.text)) }
            }
        }

        if evidence.count >= 3 {
            progress("Writing the field of the day…")
            let block = Research.block(evidence)
            let p = try await client.json(Primer.self, schemaName: "primer", system: cardSystem, user: """
                Field of the day: \(field)

                Evidence:
                \(block)

                Write a primer card for a curious newcomer:
                - title: a hook of up to 8 words (not just the field's name).
                - body: 2–3 sentences on what the field studies and why it is interesting.
                - bullets: exactly 3 facts from the evidence, each one sentence, with the fact_id it comes from.
                - why_it_matters: one sentence.
                - A check question with 3 or 4 choices, answerable from the evidence; explanation in one sentence.
                """, schema: primerSchema, effort: .medium)
            var sources: [ItemSource] = []
            for bullet in p.bullets {
                for source in evidence.first(where: { $0.id == bullet.factId })?.sources ?? []
                where !sources.contains(where: { $0.url == source.url }) {
                    sources.append(source)
                }
            }
            if !sources.isEmpty {
                cards.insert(DiscoverCard(
                    id: UUID().uuidString, kind: "field_primer", eyebrow: "Field of the day · \(field)", title: trim(p.title),
                    body: trim(p.body), bullets: p.bullets.prefix(3).map { trim($0.text) }, whyItMatters: trim(p.whyItMatters),
                    imageURL: nil, sources: Array(sources.prefix(4)),
                    check: check(p.question, p.choices, p.answerIndex, p.explanation)), at: 0)
                pending = pending.map { (card: $0.card + 1, evidence: $0.evidence) }
                if cards[0].check != nil { pending.append((card: 0, evidence: block)) }
            }
        }

        // Keep a check question only if an independent pass reaches the same answer.
        if !pending.isEmpty {
            progress("Double-checking the questions…")
            var questions: [String] = []
            for (i, entry) in pending.enumerated() {
                guard let q = cards[entry.card].check else { continue }
                let choices = q.choices.enumerated().map { "   \($0.offset). \($0.element)" }.joined(separator: "\n")
                questions.append("Question \(i)\nEvidence:\n\(entry.evidence)\n\n\(q.question)\n\(choices)")
            }
            let verdict = try await client.json(Checks.self, schemaName: "checks", system: checkSystem,
                                                user: questions.joined(separator: "\n\n---\n\n"), schema: checkSchema,
                                                effort: .medium)
            for (i, entry) in pending.enumerated() {
                let result = verdict.results.first { $0.question == i }
                if result?.ok != true || result?.answerIndex != cards[entry.card].check?.answerIndex {
                    cards[entry.card].check = nil
                }
            }
        }

        guard !cards.isEmpty else { throw GenerationError(message: "Couldn't put today's cards together. Pull to try again.") }
        return DiscoverFeed(date: DayKey.string(for: date), cards: cards)
    }

    /// Sourced facts for the field primer: Claude's web search, or a Wikipedia article for other models.
    private static func facts(for field: String, client: LLMClient) async throws -> [Evidence] {
        let ask = """
            Field: \(field)
            Find 8 facts that give a curious newcomer a real foothold in this field: the central question it asks, one key idea or method, a landmark discovery (who and when), how it touches everyday life, and one thing that surprises most people.
            """
        if client.config.nativeWebSearch { return try await Research.web(ask, maxSearches: 4, client: client) }
        guard let title = try await Feeds.wikipediaSearch(field, limit: 1).first,
              let article = try await Feeds.wikipediaArticle(title) else { return [] }
        return try await Research.read([article.excerpt(from: 0, length: 9000)], ask: ask, client: client)
    }

    // MARK: New papers

    private struct Picks: Decodable {
        struct Pick: Decodable {
            let paper: Int
            let headline: String
            let summary: String
            let whyItMatters: String
            let quote: String
        }
        let picks: [Pick]
    }

    private static let picksSchema: [String: Any] = [
        "type": "object", "additionalProperties": false, "required": ["picks"],
        "properties": [
            "picks": [
                "type": "array",
                "items": [
                    "type": "object", "additionalProperties": false,
                    "required": ["paper", "headline", "summary", "why_it_matters", "quote"],
                    "properties": [
                        "paper": ["type": "integer"], "headline": ["type": "string"], "summary": ["type": "string"],
                        "why_it_matters": ["type": "string"], "quote": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]

    /// Up to three new papers in a topic, summarized strictly from their abstracts.
    static func updates(topic: String, client: LLMClient) async throws -> [FieldUpdate] {
        async let journals = try? Feeds.crossrefRecent(topic: topic)
        async let preprints = try? Feeds.arxivRecent(topic: topic)
        let papers = (await journals ?? []) + (await preprints ?? [])
        guard !papers.isEmpty else { return [] }

        let list = papers.enumerated().map { entry -> String in
            let p = entry.element
            return "P\(entry.offset + 1). \"\(p.title)\" — \(p.venue), \(p.date)\(p.peerReviewed ? "" : " (preprint, not peer reviewed)")\nAbstract: \(p.abstract)"
        }
        let out = try await client.json(Picks.self, schemaName: "picks", system: """
            You brief busy experts on new research in their field for Sharpy, a learning app.
            Summarize only what each abstract says, in plain language. State findings with the same certainty the authors use; never overstate. No hype words such as "breakthrough" or "revolutionary".
            """, user: """
            Field: \(topic)

            Recent papers:
            \(list.joined(separator: "\n\n"))

            Pick up to 3 papers that are clearly about \(topic) and most worth an expert's attention. Prefer peer-reviewed work in established journals, and skip any venue you don't recognize as reputable. Pick none if nothing fits.
            - paper: the P number (just the number).
            - headline: up to 12 words, plain and accurate.
            - summary: 40–60 words on what they did and found, from the abstract only.
            - why_it_matters: one cautious sentence.
            - quote: an exact, word-for-word excerpt of 10–30 words from the abstract.
            """, schema: picksSchema, effort: .medium)

        var updates: [FieldUpdate] = []
        for pick in out.picks {
            guard pick.paper >= 1, pick.paper <= papers.count else { continue }
            let p = papers[pick.paper - 1]
            guard !updates.contains(where: { $0.url == p.url }),
                  Research.normalize(p.abstract).contains(Research.normalize(pick.quote)) else { continue }
            updates.append(FieldUpdate(id: UUID().uuidString, topic: topic, headline: trim(pick.headline),
                                       summary: trim(pick.summary), whyItMatters: trim(pick.whyItMatters),
                                       quote: trim(pick.quote), url: p.url, venue: p.venue,
                                       peerReviewed: p.peerReviewed, date: p.date, authors: p.authors))
        }
        return Array(updates.prefix(3))
    }
}

/// Today's Discover feed and paper briefings, kept on disk so the tab opens
/// instantly (and offline) and each is paid for once a day.
enum DiscoverCache {
    private static var folder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    static func load() -> DiscoverFeed? {
        guard !Launch.isDemo, let data = try? Data(contentsOf: folder.appendingPathComponent("discover.json")) else { return nil }
        return try? JSONDecoder().decode(DiscoverFeed.self, from: data)
    }

    static func save(_ feed: DiscoverFeed) {
        guard !Launch.isDemo, let data = try? JSONEncoder().encode(feed) else { return }
        try? data.write(to: folder.appendingPathComponent("discover.json"), options: .atomic)
    }

    /// Paper briefings by day, then topic key.
    private static func loadUpdates() -> [String: [String: [FieldUpdate]]] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("updates.json")) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: [FieldUpdate]]].self, from: data)) ?? [:]
    }

    static func updates(day: String, topic: String) -> [FieldUpdate]? {
        loadUpdates()[day]?[QuestionBank.key(topic)]
    }

    static func saveUpdates(_ items: [FieldUpdate], day: String, topic: String) {
        guard !Launch.isDemo else { return }
        // Only today's briefings are worth keeping.
        var all = loadUpdates().filter { $0.key == day }
        all[day, default: [:]][QuestionBank.key(topic)] = items
        if let data = try? JSONEncoder().encode(all) {
            try? data.write(to: folder.appendingPathComponent("updates.json"), options: .atomic)
        }
    }
}
