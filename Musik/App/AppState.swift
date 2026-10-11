import Foundation
import SwiftUI
import UIKit

/// App-wide state: login gate, toasts and favorite sets shared by every screen.
@MainActor
final class AppState: ObservableObject {
    enum Phase { case checking, login, ready }

    @Published var phase: Phase = .checking
    @Published var toast: String?
    @Published var favoriteTracks: Set<Int> = []
    @Published var favoriteArtists: Set<String> = []
    @Published var favoriteAlbums: Set<String> = []
    /// Bumped when shelves should reload (favorites or mixes changed).
    @Published var homeRevision = 0
    /// A server link from a scanned QR or a musik:// URL, waiting for the login screen.
    @Published var pendingConnect: ConnectLink?

    let settings: Settings
    let api: APIClient
    /// Account session for "Настройки сервера" (profiles, devices, invitations, users).
    let account: AccountClient
    let player: PlayerController

    private var toastTask: Task<Void, Never>?

    init() {
        let settings = Settings.shared
        let api = APIClient(settings: settings)
        self.settings = settings
        self.api = api
        self.account = AccountClient(settings: settings)
        self.player = PlayerController(api: api, settings: settings)
        ImageLoader.shared.api = api
        player.app = self
        api.onUnauthorized = { [weak self] in self?.handleUnauthorized() }
    }

    // MARK: Boot & auth

    func bootstrap() async {
        guard !settings.baseURL.isEmpty else {
            phase = .login
            return
        }
        Task { await self.refreshServerMode() }
        do {
            let me = try await api.authMe()
            if me.ok || me.authEnabled == false {
                phase = .ready
                await refreshFavorites()
                await player.restore()
            } else {
                phase = .login
            }
        } catch {
            // Server unreachable: still show the login screen with the saved URL.
            phase = .login
            show(error)
        }
    }

    enum LoginMode: String, CaseIterable, Identifiable {
        case token = "API token"
        case password = "Пароль"
        case account = "Аккаунт"
        var id: String { rawValue }
    }

    /// The server has accounts: the shared password does not exist there.
    struct AccountsRequired: LocalizedError {
        var errorDescription: String? {
            "На этом сервере вход по аккаунту: имя и пароль или приглашение"
        }
    }

