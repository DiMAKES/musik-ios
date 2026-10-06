import AVFoundation
import MediaPlayer
import UIKit

/// Playback state machine mirroring the web client (app.js):
/// start → stream (+auth) → track_start → progress every ~4 s → track_end | skip → next.
/// Radio sessions have an endless `queue`; fixed lists (mixes, albums, `/api/play`)
/// carry `tracks` and stop with `ended: true` instead of falling back to radio.
@MainActor
final class PlayerController: ObservableObject {
    @Published private(set) var current: Track?
    @Published private(set) var queue: [QueueItem] = []
    @Published private(set) var playlist: [Track] = []
    @Published private(set) var fixed = false
    @Published private(set) var listName: String?
    @Published private(set) var maturity: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var disliked = false
    /// A start / skip request is in flight.
    @Published private(set) var busy = false

    weak var app: AppState?

    private let api: APIClient
    private let settings: Settings
    private let player = AVPlayer()

    private(set) var sessionId: String?
    /// Bumped whenever the loaded item or pending advance changes; stale item callbacks compare against it.
    private var generation = 0
    /// Identifies the latest start / skip / advance request; only its response is applied
    /// and only it clears `busy` (loading the next item bumps `generation`, not this).
    private var requestSeq = 0
    private var startSent = false
    private var listened: Double = 0
    private var lastPos: Double = 0
    private var lastProgressAt = Date.distantPast
    private var failStreak = 0
    private var seeking = false

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var itemNotifications: [NSObjectProtocol] = []
    private var artworkTask: Task<Void, Never>?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var interruptionObserver: NSObjectProtocol?

    // Cross-device sync (see the Sync section): this device owns the shared state
    // while it plays; others pause and cue the same track and position.
    private var syncOwner = false
    private var lastSyncWrite = Date.distantPast
    private var lastSyncSeen = Date.distantPast
    private var appActive = true
    private var syncTask: Task<Void, Never>?
    /// Position to restore once the cued item is ready to play.
    private var pendingSeek: Double?

    init(api: APIClient, settings: Settings) {
        self.api = api
        self.settings = settings
        player.automaticallyWaitsToMinimizeStalling = true
        configureAudioSession()
        configureRemoteCommands()
        observePlayer()
        startSyncLoop()
    }

    var hasSession: Bool { sessionId != nil }

    // MARK: - Starting playback

    func startRadio(seed: Int? = nil) {
        var body: [String: Any] = [:]
        if let seed { body["seed_track_id"] = seed }
        start { try await self.api.post("/api/radio/start", body) }
    }

    /// POST /api/play: `track_id`, `track_ids`, `artist`, `album`, `start_track_id`, `name`.
    func play(_ body: [String: Any]) {
        start { try await self.api.post("/api/play", body) }
    }

    func playMix(_ kind: String, startTrackId: Int? = nil) {
        let escaped = kind.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? kind
        var body: [String: Any] = [:]
        if let startTrackId { body["start_track_id"] = startTrackId }
        start { try await self.api.post("/api/mixes/\(escaped)/play", body) }
    }

    func playSimilarNow() {
        guard let track = current else { return }
        start {
            let hits = try await self.api.recommendSeed(trackId: track.id)
            guard !hits.isEmpty else {
                throw APIError(status: 0, code: "empty", message: "Похожих треков не нашлось")
            }
            return try await self.api.post("/api/play", [
                "track_ids": hits.map(\.id),
                "name": "Похоже на «\(track.displayTitle)»",
            ])
        }
    }

    /// Jump inside the current list / radio queue.
    func jump(trackId: Int, index: Int) {
        guard let sid = sessionId, trackId != current?.id else { return }
        start {
            try await self.api.post("/api/session/jump", ["session_id": sid, "index": index, "track_id": trackId])
        }
    }

    private func start(_ request: @escaping () async throws -> PlayPayload) {
        generation += 1
        let req = nextRequest()
        Task {
            defer { self.finish(req) }
            do {
                let payload = try await request()
                guard req == self.requestSeq else { return }
                self.apply(payload, autoplay: true)
            } catch {
                self.app?.show(error)
            }
        }
    }

