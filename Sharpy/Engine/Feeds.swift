import Foundation

/// Plain text from a public source that a model may summarize and quote.
struct SourceDoc {
    /// For Discover: which card kind the document feeds.
    var label = ""
    let title: String
    let url: String
    let publisher: String
    let text: String
    var imageURL: String?

    /// A window of about `length` characters starting near `offset`, cut at paragraph
    /// and sentence boundaries so quotes stay intact.
    func excerpt(from offset: Int, length: Int) -> SourceDoc {
        guard text.count > length else { return self }
        let chars = Array(text)
        var start = offset % max(1, chars.count - length)
        if start > 0, let para = chars[start...].firstIndex(of: "\n") { start = min(para + 1, chars.count - 1) }
        var end = min(chars.count, start + length)
        if end < chars.count, let stop = chars[start..<end].lastIndex(of: ".") { end = stop + 1 }
        return SourceDoc(label: label, title: title, url: url, publisher: publisher, text: String(chars[start..<end]),
                         imageURL: imageURL)
    }
}

struct Paper {
    let title: String
    let abstract: String
    let url: String
    let venue: String
    let peerReviewed: Bool
    let date: String
    let authors: String
}

/// Free public sources, fetched straight from the phone. Nothing here calls a model.
enum Feeds {
    static let userAgent = "SharpyApp/1.0 (+https://github.com/Houchen181/sharpy-ios)"

