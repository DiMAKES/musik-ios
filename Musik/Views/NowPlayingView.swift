import SwiftUI

/// Full-screen player that fits one screen without scrolling. The toggles at the top swap the
/// artwork for the up-next list or the lyrics; tapping the active toggle returns to the artwork.
struct NowPlayingView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case queue = "Дальше"
        case lyrics = "Текст"
        var id: String { rawValue }
    }

    @EnvironmentObject var app: AppState
    @EnvironmentObject var player: PlayerController
    @Environment(\.dismiss) private var dismiss

    @State private var scrubbing = false
    @State private var scrub: Double = 0
    /// nil shows the artwork.
    @State private var pane: Pane?

    var body: some View {
        ZStack {
            Theme.backdrop
            if let track = player.current {
                VStack(spacing: 14) {
                    topBar
                    paneToggles
                    content(track)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    titleBlock(track)
                    seekBar
                    transport
                        .padding(.bottom, 8)
                }
                .padding(.bottom, 12)
            } else {
                VStack(spacing: 12) {
                    Text("Ничего не играет").font(.title3.weight(.semibold))
                    Button("Включить радио") { player.startRadio() }
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .overlay(alignment: .top) { ToastView() }
    }

    // MARK: Parts

    private var topBar: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.title3.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            Spacer()
            VStack(spacing: 2) {
                Text(player.listName ?? (player.fixed ? "Плейлист" : "Радио"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(Labels.maturity(player.maturity))
                    .font(.caption2)
                    .foregroundStyle(Theme.teal)
            }
            Spacer()
            Color.clear.frame(width: 32, height: 32)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.top, 16)
    }

    private var paneToggles: some View {
        HStack(spacing: 10) {
            ForEach(Pane.allCases) { p in
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { pane = pane == p ? nil : p }
                } label: {
                    Text(p.rawValue)
                }
                .buttonStyle(ChipButtonStyle(active: pane == p))
            }
        }
    }

    @ViewBuilder
    private func content(_ track: Track) -> some View {
        switch pane {
        case nil:
            ArtworkView(trackId: track.id, size: 640, fallback: track.displayTitle, cornerRadius: 22)
                .shadow(color: .black.opacity(0.55), radius: 28, y: 14)
                .scaleEffect(player.isPlaying ? 1 : 0.94)
                .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.isPlaying)
                .padding(.horizontal, 28)
                .transition(.opacity)
        case .queue?:
            ScrollView { upNext.padding(.vertical, 4) }
                .transition(.opacity)
        case .lyrics?:
            LyricsView(trackId: track.id)
                .transition(.opacity)
        }
    }

    private func titleBlock(_ track: Track) -> some View {
        VStack(spacing: 4) {
            Text(track.displayTitle)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(1)
            Text(track.subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            if let source = Labels.source(track.source) {
                Text(source)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.teal.opacity(0.25), in: Capsule())
                    .foregroundStyle(Theme.teal)
            }
        }
        .padding(.horizontal, 24)
    }

    private var seekBar: some View {
        let total = max(player.duration, 1)
        return VStack(spacing: 4) {
            Slider(value: Binding(
                get: { scrubbing ? scrub : min(player.position, total) },
                set: { scrub = $0 }
            ), in: 0...total, onEditingChanged: { editing in
                if editing {
                    scrub = player.position
                    scrubbing = true
                } else {
                    player.seek(to: scrub)
                    scrubbing = false
                }
            })
            HStack {
                Text(formatTime(scrubbing ? scrub : player.position))
                Spacer()
                Text(formatTime(player.duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 24)
    }

    /// Dislike · back · play/pause · next · like.
    private var transport: some View {
        HStack {
            Button { player.dislike() } label: {
                Image(systemName: player.disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .font(.title2)
                    .foregroundStyle(player.disliked ? Theme.accentBright : .primary)
                    .frame(width: 44, height: 44)
            }
            .disabled(player.disliked)
            .accessibilityLabel("Дизлайк")
            Spacer()
            Button { player.back() } label: {
                Image(systemName: "backward.fill").font(.title).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Предыдущий")
            Spacer()
            Button { player.togglePlay() } label: {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Theme.accentBright, Theme.accent],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 72, height: 72)
                    if player.isBuffering || player.busy {
                        ProgressView().tint(.black)
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.black.opacity(0.85))
                    }
                }
            }
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Играть")
            Spacer()
            Button { player.skip() } label: {
                Image(systemName: "forward.fill").font(.title).frame(width: 44, height: 44)
            }
            .disabled(player.busy)
            .accessibilityLabel("Следующий")
            Spacer()
            Button { player.like() } label: {
                Image(systemName: player.isFavorite ? "heart.fill" : "heart")
                    .font(.title2)
                    .foregroundStyle(player.isFavorite ? Theme.accent : .primary)
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Лайк")
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 20)
    }

    private var upNext: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if player.fixed {
                Text("В этом списке · \(player.playlist.count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                ForEach(Array(player.playlist.enumerated()), id: \.offset) { i, t in
                    TrackRow(track: t, index: i) {
                        player.jump(trackId: t.id, index: t.position ?? i)
                    }
                }
            } else {
                Text("Дальше в радио · нажми — сразу она")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.muted)
                ForEach(Array(player.queue.enumerated()), id: \.offset) { i, item in
                    QueueRow(item: item) {
                        player.jump(trackId: item.trackId, index: i)
                    }
                }
                if player.queue.isEmpty {
                    EmptyHint(text: "Очередь пополнится после следующего трека")
                }
            }
        }
        .padding(.horizontal, 20)
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ArtworkView(trackId: item.trackId, size: 96, fallback: item.title ?? "♪", cornerRadius: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.nonEmpty ?? "#\(item.trackId)").lineLimit(1)
                    HStack(spacing: 6) {
                        Text(item.artist ?? "").lineLimit(1)
                        if let why = Labels.why(item) {
                            Text(why).italic().foregroundStyle(Theme.teal).lineLimit(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 8)
                Text(formatTime(item.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.muted)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Plain or time-synced (LRC) lyrics in their own scroll area; the synced line under the
/// playhead is highlighted and kept centred.
struct LyricsView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var player: PlayerController
    let trackId: Int

    @State private var lyrics: Lyrics?
    @State private var lines: [(time: Double, text: String)] = []
    @State private var loading = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity)
                    } else if !lines.isEmpty {
                        let active = activeIndex
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.title3.weight(i == active ? .bold : .regular))
                                .foregroundStyle(i == active ? Theme.accentBright : Theme.muted)
                                .id(i)
                                .onTapGesture { player.seek(to: line.time) }
                        }
                    } else if let plain = lyrics?.plainLyrics.nonEmpty {
                        Text(plain).font(.body).foregroundStyle(Color.primary.opacity(0.9))
                    } else {
                        EmptyHint(text: lyrics?.status == "instrumental" ? "Инструментал" : "Текста нет")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.vertical, 8)
            }
            .onChange(of: activeIndex) { index in
                guard let index else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(index, anchor: .center) }
            }
        }
        .task(id: trackId) { await load() }
    }

    private var activeIndex: Int? {
        lines.lastIndex { $0.time <= player.position + 0.3 }
    }

    private func load() async {
        loading = true
        lyrics = try? await app.api.lyrics(trackId: trackId)
        lines = Self.parseLRC(lyrics?.syncedLyrics ?? "")
        loading = false
    }

    static func parseLRC(_ text: String) -> [(time: Double, text: String)] {
        guard let re = try? NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#) else { return [] }
        var out: [(time: Double, text: String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let ns = raw as NSString
            let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let body = ns.substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let sec = Double(ns.substring(with: m.range(at: 2))) ?? 0
                out.append((minutes * 60 + sec, body))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