    /// Resume after an app restart (paused, like the web UI): where the owner last
    /// listened on any device, otherwise this device's last session.
    func restore() async {
        guard current == nil else { return }
        if let shared = try? await api.playbackState(), let state = shared.state {
            noteSeen(state)
            if await cue(state, fallback: shared.track) { return }
        }
        guard current == nil, let sid = settings.sessionId else { return }
        do {
            let payload: PlayPayload = try await api.get("/api/now", query: [URLQueryItem(name: "session_id", value: sid)])
            setSession(sid)
            apply(payload, autoplay: false)
        } catch let e as APIError where e.isNotFound {
            settings.sessionId = nil
        } catch {}
    }

    private func apply(_ p: PlayPayload, autoplay: Bool) {
        if let sid = p.sessionId { setSession(sid) }
        if let m = p.maturity { maturity = m }
        let tracks = p.tracks ?? []
        fixed = p.fixed ?? !tracks.isEmpty
        if fixed {
            playlist = tracks
            queue = []
            listName = p.name.nonEmpty ?? p.mode
        } else {
            playlist = []
            queue = p.queue ?? []
            listName = p.name.nonEmpty ?? "Радио"
        }
        if let cur = p.current {
            load(cur, autoplay: autoplay)
        } else if autoplay {
            app?.show("Здесь пока нечего играть")
        }
    }

    private func setSession(_ id: String) {
        sessionId = id
        settings.sessionId = id
    }

