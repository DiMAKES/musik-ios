import SwiftUI

@main
struct MusikApp: App {
    @StateObject private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(app.player)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.backdrop
            switch app.phase {
            case .checking:
                VStack(spacing: 16) {
                    Text("musik").font(.display(44))
                    ProgressView()
                }
            case .login:
                LoginView()
            case .ready:
                MainView()
            }
        }
        .overlay(alignment: .top) { ToastView() }
        .task { await app.bootstrap() }
        .onOpenURL { app.open($0) }
        .onChange(of: scenePhase) { phase in
            app.player.sceneChanged(active: phase == .active, background: phase == .background)
        }
    }
}

struct MainView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var player: PlayerController
    @State private var showPlayer = false
    @State private var miniPlayerHeight: CGFloat = 0

    var body: some View {
        TabView {
            tab { HomeView() }
                .tabItem { Label("Главная", systemImage: "house.fill") }
            tab { LibraryView() }
                .tabItem { Label("Библиотека", systemImage: "music.note.list") }
            tab { ProfileView() }
                .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
        }
        .sheet(isPresented: $showPlayer) {
            NowPlayingView()
                .environmentObject(app)
                .environmentObject(player)
                .presentationDragIndicator(.visible)
        }
    }

    /// A safe-area inset on the NavigationStack does not reach the lists inside it, so the
    /// mini player floats over the stack and every screen leaves room for it itself
    /// (`miniPlayerSpace()`), sized by the player's measured height.
    private func tab<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        NavigationStack {
            content()
                .miniPlayerSpace()
                .withRoutes()
        }
        .environment(\.miniPlayerInset, player.current == nil ? 0 : miniPlayerHeight)
        .overlay(alignment: .bottom) {
            if player.current != nil {
                MiniPlayer { showPlayer = true }
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: MiniPlayerHeightKey.self, value: geo.size.height)
                    })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onPreferenceChange(MiniPlayerHeightKey.self) { miniPlayerHeight = $0 }
        .animation(.easeOut(duration: 0.25), value: player.current?.id)
    }
}

private struct MiniPlayerHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