    func login(baseURL: String, mode: LoginMode, secret: String) async throws {
        settings.baseURL = baseURL
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .token:
            settings.token = secret
        case .password:
            settings.token = nil
            if try await api.authMe().multiUser == true { throw AccountsRequired() }
            try await api.login(password: secret)
        case .account:
            // Accounts sign in through login(baseURL:username:password:).
            throw APIError(status: 0, code: "bad_mode", message: "Введи имя и пароль")
        }
        _ = try await api.health()
        let me = try await api.authMe()
        guard me.ok || me.authEnabled == false else {
            settings.token = nil
            throw APIError(status: 401, code: "auth_required",
                           message: mode == .token ? "Сервер не принял токен" : "Не удалось войти")
        }
        settings.deviceTokenId = nil
        settings.profileId = nil
        await refreshServerMode()
        phase = .ready
        await refreshFavorites()
    }

    /// Accounts: name and password give this phone its own device token.
    func login(baseURL: String, username: String, password: String) async throws {
        settings.baseURL = baseURL
        try await signIn(username: username, password: password)
    }

    /// Accounts: creates one from an invitation, then signs in with it.
    func register(baseURL: String, invitation: String, username: String, password: String) async throws {
        settings.baseURL = baseURL
        settings.token = nil
        clearCookies()
        try await api.register(invitation: invitation, username: username, password: password)
        try await signIn(username: username, password: password)
    }

    private func signIn(username: String, password: String) async throws {
        settings.token = nil
        clearCookies()
        let grant: TokenGrant
        do {
            grant = try await api.deviceToken(username: username, password: password,
                                              deviceName: deviceName)
        } catch let e as APIError where e.isNotFound {
            throw APIError(status: 404, code: e.code, message: "Сервер не поддерживает вход по аккаунту — обнови его")
        }
        // Register and login leave a browser session cookie; with a Bearer token as
        // well the server answers 400 credential_conflict, so only the token stays.
        clearCookies()
        settings.token = grant.token
        let me = try await api.authMe()
        guard me.ok else {
            settings.token = nil
            throw APIError(status: 401, code: "auth_required", message: "Сервер не принял токен устройства")
        }
        settings.multiUser = true
        settings.username = username
        settings.deviceTokenId = grant.device?.id
        settings.profileId = grant.device?.profileId
        // The same name and password open the account session, so "Настройки сервера"
        // work right away; if it fails, that screen asks for the password itself.
        try? await account.signIn(username: username, password: password)
        phase = .ready
        await refreshFavorites()
    }

    /// Name this phone gets in the server's device list.
    var deviceName: String { "\(UIDevice.current.model) · musik iOS" }

    /// Whether the server has accounts; asked without credentials.
    func refreshServerMode() async {
        guard !settings.baseURL.isEmpty, let me = try? await account.publicAuthMe() else { return }
        settings.multiUser = me.multiUser == true
    }

    /// Plays in another profile of the account from now on: this phone gets a new
    /// device token for it, and the old one is revoked.
    func useProfile(_ profile: ServerProfile) async throws {
        let issued = try await account.createDeviceToken(name: deviceName, profileId: profile.id)
        let old = settings.deviceTokenId
        player.stop(clearSession: true)
        settings.token = issued.token
        settings.deviceTokenId = issued.device.id
        settings.profileId = profile.id
        if let old, old != issued.device.id { try? await account.revokeDeviceToken(old) }
        await refreshFavorites()
        homeRevision += 1
        await player.restore()
        show("Профиль «\(profile.name)»")
    }

    private func clearCookies() {
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
    }

    /// musik://connect?url=…&token=… opened from the system Camera or another app.
    func open(_ url: URL) {
        guard let link = ConnectLink(url: url) else { return }
        if phase == .ready {
            show("Уже подключено к серверу. Чтобы подключить другой, выйди в профиле.")
        } else {
            pendingConnect = link
        }
    }

    func logout() async {
        player.stop(clearSession: true)
        await api.logout()
        await account.signOut()
        settings.token = nil
        settings.deviceTokenId = nil
        settings.profileId = nil
        clearCookies()
        ImageLoader.shared.clear()
        favoriteTracks = []
        favoriteArtists = []
        favoriteAlbums = []
        phase = .login
    }

    private func handleUnauthorized() {
        guard phase == .ready else { return }
        player.stop(clearSession: false)
        phase = .login
        show("Сессия истекла — войди снова")
    }

    // MARK: Favorites

    func refreshFavorites() async {
        guard let fav = try? await api.favorites() else { return }
        favoriteTracks = Set((fav.tracks ?? []).map(\.trackId))
        favoriteArtists = Set((fav.artists ?? []).map(\.artist))
        favoriteAlbums = Set((fav.albums ?? []).map(\.id))
    }

    func isFavorite(album: AlbumItem) -> Bool { favoriteAlbums.contains(album.id) }

    /// Toggles a track heart; returns the new state.
    @discardableResult
    func toggleFavoriteTrack(_ id: Int) async -> Bool? {
        do {
            let r = try await api.toggleFavorite(["type": "track", "track_id": id])
            if r.favorited { favoriteTracks.insert(id) } else { favoriteTracks.remove(id) }
            show(r.favorited ? "Любимая песня" : "Песня убрана из любимых")
            homeRevision += 1
            return r.favorited
        } catch {
            show(error)
            return nil
        }
    }

    func toggleFavoriteArtist(_ artist: String) async {
        do {
            let r = try await api.toggleFavorite(["type": "artist", "artist": artist])
            if r.favorited { favoriteArtists.insert(artist) } else { favoriteArtists.remove(artist) }
            show(r.favorited ? "Любимый артист" : "Артист убран")
            homeRevision += 1
        } catch {
            show(error)
        }
    }

    func toggleFavoriteAlbum(artist: String?, album: String) async {
        do {
            let r = try await api.toggleFavorite(["type": "album", "artist": artist ?? "", "album": album])
            let key = albumKey(artist, album)
            if r.favorited { favoriteAlbums.insert(key) } else { favoriteAlbums.remove(key) }
            show(r.favorited ? "Любимый альбом" : "Альбом убран")
            homeRevision += 1
        } catch {
            show(error)
        }
    }

    func addLater(_ trackId: Int) async {
        do {
            try await api.addLater(trackId: trackId)
            show("В «Потом»")
            homeRevision += 1
        } catch {
            show(error)
        }
    }

    // MARK: Toasts

    func show(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { toast = message }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.toast = nil }
        }
    }

    func show(_ error: Error) {
        if error is CancellationError { return }
        show(error.localizedDescription)
    }

    /// Runs an async action and turns any error into a toast.
    func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do { try await action() } catch { show(error) }
        }
    }
}
