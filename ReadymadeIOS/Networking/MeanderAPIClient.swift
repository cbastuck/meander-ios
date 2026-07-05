import Foundation

enum APIError: LocalizedError {
    case invalidBaseURL(String)
    case invalidResponse
    case httpStatus(Int, String)
    case invalidJSONPayload

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let baseURL):
            return "Invalid base URL: \(baseURL)"
        case .invalidResponse:
            return "Server returned an invalid response."
        case .httpStatus(let code, let body):
            if body.isEmpty {
                return "Request failed with HTTP \(code)."
            }
            return "Request failed with HTTP \(code): \(body)"
        case .invalidJSONPayload:
            return "Payload must be valid JSON before saving."
        }
    }
}

final class MeanderAPIClient {
    private var baseURL: URL
    private let session: URLSession

    init(baseURLString: String, session: URLSession = .shared) throws {
        guard let url = URL(string: baseURLString) else {
            throw APIError.invalidBaseURL(baseURLString)
        }
        self.baseURL = url
        self.session = session
    }

    func updateBaseURL(_ baseURLString: String) throws {
        guard let url = URL(string: baseURLString) else {
            throw APIError.invalidBaseURL(baseURLString)
        }
        baseURL = url
    }

    func fetchBoards() async throws -> [String] {
        let data = try await send(path: "boards", method: "GET")
        return try JSONDecoder().decode([String].self, from: data)
    }

    func loadBoard(named name: String) async throws -> String {
        try await sendString(path: "boards/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)", method: "GET")
    }

    func saveBoard(_ draft: BoardDraft) async throws {
        guard let payloadData = draft.json.data(using: .utf8) else {
            throw APIError.invalidJSONPayload
        }
        _ = try JSONSerialization.jsonObject(with: payloadData)
        _ = try await send(path: "boards/\(draft.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? draft.name)", method: "POST", body: payloadData)
    }

    func deleteBoard(named name: String) async throws {
        _ = try await send(path: "boards/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name)", method: "DELETE")
    }

    func fetchRemotes() async throws -> [Remote] {
        let data = try await send(path: "remotes", method: "GET")
        return try JSONDecoder().decode([Remote].self, from: data)
    }

    private func sendString(path: String, method: String, body: Data? = nil) async throws -> String {
        let data = try await send(path: path, method: method, body: body)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func send(path: String, method: String, body: Data? = nil) async throws -> Data {
        let endpoint = baseURL.appending(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpStatus(http.statusCode, bodyText)
        }
        return data
    }
}
