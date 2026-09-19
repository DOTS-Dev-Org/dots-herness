import Foundation

struct PagesDeployClient: Sendable {
    let accountId: String
    let apiToken: String

    /// Direct upload is available for an already-built static directory.
    /// Build steps stay on the desktop or GitHub Actions.
    func deploy(project: String, files: [String: Data]) async throws -> URL {
        guard let url = URL(string: "https://api.cloudflare.com/client/v4/accounts/\(accountId)/pages/projects/\(project)/deployments") else { throw PagesError.invalidURL }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        let boundary = "HerNess-\(UUID().uuidString)"; request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipart(files: files, boundary: boundary)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let subdomain = object["result"] as? [String: Any], let value = subdomain["url"] as? String, let url = URL(string: value) else { throw PagesError.server(String(data: data, encoding: .utf8) ?? "Cloudflare Pages deploy failed") }
        return url
    }

    private func multipart(files: [String: Data], boundary: String) -> Data { var data = Data(); files.forEach { path, content in data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files[\(path)]\"; filename=\"\(path)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)); data.append(content); data.append(Data("\r\n".utf8)) }; data.append(Data("--\(boundary)--\r\n".utf8)); return data }
}

enum PagesError: LocalizedError { case invalidURL, server(String); var errorDescription: String? { switch self { case .invalidURL: return "Cloudflare Pages URL is invalid."; case .server(let message): return message } } }
