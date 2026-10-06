import Foundation

/// What the "add this server" QR in the web UI (Profile → Settings) carries:
///
///     musik://connect?url=<server base url>&token=<API token>
///
/// The same link opens the app from the system Camera. A QR with a plain
/// http(s) address is accepted too and only fills the address field.
struct ConnectLink: Equatable {
    var baseURL: String
    var token: String?

    init?(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let comps = URLComponents(string: text), let scheme = comps.scheme?.lowercased() else {
            return nil
        }
        switch scheme {
        case "musik":
            guard comps.host?.lowercased() == "connect",
                  let url = Self.query(comps, "url"), Self.isServerURL(url) else { return nil }
            baseURL = Settings.normalize(url)
            token = Self.query(comps, "token")
        case "http", "https":
            guard Self.isServerURL(text) else { return nil }
            var base = comps
            base.query = nil
            base.fragment = nil
            baseURL = Settings.normalize(base.string ?? text)
            token = nil
        default:
            return nil
        }
    }

    init?(url: URL) { self.init(url.absoluteString) }

    private static func isServerURL(_ raw: String) -> Bool {
        guard let c = URLComponents(string: raw), let s = c.scheme?.lowercased() else { return false }
        return (s == "http" || s == "https") && !(c.host ?? "").isEmpty
    }

    /// The server builds the link with Go's url.Values.Encode: a space is "+",
    /// a literal "+" is "%2B". URLComponents.queryItems would keep "+" as is.
    private static func query(_ comps: URLComponents, _ name: String) -> String? {
        for item in comps.percentEncodedQueryItems ?? [] where item.name == name {
            let value = item.value?
                .replacingOccurrences(of: "+", with: " ")
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (value?.isEmpty ?? true) ? nil : value
        }
        return nil
    }
}
