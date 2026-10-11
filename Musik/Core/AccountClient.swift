import Foundation

/// The account session behind "Настройки сервера": profiles, devices, invitations and
/// users. A device token cannot do any of that by design, so the app signs in the way
/// the browser does (`POST /api/auth/login` with name and password) and gets a session
/// cookie and a CSRF token, valid for 14 days.
///
/// Both live in the Keychain and are sent by hand on a URLSession without a cookie
/// store: the server refuses a request that carries a cookie and a Bearer token at
/// once, so the playback client (Bearer) and this one (cookie) never share cookies.
final class AccountClient: @unchecked Sendable {
    /// The session expired or was never opened: the screen asks for the password again.
    struct SignInRequired: LocalizedError {
        var errorDescription: String? { "Войди в аккаунт, чтобы управлять сервером" }
    }

    let settings: Settings
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    init(settings: Settings) {
        self.settings = settings
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    var isSignedIn: Bool { !(settings.accountSession ?? "").isEmpty }

    // MARK: Session

    func signIn(username: String, password: String) async throws {
        let (_, response) = try await request("POST", "/api/auth/login",
                                              body: ["username": username, "password": password],
                                              authed: false)
        guard let http = response as? HTTPURLResponse, let url = http.url else {
            throw APIError(status: 0, code: "network", message: "Нет ответа сервера")
        }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { out, field in
            if let k = field.key as? String, let v = field.value as? String { out[k] = v }
        }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
        let sessionCookie = cookies.first { $0.name == "musik_session" }?.value
        guard let sessionCookie, !sessionCookie.isEmpty else {
            throw APIError(status: 0, code: "no_session",
                           message: "Сервер не открыл сессию: вход по аккаунту работает только через HTTPS")
        }
        settings.accountSession = sessionCookie
        settings.accountCSRF = cookies.first { $0.name == "musik_csrf" }?.value
        settings.username = username
    }

    func signOut() async {
        if isSignedIn { _ = try? await request("POST", "/api/auth/logout") }
        clear()
    }

    func clear() {
        settings.accountSession = nil
        settings.accountCSRF = nil
    }

    /// `GET /api/auth/me` with no credentials: tells a server with accounts apart.
    func publicAuthMe() async throws -> AuthMe {
        let (data, _) = try await request("GET", "/api/auth/me", authed: false)
        return try decode(AuthMe.self, data)
    }

    // MARK: Account and profiles

    func me() async throws -> AccountMe {
        let me = try decode(AccountMe.self, try await call("GET", "/api/auth/me"))
        guard me.authenticated == true else {
            clear()
            throw SignInRequired()
        }
        return me
    }

    func changePassword(current: String, new: String) async throws {
        _ = try await call("POST", "/api/account/password", body: ["current": current, "new": new])
    }

    func createProfile(name: String) async throws -> ServerProfile {
        try decode(ServerProfile.self, try await call("POST", "/api/profiles", body: ["name": name]))
    }

    func renameProfile(_ id: String, name: String) async throws {
        _ = try await call("PATCH", "/api/profiles/\(id)", body: ["name": name])
    }

    func deleteProfile(_ id: String) async throws {
        _ = try await call("DELETE", "/api/profiles/\(id)")
    }

    // MARK: Devices

    func deviceTokens() async throws -> [DeviceTokenInfo] {
        try decode(DeviceTokenList.self, try await call("GET", "/api/account/device-tokens")).tokens
    }

    func createDeviceToken(name: String, profileId: String) async throws -> IssuedDeviceToken {
        try decode(IssuedDeviceToken.self, try await call("POST", "/api/account/device-tokens",
                                                          body: ["name": name, "profile_id": profileId]))
    }

    func revokeDeviceToken(_ id: String) async throws {
        _ = try await call("DELETE", "/api/account/device-tokens/\(id)")
    }

    func replaceDeviceToken(_ id: String) async throws -> IssuedDeviceToken {
        try decode(IssuedDeviceToken.self, try await call("POST", "/api/account/device-tokens/\(id)/replace"))
    }

    // MARK: Administration

    func invitations() async throws -> [InvitationInfo] {
        try decode([InvitationInfo].self, try await call("GET", "/api/admin/invitations"))
    }

    func createInvitation(email: String, hours: Int) async throws -> CreatedInvitation {
        var body: [String: Any] = ["ttl_hours": hours]
        if !email.isEmpty { body["email"] = email }
        return try decode(CreatedInvitation.self, try await call("POST", "/api/admin/invitations", body: body))
    }

    func revokeInvitation(_ id: String) async throws {
        _ = try await call("DELETE", "/api/admin/invitations/\(id)")
    }

    func users() async throws -> [AccountInfo] {
        try decode([AccountInfo].self, try await call("GET", "/api/admin/users"))
    }

    func updateUser(_ id: String, status: String, admin: Bool) async throws {
        _ = try await call("PATCH", "/api/admin/users/\(id)", body: ["status": status, "admin": admin])
    }

    // MARK: Transport

    /// An authed call: a 401 means the session is gone, and the screen asks to sign in.
    private func call(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard isSignedIn else { throw SignInRequired() }
        do {
            return try await request(method, path, body: body).0
        } catch let e as APIError where e.isUnauthorized {
            clear()
            throw SignInRequired()
        }
    }

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil,
                         authed: Bool = true) async throws -> (Data, URLResponse) {
        guard !settings.baseURL.isEmpty, let url = URL(string: settings.baseURL + path) else {
            throw APIError(status: 0, code: "bad_url", message: "Неверный адрес сервера")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if authed, let cookie = settings.accountSession {
            var header = "musik_session=\(cookie)"
            if let csrf = settings.accountCSRF {
                header += "; musik_csrf=\(csrf)"
                req.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
            }
            req.setValue(header, forHTTPHeaderField: "Cookie")
        }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch let e as URLError {
            throw APIError(status: 0, code: "network", message: e.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let env = try? decoder.decode(AccountErrorEnvelope.self, from: data)
            throw APIError(status: status, code: env?.code,
                           message: env?.error ?? "Ошибка сервера (HTTP \(status))")
        }
        return (data, response)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError(status: 0, code: "decode", message: "Неожиданный ответ сервера")
        }
    }
}

private struct AccountErrorEnvelope: Decodable {
    let error: String?
    let code: String?
}

// MARK: - Models

struct AccountMe: Decodable {
    var ok: Bool
    var authenticated: Bool?
    var localAccount: Bool?
    var user: AccountUser?
    var activeProfile: ServerProfile?
    var profiles: [ServerProfile]?

