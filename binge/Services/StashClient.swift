import Foundation

// Lightweight GraphQL client for talking to a Stash instance. One
// `gql<T>` method that takes a query + variables, decodes the
// response into a caller-supplied Decodable. Mirrors the shape of
// the web's `src/api/graphql.ts`.
//
// Same-origin auth doesn't exist on iOS — every request explicitly
// sets the `ApiKey` header. The user pastes their API key into
// Settings once (or signs in to fetch it); it's stored in the
// Keychain (see KeychainStore), never UserDefaults.

enum StashClientError: Error, LocalizedError {
    case notConfigured
    case badURL(String)
    case badHTTPStatus(Int)
    case graphqlErrors([String])
    case emptyResponse
    case decoding(any Error)
    case network(any Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Stash URL / API key not set."
        case .badURL(let s):
            return "Invalid URL: \(s)"
        case .badHTTPStatus(let code):
            return "HTTP \(code) from Stash."
        case .graphqlErrors(let msgs):
            return msgs.joined(separator: "; ")
        case .emptyResponse:
            return "Stash returned no data."
        case .decoding(let err):
            return "Couldn't decode response: \(err.localizedDescription)"
        case .network(let err):
            return "Network: \(err.localizedDescription)"
        }
    }
}

actor StashClient {
    private let baseURL: String
    private let apiKey: String

    /// One shared URLSession across every StashClient instance.
    /// Constructing a session-per-instance kills keep-alive reuse
    /// — every gql call would build a fresh TCP+TLS handshake.
    /// The session itself is thread-safe (Foundation guarantees
    /// it) so sharing across actors is fine. Lazy so initial app
    /// boot doesn't pay this cost until the first GraphQL call.
    private static let sharedSession: URLSession = {
        // Ephemeral config — no disk cache for GraphQL responses;
        // the app's own cache layer (StashDBCache etc.) decides
        // what's worth keeping. Timeouts match the previous
        // per-instance values.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        // With a delegate that refuses a redirect off the host we asked
        // for. This request carries the Stash API key in a custom
        // header, and Foundation copies those to the redirect target.
        // See CredentialSession.
        return URLSession(
            configuration: cfg,
            delegate: SameHostRedirectDelegate.shared,
            delegateQueue: nil
        )
    }()

    private var session: URLSession { Self.sharedSession }

    init(baseURL: String, apiKey: String) {
        // Strip trailing slashes so we can concatenate "/graphql"
        // predictably.
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\r\t"))
        self.apiKey = apiKey
    }

    func gql<T: Decodable>(
        _ query: String,
        variables: [String: Any] = [:]
    ) async throws -> T {
        guard let url = URL(string: "\(baseURL)/graphql") else {
            throw StashClientError.badURL(baseURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "ApiKey")
        }

        let body: [String: Any] = ["query": query, "variables": variables]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw StashClientError.network(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw StashClientError.badHTTPStatus(http.statusCode)
        }

        let wrapper: GQLResponse<T>
        do {
            wrapper = try JSONDecoder().decode(GQLResponse<T>.self, from: data)
        } catch {
            throw StashClientError.decoding(error)
        }
        if let errors = wrapper.errors, !errors.isEmpty {
            throw StashClientError.graphqlErrors(errors.map { $0.message })
        }
        guard let value = wrapper.data else {
            throw StashClientError.emptyResponse
        }
        return value
    }
}

// MARK: – Internals

private struct GQLResponse<T: Decodable>: Decodable {
    let data: T?
    let errors: [GQLError]?
}

private struct GQLError: Decodable {
    let message: String
}
