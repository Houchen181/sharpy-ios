import Foundation

enum APIError: LocalizedError {
    case server(String)
    case status(Int)
    case endedEarly

    var errorDescription: String? {
        switch self {
        case .server(let message): message
        case .status(let code): "Sharpy's server answered with an error (\(code)). Please try again."
        case .endedEarly: "The connection ended early. Please try again."
        }
    }
}

/// Talks to the Sharpy Worker. Generation endpoints stream newline-delimited JSON:
/// progress lines while Claude researches and writes, then the result.
/// Main-actor bound so progress callbacks can update views directly.
@MainActor
struct APIClient {
    let baseURL: URL
    let installID: String
    private let session: URLSession

    init(installID: String) {
        let raw = Bundle.main.object(forInfoDictionaryKey: "SharpyAPIBaseURL") as? String ?? ""
        baseURL = URL(string: raw) ?? URL(string: "https://sharpy-api.charges-ios.workers.dev")!
        self.installID = installID
        let config = URLSessionConfiguration.default
        // The server pings every 15 s while it works, so a long idle gap means trouble.
        config.timeoutIntervalForRequest = 90
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
    }

    private struct LineHead: Decodable {
        let type: String
        let message: String?
    }

    private struct SessionLine: Decodable {
        let items: [QuizItem]
    }

    private struct UpdatesLine: Decodable {
        let topic: String
        let items: [FieldUpdate]
        let note: String?
    }

    private struct ErrorBody: Decodable {
        let error: String
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(installID, forHTTPHeaderField: "X-Sharpy-Install")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private func check(_ response: URLResponse, body: () async throws -> Data) async throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.endedEarly }
        guard http.statusCode == 200 else {
            if let data = try? await body(), let err = try? JSONDecoder().decode(ErrorBody.self, from: data) {
                throw APIError.server(err.error)
            }
            throw APIError.status(http.statusCode)
        }
    }

    /// Streams lines to `handle` until the server closes the response.
    private func stream(_ request: URLRequest, handle: (String, Data) throws -> Void) async throws {
        let (bytes, response) = try await session.bytes(for: request)
        try await check(response) {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            return data
        }
        let decoder = JSONDecoder()
        for try await line in bytes.lines {
            let data = Data(line.utf8)
            guard let head = try? decoder.decode(LineHead.self, from: data) else { continue }
            if head.type == "error" { throw APIError.server(head.message ?? "Something went wrong.") }
            try handle(head.type, data)
        }
    }

    /// New questions for a practice session. `progress` receives status lines such as
    /// "Searching trusted sources…" while the server generates missing questions.
    func sessionItems(
        topics: [String],
        level: Level,
        count: Int,
        seen: [String],
        progress: @escaping (String) -> Void
    ) async throws -> [QuizItem] {
        if Launch.isDemo { return DemoData.items }
        let request = try request("v1/session", method: "POST", body: [
            "topics": topics, "level": level.rawValue, "count": count, "seen": seen,
        ])
        var items: [QuizItem]?
        try await stream(request) { type, data in
            switch type {
            case "progress":
                if let message = try JSONDecoder().decode(LineHead.self, from: data).message { progress(message) }
            case "session":
                items = try JSONDecoder().decode(SessionLine.self, from: data).items
            default:
                break
            }
        }
        guard let items else { throw APIError.endedEarly }
        return items
    }

    func discover(date: String) async throws -> DiscoverFeed {
        if Launch.isDemo { return DemoData.feed }
        var request = try request("v1/discover")
        request.url = URL(string: request.url!.absoluteString + "?date=\(date)")
        let (data, response) = try await session.data(for: request)
        try await check(response) { data }
        return try JSONDecoder().decode(DiscoverFeed.self, from: data)
    }

    /// Calls `onTopic` once per topic as each briefing arrives.
    func fieldUpdates(
        topics: [String],
        progress: @escaping (String) -> Void,
        onTopic: @escaping (String, [FieldUpdate], String?) -> Void
    ) async throws {
        if Launch.isDemo {
            for topic in topics { onTopic(topic, DemoData.updates.filter { $0.topic == topic }, nil) }
            return
        }
        let request = try request("v1/updates", method: "POST", body: ["topics": topics])
        try await stream(request) { type, data in
            switch type {
            case "progress":
                if let message = try JSONDecoder().decode(LineHead.self, from: data).message { progress(message) }
            case "updates":
                let line = try JSONDecoder().decode(UpdatesLine.self, from: data)
                onTopic(line.topic, line.items, line.note)
            default:
                break
            }
        }
    }

    /// Two reports from different people retire an item for everyone.
    func report(itemID: String, reason: String) async {
        if Launch.isDemo { return }
        guard let request = try? request("v1/report", method: "POST", body: ["itemId": itemID, "reason": reason]) else { return }
        _ = try? await session.data(for: request)
    }
}
