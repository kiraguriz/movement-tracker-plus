import Foundation

public enum ServiceEndpoint {
    /// Release configuration contains only the public proxy URL. Credentials belong in Worker secrets.
    /// Unexpanded build settings and URLs with embedded credentials/query tokens are rejected.
    public static func parse(_ value: String?, allowLocalHTTP: Bool = false) -> URL? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              !raw.contains("$("), let parts = URLComponents(string: raw),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let url = parts.url else { return nil }
        if parts.scheme == "https" { return url }
        if allowLocalHTTP, parts.scheme == "http", ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host) { return url }
        return nil
    }
}