    private static func get(_ url: URL, accept: String = "application/json") async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LLMError.other("Couldn't reach \(url.host ?? "a source"). Check your connection.")
        }
        return data
    }

    private static func json(_ url: URL) async throws -> [String: Any] {
        let data = try await get(url)
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private static func text(_ url: URL) async throws -> String {
        let data = try await get(url, accept: "*/*")
        return String(decoding: data, as: UTF8.self)
    }

    private static func url(_ base: String, _ query: [String: String]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    private static func authorList(_ names: [String]) -> String {
        names.count > 3 ? names.prefix(3).joined(separator: ", ") + " et al." : names.joined(separator: ", ")
    }

    // MARK: Wikipedia

    /// Wikipedia's featured feed for a day: the featured article and "On this day" events.
    static func wikipediaFeatured(on date: Date) async throws -> [SourceDoc] {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let path = String(format: "%04d/%02d/%02d", c.year ?? 2026, c.month ?? 1, c.day ?? 1)
        let feed = try await json(URL(string: "https://en.wikipedia.org/api/rest_v1/feed/featured/\(path)")!)
        var docs: [SourceDoc] = []
        if let tfa = feed["tfa"] as? [String: Any], let extract = tfa["extract"] as? String, let page = pageURL(tfa) {
            let title = (tfa["titles"] as? [String: Any])?["normalized"] as? String ?? "Today's featured article"
            // The feed's extract is one sentence; the article's lead section has the substance.
            let intro = await wikipediaIntro(title)
            docs.append(SourceDoc(label: "featured_article", title: title, url: page, publisher: "Wikipedia",
                                  text: intro ?? extract, imageURL: thumbnail(tfa)))
        }
        for event in (feed["onthisday"] as? [[String: Any]] ?? []).prefix(6) {
            let pages = event["pages"] as? [[String: Any]] ?? []
            guard let page = pages.first(where: { $0["extract"] is String && pageURL($0) != nil }),
                  let year = event["year"].map({ "\($0)" }), let text = event["text"] as? String else { continue }
            let name = (page["titles"] as? [String: Any])?["normalized"] as? String ?? ""
            docs.append(SourceDoc(label: "on_this_day", title: "\(year): \(name)", url: pageURL(page)!, publisher: "Wikipedia",
                                  text: "On this day in \(year): \(text)\n\n\(page["extract"] as? String ?? "")",
                                  imageURL: thumbnail(page)))
        }
        return docs
    }

    private static func pageURL(_ page: [String: Any]) -> String? {
        ((page["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
    }

    private static func thumbnail(_ page: [String: Any]) -> String? {
        (page["thumbnail"] as? [String: Any])?["source"] as? String
    }

    static func wikipediaIntro(_ title: String) async -> String? {
        let u = url("https://en.wikipedia.org/w/api.php", [
            "action": "query", "prop": "extracts", "exintro": "1", "explaintext": "1", "redirects": "1",
            "format": "json", "formatversion": "2", "titles": title,
        ])
        guard let data = try? await json(u), let pages = (data["query"] as? [String: Any])?["pages"] as? [[String: Any]],
              let extract = (pages.first?["extract"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !extract.isEmpty else { return nil }
        return extract
    }

    /// Article titles matching a search, best first.
    static func wikipediaSearch(_ query: String, limit: Int = 12) async throws -> [String] {
        let data = try await json(url("https://en.wikipedia.org/w/api.php", [
            "action": "query", "list": "search", "srsearch": query, "srlimit": String(limit), "srnamespace": "0",
            "format": "json", "formatversion": "2",
        ]))
        let results = (data["query"] as? [String: Any])?["search"] as? [[String: Any]] ?? []
        return results.compactMap { $0["title"] as? String }
    }

    /// One article as plain text.
    static func wikipediaArticle(_ title: String) async throws -> SourceDoc? {
        let data = try await json(url("https://en.wikipedia.org/w/api.php", [
            "action": "query", "prop": "extracts|info", "inprop": "url", "explaintext": "1", "exsectionformat": "plain",
            "redirects": "1", "format": "json", "formatversion": "2", "titles": title,
        ]))
        guard let page = ((data["query"] as? [String: Any])?["pages"] as? [[String: Any]])?.first,
              let text = page["extract"] as? String, text.count > 400 else { return nil }
        let name = page["title"] as? String ?? title
        let link = page["fullurl"] as? String
            ?? "https://en.wikipedia.org/wiki/" + (name.replacingOccurrences(of: " ", with: "_")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")
        // Drop the reference-list tail, which isn't prose worth quoting.
        let body = text.components(separatedBy: "\nReferences\n").first ?? text
        return SourceDoc(title: name, url: link, publisher: "Wikipedia", text: body)
    }

    /// A few Wikipedia articles on a topic for a model to read. `variety` rotates
    /// through related articles and deeper into the main one, so each new question
    /// set covers new ground.
    static func wikipediaReading(about topic: String, variety: Int, articles: Int = 3, window: Int = 6000) async throws -> [SourceDoc] {
        let titles = try await wikipediaSearch(topic)
            .filter { !$0.hasPrefix("List of") && !$0.contains("(disambiguation)") }
        guard let main = titles.first else { return [] }
        var picks = [main]
        let related = Array(titles.dropFirst())
        if !related.isEmpty {
            for i in 0..<min(articles - 1, related.count) {
                let title = related[(variety * (articles - 1) + i) % related.count]
                if !picks.contains(title) { picks.append(title) }
            }
        }
        var docs: [SourceDoc] = []
        for (i, title) in picks.enumerated() {
            guard let article = try? await wikipediaArticle(title) else { continue }
            docs.append(article.excerpt(from: i == 0 ? variety * window / 2 : 0, length: window))
        }
        return docs
    }

    // MARK: Space, journalism, papers

    /// NASA's Astronomy Picture of the Day; the explanation is written by professional astronomers.
    static func nasaApod() async throws -> SourceDoc? {
        let apod = try await json(URL(string: "https://api.nasa.gov/planetary/apod?api_key=DEMO_KEY&thumbs=true")!)
        guard let explanation = apod["explanation"] as? String, let date = apod["date"] as? String else { return nil }
        let parts = date.split(separator: "-").map(String.init)
        guard parts.count == 3 else { return nil }
        let title = apod["title"] as? String ?? ""
        let media = apod["url"] as? String ?? ""
        // Since APOD moved to science.nasa.gov the API sometimes returns the site's
        // name and logo instead of the picture; keep only the (correct) explanation then.
        let broken = title == "NASA Science" || media.contains("nasa-logo")
        let image = (apod["media_type"] as? String) == "image" ? media : apod["thumbnail_url"] as? String
        let text = (explanation.components(separatedBy: "Tomorrow's picture:").first ?? explanation)
            .replacing(pattern: "\\s+", with: " ").trimmingCharacters(in: .whitespaces)
        return SourceDoc(label: "space", title: broken ? "Astronomy Picture of the Day" : title,
                         url: "https://apod.nasa.gov/apod/ap\(parts[0].suffix(2))\(parts[1])\(parts[2]).html",
                         publisher: "NASA APOD", text: text,
                         // Only show images NASA can share freely; credited photos stay a link.
                         imageURL: broken || apod["copyright"] != nil ? nil : image)
    }

    /// Latest Quanta Magazine stories (editorially independent, fact-checked science journalism).
    static func quantaLatest(limit: Int = 3) async throws -> [SourceDoc] {
        let xml = try await text(URL(string: "https://www.quantamagazine.org/feed/")!)
        var docs: [SourceDoc] = []
        for item in xml.captures("<item>([\\s\\S]*?)</item>") {
            let title = stripHtml(item.captures("<title>([\\s\\S]*?)</title>").first ?? "")
            let link = stripHtml(item.captures("<link>([\\s\\S]*?)</link>").first ?? "")
            let text = stripHtml(item.captures("<description>([\\s\\S]*?)</description>").first ?? "")
            if !title.isEmpty, !link.isEmpty, !text.isEmpty {
                docs.append(SourceDoc(label: "worth_reading", title: title, url: link, publisher: "Quanta Magazine", text: text))
            }
            if docs.count >= limit { break }
        }
        return docs
    }

    /// Newest arXiv preprints matching a topic (not peer reviewed; labelled as such).
    static func arxivRecent(topic: String, limit: Int = 8) async throws -> [Paper] {
        let query = "all:\"\(topic.replacingOccurrences(of: "\"", with: ""))\""
        let u = url("https://export.arxiv.org/api/query", [
            "search_query": query, "sortBy": "submittedDate", "sortOrder": "descending", "max_results": String(limit),
        ])
        let xml = try await text(u)
        return xml.captures("<entry>([\\s\\S]*?)</entry>").compactMap { entry in
            func tag(_ name: String) -> String { stripHtml(entry.captures("<\(name)[^>]*>([\\s\\S]*?)</\(name)>").first ?? "") }
            let paper = Paper(title: tag("title"), abstract: tag("summary"),
                              url: tag("id").replacingOccurrences(of: "http://", with: "https://"),
                              venue: "arXiv preprint", peerReviewed: false, date: String(tag("published").prefix(10)),
                              authors: authorList(entry.captures("<name>([\\s\\S]*?)</name>").map(stripHtml)))
            return paper.title.isEmpty || paper.abstract.isEmpty ? nil : paper
        }
    }

    /// Recent journal articles with abstracts from Crossref (publisher-registered DOIs), most relevant first.
    static func crossrefRecent(topic: String, limit: Int = 10) async throws -> [Paper] {
        let since = Calendar.current.date(byAdding: .day, value: -45, to: .now) ?? .now
        let c = Calendar.current.dateComponents([.year, .month, .day], from: since)
        let data = try await json(url("https://api.crossref.org/works", [
            "query": topic,
            "filter": String(format: "from-pub-date:%04d-%02d-%02d,type:journal-article,has-abstract:true",
                             c.year ?? 2026, c.month ?? 1, c.day ?? 1),
            "rows": String(limit),
            "select": "DOI,title,abstract,container-title,published,author",
        ]))
        let items = (data["message"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
        return items.compactMap { w in
            guard let doi = w["DOI"] as? String else { return nil }
            let title = stripHtml((w["title"] as? [String])?.first ?? "")
            let abstract = stripHtml(w["abstract"] as? String ?? "").replacing(pattern: "^(?i)abstract\\s*", with: "")
            let parts = ((w["published"] as? [String: Any])?["date-parts"] as? [[Any]])?.first ?? []
            let date = parts.enumerated()
                .map { part in part.offset == 0 ? "\(part.element)" : String(format: "%02d", LLMClient.int(part.element)) }
                .joined(separator: "-")
            let names = (w["author"] as? [[String: Any]] ?? []).map { a in
                [a["given"] as? String, a["family"] as? String].compactMap { $0 }.joined(separator: " ")
            }.filter { !$0.isEmpty }
            guard !title.isEmpty, abstract.count > 200 else { return nil }
            return Paper(title: title, abstract: abstract, url: "https://doi.org/\(doi)",
                         venue: stripHtml((w["container-title"] as? [String])?.first ?? "Journal article"),
                         peerReviewed: true, date: date, authors: authorList(names))
        }
    }

    static func stripHtml(_ s: String) -> String {
        var t = s.replacing(pattern: "<!\\[CDATA\\[([\\s\\S]*?)\\]\\]>", with: "$1")
            .replacing(pattern: "<[^>]+>", with: " ")
        // &amp; last, so an escaped entity such as &amp;#8217; isn't decoded twice.
        let entities = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#039;", "'"), ("&#39;", "'"), ("&apos;", "'"),
                        ("&#8217;", "’"), ("&#8216;", "‘"), ("&#8220;", "“"), ("&#8221;", "”"), ("&#8211;", "–"),
                        ("&#8212;", "—"), ("&nbsp;", " "), ("&amp;", "&")]
        for (entity, char) in entities { t = t.replacingOccurrences(of: entity, with: char) }
        return t.replacing(pattern: "\\s+", with: " ").trimmingCharacters(in: .whitespaces)
    }
}

extension String {
    func replacing(pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return self }
        return re.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }

    /// The first capture group of every match.
    func captures(_ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { m in
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: self) else { return nil }
            return String(self[r])
        }
    }
}
