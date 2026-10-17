import Foundation

enum BoxError: Error, LocalizedError, Equatable {
    case invalidURL
    case insecureURL
    case missingDeviceId
    case notConfigured
    case http(Int, String?)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Box URL is not a valid URL"
        case .insecureURL: return "Box URL must be https (http allowed only for localhost)"
        case .missingDeviceId: return "Device id is required"
        case .notConfigured: return "Box URL, token and device id are not all set"
        case .http(let code, let body):
            if code == 404 { return "HTTP 404 — box reachable but endpoint not deployed yet" }
            if code == 401 || code == 403 { return "HTTP \(code) — token rejected" }
            return "HTTP \(code)" + (body.map { ": \($0)" } ?? "")
        case .transport(let m): return "Network: \(m)"
        }
    }
}

/// The only place the app talks to the network. Every request goes to the configured box URL.
struct BoxClient: Sendable {
    let config: BridgeConfig
    var session: URLSession = .shared

    static func validatedBaseURL(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              let host = url.host()?.lowercased(), !host.isEmpty else { throw BoxError.invalidURL }
        let isLocal = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard scheme == "https" || (scheme == "http" && isLocal) else { throw BoxError.insecureURL }
        return url
    }

    // MARK: Endpoints (contract: docs/API.md)

    func ping() async throws -> JSONValue {
        let data = try await send(request("bridge/ping", query: [.init(name: "device", value: config.deviceId)], method: "GET", bearer: true))
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }

    /// `wait`: long poll — the box holds the request until a job exists or `wait` seconds pass.
    /// nil = the instant v0.1 behaviour (push, BG refresh, the Poll-now button).
    func fetchJobs(wait: Int? = nil) async throws -> JobsResponse {
        let data = try await send(jobsRequest(wait: wait))
        return try JSONDecoder().decode(JobsResponse.self, from: data)
    }

    func jobsRequest(wait: Int?) -> URLRequest {
        var query: [URLQueryItem] = [.init(name: "device", value: config.deviceId)]
        if let wait { query.append(.init(name: "wait", value: String(wait))) }
        var r = request("bridge/jobs", query: query, method: "GET", bearer: true)
        // The box answers by `wait`; leave room for the network on top.
        if let wait { r.timeoutInterval = max(r.timeoutInterval, TimeInterval(wait) + 15) }
        return r
    }

    func postResults(_ results: [JobResult]) async throws {
        let body = try JSONEncoder().encode(ResultsRequest(device: config.deviceId, results: results))
        _ = try await send(request("bridge/results", method: "POST", bearer: true, body: body))
    }

    func registerDevice(_ registration: DeviceRegistration) async throws {
        let body = try JSONEncoder().encode(registration)
        _ = try await send(request("bridge/devices", method: "POST", bearer: true, body: body))
    }

    /// Existing Health-Auto-Export-compatible endpoint. Note: raw token, no `Bearer` prefix.
    func ingest(_ body: Data) async throws {
        _ = try await send(request("hk/ingest", method: "POST", bearer: false, body: body))
    }

    // MARK: Plumbing

    func request(_ path: String, query: [URLQueryItem] = [], method: String, bearer: Bool, body: Data? = nil) -> URLRequest {
        var components = URLComponents(url: config.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var r = URLRequest(url: components.url!, timeoutInterval: 30)
        r.httpMethod = method
        r.setValue(bearer ? "Bearer \(config.token)" : config.token, forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.setValue("Bridge/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        r.setValue(config.deviceId, forHTTPHeaderField: "X-Bridge-Device")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw BoxError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw BoxError.transport("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw BoxError.http(http.statusCode, String(data: data.prefix(200), encoding: .utf8))
        }
        return data
    }
}
