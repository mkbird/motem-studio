import Foundation

/// Authenticated HTTP client for `deskrobot-backend`. All requests get
/// `Authorization: Bearer <token>` + `Accept-Language` automatically.
/// `AuthManager.shared` is the source of truth for both pieces.
@MainActor
final class APIClient {

    static let shared = APIClient()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum APIError: Error, LocalizedError {
        case httpStatus(Int, String)
        case decode(Error)
        case transport(Error)
        case missingToken

        var errorDescription: String? {
            switch self {
            case .httpStatus(let code, let message):
                return "HTTP \(code): \(message)"
            case .decode(let err):
                return "Decode failed: \(err.localizedDescription)"
            case .transport(let err):
                return "Network error: \(err.localizedDescription)"
            case .missingToken:
                return "Not logged in"
            }
        }
    }

    // MARK: - Requests

    /// JSON GET with automatic decode. Authentication required.
    func get<T: Decodable>(_ path: String, as type: T.Type = T.self) async throws -> T {
        let request = try await buildRequest(path: path, method: "GET", body: nil)
        return try await perform(request)
    }

    /// JSON GET that returns the raw `Data` (callers may decode out of
    /// band — used by tar.gz / zip downloads).
    func getData(_ path: String) async throws -> Data {
        let request = try await buildRequest(path: path, method: "GET", body: nil)
        return try await performRaw(request).data
    }

    /// Multipart upload with a single binary `file` field. Returns a
    /// JSON-decoded response.
    func uploadFile<T: Decodable>(
        _ path: String,
        fileData: Data,
        fileName: String,
        mimeType: String = "application/octet-stream",
        as type: T.Type = T.self
    ) async throws -> T {
        let boundary = "MotemStudio-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n".utf8Data)
        body.append("Content-Type: \(mimeType)\r\n\r\n".utf8Data)
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n".utf8Data)

        var request = try await buildRequest(path: path, method: "POST", body: nil)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await perform(request)
    }

    /// JSON POST with automatic encode + decode.
    func postJSON<Req: Encodable, Resp: Decodable>(
        _ path: String,
        body: Req,
        as type: Resp.Type = Resp.self,
        authenticated: Bool = true
    ) async throws -> Resp {
        let encoded = try JSONEncoder().encode(body)
        var request = try await buildRequest(
            path: path,
            method: "POST",
            body: encoded,
            authenticated: authenticated
        )
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try await perform(request)
    }

    // MARK: - Plumbing

    private func buildRequest(
        path: String,
        method: String,
        body: Data?,
        authenticated: Bool = true
    ) async throws -> URLRequest {
        let url = BackendConfig.baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        if let body { request.httpBody = body }

        request.setValue(Locale.current.identifier, forHTTPHeaderField: "Accept-Language")

        if authenticated {
            let token = AuthManager.shared.accessToken
            guard !token.isEmpty else { throw APIError.missingToken }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, _) = try await performRaw(request)
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    private func performRaw(_ request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw APIError.transport(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.httpStatus(0, "no HTTP response")
        }
        if !(200..<300).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 {
                AuthManager.shared.handleUnauthorized()
            }
            throw APIError.httpStatus(http.statusCode, message)
        }
        return (data, http)
    }
}

private extension String {
    var utf8Data: Data { data(using: .utf8) ?? Data() }
}