    // MARK: - Transport

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            resume()
        }
    }

    func resume() {
        guard let track = current else { return }
        if player.currentItem == nil || player.currentItem?.status == .failed {
            load(track, autoplay: true)
            return
        }
        activateAudioSession()
        player.play()
        if !startSent { sendStart(track) }
    }

    func pause() { player.pause() }

    func seek(to seconds: Double) {
        guard player.currentItem != nil else { return }
        let target = max(0, duration > 0 ? min(seconds, duration - 0.25) : seconds)
        seeking = true
        position = target
        lastPos = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.seeking = false
                self.lastPos = self.player.currentTime().seconds
                self.updateNowPlaying()
                self.pushState()
            }
        }
    }

    func skip() {
        guard let track = current, sessionId != nil else { return }
        generation += 1
        let req = nextRequest()
        player.pause()
        Task {
            defer { self.finish(req) }
            do {
                let res = try await self.postEvent("skip", track: track, reason: "skipped", retry: true)
                guard req == self.requestSeq, let res else { return }
                self.advance(with: res)
            } catch {
                self.app?.show(error)
                if req == self.requestSeq { self.player.play() }
            }
        }
    }

    private func nextRequest() -> Int {
        requestSeq += 1
        busy = true
        return requestSeq
    }

    private func finish(_ req: Int) {
        if req == requestSeq { busy = false }
    }

    func back() {
        guard current != nil, let sid = sessionId else { return }
        if position > 3 {
            seek(to: 0)
            listened = 0
            if !isPlaying { resume() }
            return
        }
        start { try await self.api.post("/api/session/back", ["session_id": sid]) }
    }

    private func trackFinished(gen: Int) {
        guard gen == generation, let track = current else { return }
        generation += 1
        requestSeq += 1
        let req = requestSeq
        position = duration
        Task {
            do {
                let res = try await self.postEvent("track_end", track: track, reason: "completed", retry: true)
                guard req == self.requestSeq, let res else { return }
                self.advance(with: res)
            } catch {
                self.app?.show(error)
            }
        }
    }

    private func advance(with res: EventResult) {
        applyLists(res)
        if let next = res.next {
            load(next, autoplay: true)
        } else if res.ended == true {
            player.pause()
            app?.show("Конец плейлиста")
        }
    }

    private func applyLists(_ res: EventResult) {
        if let sid = res.sessionId { setSession(sid) }
        if let m = res.maturity { maturity = m }
        if let name = res.name.nonEmpty { listName = name }
        if let tracks = res.tracks {
            fixed = true
            playlist = tracks
        } else if let q = res.queue {
            queue = q
        }
    }

    // MARK: - Rating

    var isFavorite: Bool {
        guard let id = current?.id else { return false }
        return app?.favoriteTracks.contains(id) ?? false
    }

    /// ♥ = favorite toggle; a fresh heart also sends a `like` event (as the web UI does).
    func like() {
        guard let track = current, let app else { return }
        Task {
            let favorited = await app.toggleFavoriteTrack(track.id)
            self.updateNowPlaying()
            if favorited == true {
                if let res = try? await self.postEvent("like", track: track) { self.applyLists(res) }
            }
        }
    }

    func dislike() {
        guard let track = current else { return }
        Task {
            do {
                guard let res = try await self.postEvent("dislike", track: track) else { return }
                self.applyLists(res)
                if track.id == self.current?.id {
                    self.disliked = true
                    self.updateNowPlaying()
                }
                self.app?.show(res.ignored == true ? "Уже дизлайк" : "Дизлайк — меньше такого")
            } catch {
                self.app?.show(error)
            }
        }
    }

    // MARK: - Loading

    private func load(_ track: Track, autoplay: Bool) {
        generation += 1
        let gen = generation
        current = track
        disliked = false
        startSent = false
        position = 0
        duration = track.duration ?? 0
        listened = 0
        lastPos = 0
        lastProgressAt = Date()

        guard let url = api.streamURL(for: track) else { return }
        var options: [String: Any] = [:]
        let headers = api.authHeaders()
        if !headers.isEmpty { options["AVURLAssetHTTPHeaderFieldsKey"] = headers }
        let cookies = api.cookies(for: url)
        if !cookies.isEmpty { options[AVURLAssetHTTPCookiesKey] = cookies }
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        observe(item, gen: gen)
        player.replaceCurrentItem(with: item)

        nowPlayingArtwork = nil
        updateNowPlaying()
        loadNowPlayingArtwork(for: track)

        if autoplay {
            activateAudioSession()
            player.play()
            sendStart(track)
        }
    }

    private func sendStart(_ track: Track) {
        startSent = true
        Task { _ = try? await self.postEvent("track_start", track: track) }
    }

    private func observe(_ item: AVPlayerItem, gen: Int) {
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications = [
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.trackFinished(gen: gen) }
            },
            NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.playbackFailed(gen: gen, error: nil) }
            },
        ]
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch status {
                case .readyToPlay:
                    self.failStreak = 0
                    let d = item.duration.seconds
                    if d.isFinite, d > 0 { self.duration = d }
                    self.updateNowPlaying()
                    if let at = self.pendingSeek {
                        self.pendingSeek = nil
                        self.seek(to: at)
                    }
                case .failed:
                    self.playbackFailed(gen: gen, error: error)
                default:
                    break
                }
            }
        }
    }

    private func playbackFailed(gen: Int, error: Error?) {
        guard gen == generation, let track = current else { return }
        failStreak += 1
        app?.show("Не удалось воспроизвести «\(track.displayTitle)»")
        // Unsupported codec or a missing file: move on, but don't spin through a broken library.
        if failStreak <= 3 {
            skip()
        } else {
            player.pause()
        }
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.tick(seconds) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in
                guard let self else { return }
                let playing = status != .paused
                self.isBuffering = status == .waitingToPlayAtSpecifiedRate
                if playing != self.isPlaying {
                    self.isPlaying = playing
                    self.updateNowPlaying()
                    if playing {
                        // Playing here takes the shared state over from any other device.
                        self.syncOwner = true
                        self.pushState(playing: true, claim: true)
                    } else {
                        self.pushState(playing: false)
                    }
                }
            }
        }
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let info = note.userInfo,
                  let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended,
                  let optRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
                  AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume)
            else { return }
            Task { @MainActor in self?.resume() }
        }
    }

    private func tick(_ seconds: Double) {
        guard !seeking, current != nil, seconds.isFinite else { return }
        if seconds > lastPos, seconds - lastPos < 5 { listened += seconds - lastPos }
        lastPos = seconds
        position = seconds
        if let d = player.currentItem?.duration.seconds, d.isFinite, d > 0, abs(d - duration) > 0.5 {
            duration = d
            updateNowPlaying()
        }
        if isPlaying, Date().timeIntervalSince(lastSyncWrite) >= 5 { pushState() }
        if isPlaying, Date().timeIntervalSince(lastProgressAt) >= 4 {
            lastProgressAt = Date()
            Task { _ = try? await self.postEvent("progress") }
        }
    }

    func stop(clearSession: Bool) {
        syncOwner = false
        pendingSeek = nil
        generation += 1
        requestSeq += 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
        itemNotifications = []
        itemObservation = nil
        current = nil
        queue = []
        playlist = []
        listName = nil
        position = 0
        duration = 0
        busy = false
        if clearSession {
            sessionId = nil
            settings.sessionId = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Sync

    /// Called from RootView on scenePhase changes.
    func sceneChanged(active: Bool, background: Bool) {
        appActive = active
        if active {
            Task { await syncPoll() }
        } else if background {
            pushState()
        }
    }

    /// Writes where this device is. `claim` takes the state over (playback started
    /// here); other writes are heartbeats the server accepts only from the owner.
    private func pushState(playing: Bool? = nil, claim: Bool = false) {
        guard syncOwner, let sid = sessionId, let track = current else { return }
        lastSyncWrite = Date()
        let body: [String: Any] = [
            "session_id": sid,
            "track_id": track.id,
            "position_sec": position,
            "listened_sec": listened,
            "playing": playing ?? isPlaying,
            "client_id": settings.clientId,
            "claim": claim,
        ]
        Task {
            guard let res = try? await self.api.putPlaybackState(body), let state = res.state else { return }
            self.noteSeen(state)
            if !res.ok { await self.yield(to: state, fallback: nil) }
        }
    }

    private func startSyncLoop() {
        syncTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                if self.appActive || self.isPlaying { await self.syncPoll() }
            }
        }
    }

    private func syncPoll() async {
        guard app?.phase == .ready,
              let shared = try? await api.playbackState(), let state = shared.state,
              state.clientId != settings.clientId,
              Self.date(state.updatedAt) > lastSyncSeen else { return }
        noteSeen(state)
        await yield(to: state, fallback: shared.track)
    }

    /// Another device owns playback now: stop here (ownership first, so the pause
    /// does not write back) and cue its track and position.
    private func yield(to state: PlaybackState, fallback: Track?) async {
        syncOwner = false
        if player.timeControlStatus != .paused {
            player.pause()
            app?.show("Играет на другом устройстве")
        }
        _ = await cue(state, fallback: fallback)
    }

    /// Loads the shared track paused at the shared position. The listen already
    /// started on the other device, so no new track_start is sent (`startSent`).
    @discardableResult
    private func cue(_ state: PlaybackState, fallback: Track?) async -> Bool {
        if current?.id == state.trackId, player.currentItem != nil {
            if abs(position - state.positionSec) > 2 { seek(to: state.positionSec) }
            listened = max(listened, state.listenedSec)
            return true
        }
        setSession(state.sessionId)
        var track = fallback
        if var now: PlayPayload = try? await api.get("/api/now", query: [URLQueryItem(name: "session_id", value: state.sessionId)]) {
            // /api/now carries impression_id for the session's current track.
            if let cur = now.current, cur.id == state.trackId { track = cur }
            now.current = nil
            apply(now, autoplay: false) // queue / list only
        }
        guard let track else { return false }
        load(track, autoplay: false)
        startSent = true
        listened = state.listenedSec
        position = state.positionSec
        pendingSeek = state.positionSec > 1 ? state.positionSec : nil
        updateNowPlaying()
        return true
    }

    private func noteSeen(_ state: PlaybackState) {
        let at = Self.date(state.updatedAt)
        if at > lastSyncSeen { lastSyncSeen = at }
    }

    /// Go writes RFC 3339 with up to 9 fractional digits; ISO8601DateFormatter reads 3.
    static func date(_ raw: String) -> Date {
        var s = raw
        if let dot = s.firstIndex(of: "."),
           let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let digits = s[s.index(after: dot)..<end]
            s.replaceSubrange(s.index(after: dot)..<end, with: String(digits.prefix(3)))
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s) ?? .distantPast
    }

    // MARK: - Events

    @discardableResult
    private func postEvent(_ type: String, track: Track? = nil, reason: String? = nil,
                           retry: Bool = false) async throws -> EventResult? {
        guard let sid = sessionId, let t = track ?? current else { return nil }
        let isCurrent = t.id == current?.id
        var body: [String: Any] = [
            "type": type,
            "event_id": UUID().uuidString.lowercased(),
            "track_id": t.id,
            "session_id": sid,
            "client_id": settings.clientId,
            "device_id": settings.deviceId,
            "position_sec": isCurrent ? position : 0,
            "duration_sec": isCurrent && duration > 0 ? duration : (t.duration ?? 0),
            "listened_sec": isCurrent ? listened : 0,
        ]
        if let imp = t.impressionId { body["impression_id"] = imp }
        if let reason { body["reason"] = reason }

        let data: Data
        do {
            data = try await api.send("POST", "/api/events", body: body)
        } catch let e as APIError where retry && e.status == 0 {
            // Same event_id: the server deduplicates retries.
            _ = e
            try await Task.sleep(nanoseconds: 1_000_000_000)
            data = try await api.send("POST", "/api/events", body: body)
        }
        return try api.decode(EventResult.self, from: data)
    }

    // MARK: - System integration

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
    }

    private func activateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in
            self?.resume()
            return .success
        }
        c.pauseCommand.addTarget { [weak self] _ in
            self?.pause()
            return .success
        }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlay()
            return .success
        }
        c.nextTrackCommand.addTarget { [weak self] _ in
            self?.skip()
            return .success
        }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
        c.skipForwardCommand.isEnabled = false
        c.skipBackwardCommand.isEnabled = false

        // Like / dislike on the lock screen. iOS shows feedback commands in the slot of the
        // previous-track button, so that one stays in the app only.
        c.likeCommand.localizedTitle = "Нравится"
        c.likeCommand.localizedShortTitle = "Лайк"
        c.likeCommand.addTarget { [weak self] _ in
            self?.like()
            return .success
        }
        c.dislikeCommand.localizedTitle = "Не нравится"
        c.dislikeCommand.localizedShortTitle = "Дизлайк"
        c.dislikeCommand.addTarget { [weak self] _ in
            self?.dislike()
            return .success
        }
        c.previousTrackCommand.isEnabled = false
    }

    private func updateNowPlaying() {
        let c = MPRemoteCommandCenter.shared()
        c.likeCommand.isActive = isFavorite
        c.dislikeCommand.isActive = disliked
        guard let t = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.displayTitle,
            MPMediaItemPropertyArtist: t.displayArtist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let album = t.album.nonEmpty { info[MPMediaItemPropertyAlbumTitle] = album }
        if let art = nowPlayingArtwork { info[MPMediaItemPropertyArtwork] = art }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadNowPlayingArtwork(for track: Track) {
        artworkTask?.cancel()
        guard let url = api.artworkURL(trackId: track.id, width: 640) else { return }
        artworkTask = Task {
            guard let img = await ImageLoader.shared.image(url),
                  !Task.isCancelled, self.current?.id == track.id else { return }
            self.nowPlayingArtwork = Self.makeArtwork(img)
            self.updateNowPlaying()
        }
    }

    /// Built outside the main actor: MediaPlayer calls the handler on its own queue.
    nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