    var isAdmin: Bool { user?.roles?.contains("admin") == true }
}

struct AccountUser: Decodable {
    var id: String
    var displayName: String?
    var roles: [String]?
}

struct ServerProfile: Decodable, Identifiable, Hashable {
    var id: String
    var name: String
    var isDefault: Bool?
}

struct DeviceTokenInfo: Decodable, Identifiable {
    var id: String
    var profileId: String?
    var profileName: String?
    var name: String
    var createdAt: String?
    var lastUsedAt: String?
    var expiresAt: String?
    var revokedAt: String?
}

private struct DeviceTokenList: Decodable {
    var tokens: [DeviceTokenInfo]
}

struct IssuedDeviceToken: Decodable {
    var device: DeviceTokenInfo
    var token: String
}

struct InvitationInfo: Decodable, Identifiable {
    var id: String
    var email: String?
    var createdAt: String?
    var expiresAt: String
    var consumedAt: String?
    var revokedAt: String?

    var isPending: Bool {
        consumedAt == nil && revokedAt == nil && (ServerDate.parse(expiresAt) ?? .distantPast) > Date()
    }

    var state: String {
        if consumedAt != nil { return "Использовано" }
        if revokedAt != nil { return "Отозвано" }
        return isPending ? "Ожидает входа" : "Истекло"
    }
}

struct CreatedInvitation: Decodable {
    var id: String
    var secret: String
    var url: String
}

struct AccountInfo: Decodable, Identifiable {
    var id: String
    var displayName: String
    var status: String
    var admin: Bool
    var profiles: Int
}

/// RFC 3339 timestamps from the server, shown in the phone's locale.
enum ServerDate {
    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: raw)
    }

    static func text(_ raw: String?) -> String {
        guard let date = parse(raw) else { return "—" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
