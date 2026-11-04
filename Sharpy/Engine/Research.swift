import Foundation

/// A sourced fact the writers may use: numbered, with the pages that back it.
struct Evidence {
    let id: Int
    let text: String
    let sources: [ItemSource]
}

/// Gathering facts that carry a real, checkable source. Two routes:
/// - Claude (Anthropic API): web search limited to trusted sites; every quote is the
///   citation the API returns, so it comes from the page, not the model's memory.
/// - Any other model: Sharpy fetches Wikipedia articles itself, the model picks facts
///   and quotes them, and a fact survives only if its quote really is in the article.
enum Research {
    static let webSystem = """
        You are the research desk for Sharpy, an app people use for a few minutes a day to keep their thinking sharp in their own field.
        Gather precise, checkable facts from reliable sources: reference works, peer-reviewed journals, government and university sites, and official documentation.
        Write only what the pages you find state directly, and cite them. Prefer specific details (numbers, dates, mechanisms, definitions, cause and effect, who found what) over generalities.
        Leave out contested claims, fast-moving news, and anything you cannot source.
        """

    static let readerSystem = """
        You are the research desk for Sharpy, a learning app. You are given source texts.
        Pick precise, checkable facts that the texts state directly. Prefer specific details (numbers, dates, mechanisms, definitions, cause and effect, who found what) over generalities.
        Never add anything from memory. Every quote must be copied exactly, word for word, from the source it names.
        """

    /// Claude's web research: one "FACT:" line per finding.
    static func web(_ ask: String, maxSearches: Int, client: LLMClient) async throws -> [Evidence] {
        let blocks = try await client.webResearch(
            system: webSystem,
            user: ask + "\nOutput one fact per line, each line starting with \"FACT:\". One or two sentences per fact. No other text.",
            maxSearches: maxSearches)
        return facts(fromCitedBlocks: blocks)
    }

    /// Splits Claude's "FACT:" lines out of the reply and attaches the citations of
    /// every text block overlapping each fact. Facts with no trusted citation are dropped.
    static func facts(fromCitedBlocks blocks: [[String: Any]]) -> [Evidence] {
        let full = NSMutableString()
        var spans: [(start: Int, end: Int, sources: [ItemSource])] = []
        for block in blocks where (block["type"] as? String) == "text" {
            let start = full.length
            full.append(block["text"] as? String ?? "")
            var sources: [ItemSource] = []
            for c in block["citations"] as? [[String: Any]] ?? [] {
                guard (c["type"] as? String) == "web_search_result_location", let url = c["url"] as? String,
                      TrustedSources.isTrusted(url) else { continue }
                sources.append(ItemSource(
                    url: url,
                    title: c["title"] as? String ?? TrustedSources.publisher(for: url),
                    publisher: TrustedSources.publisher(for: url),
                    quote: (c["cited_text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            spans.append((start, full.length, sources))
        }

        let text = full as String
        guard let factRE = try? NSRegularExpression(pattern: "FACT:\\s*([\\s\\S]*?)(?=\\n\\s*FACT:|$)"),
              let blankRE = try? NSRegularExpression(pattern: "\\n\\s*\\n") else { return [] }
        var facts: [Evidence] = []
        for m in factRE.matches(in: text, range: NSRange(location: 0, length: full.length)) {
            var para = full.substring(with: m.range) as NSString
            // A fact ends at the next FACT line or at a blank line (ignoring closing remarks).
            if let blank = blankRE.firstMatch(in: para as String, range: NSRange(location: 0, length: para.length)) {
                para = para.substring(to: blank.range.location) as NSString
            }
            let start = m.range.location
            let end = start + para.length
            var seen = Set<String>()
            var sources: [ItemSource] = []
            for span in spans where span.start < end && span.end > start {
                for source in span.sources where seen.insert(source.url + "\n" + source.quote).inserted {
                    sources.append(source)
                }
            }
            let body = (para as String).replacing(pattern: "^FACT:\\s*", with: "")
                .replacing(pattern: "\\s+", with: " ").trimmingCharacters(in: .whitespaces)
            if !body.isEmpty && !sources.isEmpty { facts.append(Evidence(id: facts.count + 1, text: body, sources: sources)) }
        }
        return facts
    }

    private struct ReaderFacts: Decodable {
        struct Fact: Decodable {
            let text: String
            let source: Int
            let quote: String
        }
        let facts: [Fact]
    }

    private static let readerSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["facts"],
        "properties": [
            "facts": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["text", "source", "quote"],
                    "properties": [
                        "text": ["type": "string"],
                        "source": ["type": "integer"],
                        "quote": ["type": "string"],
                    ],
                ],
            ],
        ],
    ]

    /// Facts read from `docs` by any model, kept only when the quote is verbatim in its source.
    static func read(_ docs: [SourceDoc], ask: String, client: LLMClient) async throws -> [Evidence] {
        guard !docs.isEmpty else { return [] }
        let sources = docs.enumerated()
            .map { "S\($0.offset + 1): \"\($0.element.title)\" (\($0.element.publisher))\n\($0.element.text)" }
            .joined(separator: "\n\n")
        let reply = try await client.json(ReaderFacts.self, schemaName: "facts", system: readerSystem, user: """
            \(ask)

            Sources:
            \(sources)

            For each fact give:
            - text: the fact in one or two plain sentences.
            - source: the S number it comes from (just the number).
            - quote: an exact excerpt of 10–40 words copied word for word from that source that states the fact.
            """, schema: readerSchema, effort: .medium)
        var facts: [Evidence] = []
        for fact in reply.facts {
            guard fact.source >= 1, fact.source <= docs.count else { continue }
            let doc = docs[fact.source - 1]
            let quote = fact.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            // The quote must really be in the source; otherwise the fact is suspect.
            guard quote.count >= 20, normalize(doc.text).contains(normalize(quote)) else { continue }
            facts.append(Evidence(id: facts.count + 1, text: fact.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  sources: [ItemSource(url: doc.url, title: doc.title, publisher: doc.publisher, quote: quote)]))
        }
        return facts
    }

    /// Renders evidence as a numbered list for the writing and checking prompts.
    static func block(_ facts: [Evidence]) -> String {
        facts.map { fact in
            let quotes = fact.sources.prefix(2)
                .map { "   source: \($0.publisher) — \"\($0.title)\"\n   excerpt: \"\($0.quote)\"" }
                .joined(separator: "\n")
            return "[\(fact.id)] \(fact.text)\n\(quotes)"
        }
        .joined(separator: "\n\n")
    }

    /// Collapses whitespace, case and curly punctuation so a quote can be matched against its source.
    static func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "‘", with: "'").replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacing(pattern: "\\s+", with: " ")
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
    }
}
