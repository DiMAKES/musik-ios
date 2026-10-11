import SwiftUI

struct LoginView: View {
    @EnvironmentObject var app: AppState
    @State private var baseURL = ""
    @State private var mode: AppState.LoginMode = .token
    @State private var secret = ""
    @State private var busy = false
    @State private var error: String?
    @State private var scanning = false
    // Accounts (a server with MUSIK_MULTI_USER)
    @State private var registering = false
    @State private var invitation = ""
    @State private var username = ""
    @State private var password = ""
    @State private var passwordAgain = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("musik").font(.display(56))
                        .foregroundStyle(LinearGradient(colors: [Theme.accentBright, Theme.accent],
                                                        startPoint: .leading, endPoint: .trailing))
                    Text("Твой сервер, твой вкус. Подключись к Go player.")
                        .foregroundStyle(Theme.muted)
                }
                .padding(.top, 48)

                Button {
                    scanning = true
                } label: {
                    Label("Сканировать QR-код", systemImage: "qrcode.viewfinder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle(active: true))
                .disabled(busy)

                Text("QR-код — в веб-интерфейсе: Профиль → Настройки → «Показать QR», или QR приглашения. Или введи данные вручную:")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)

                field("Адрес сервера") {
                    TextField("http://192.168.1.10:8787", text: $baseURL)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Picker("Вход", selection: $mode) {
                    ForEach(AppState.LoginMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if mode == .account {
                    accountFields
                } else {
                    field(mode == .token ? "MUSIK_API_TOKEN" : "MUSIK_PASSWORD") {
                        SecureField(mode == .token ? "токен из .env сервера" : "пароль", text: $secret)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                Button {
                    Task { await submit() }
                } label: {
                    HStack {
                        if busy { ProgressView().tint(.black) }
                        Text(submitTitle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(busy || !canSubmit)

                if mode == .account {
                    Button(registering ? "Уже есть аккаунт — войти" : "У меня есть приглашение") {
                        registering.toggle()
                        error = nil
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentBright)
                    .frame(maxWidth: .infinity)
                    .disabled(busy)
                }

                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            .padding(24)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if baseURL.isEmpty { baseURL = app.settings.baseURL }
            usePendingLink()
        }
        .onChange(of: app.pendingConnect) { _ in usePendingLink() }
        .sheet(isPresented: $scanning) {
            QRScannerSheet { link in app.pendingConnect = link }
        }
    }

    // MARK: Accounts

    @ViewBuilder
    private var accountFields: some View {
        if registering {
            field("Приглашение") {
                TextField("ссылка или код приглашения", text: $invitation)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
        }
        field("Имя") {
            TextField("имя пользователя", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        field("Пароль") {
            SecureField(registering ? "не короче 8 символов" : "пароль", text: $password)
                .textContentType(registering ? .newPassword : .password)
        }
        if registering {
            field("Пароль ещё раз") {
                SecureField("повтори пароль", text: $passwordAgain)
                    .textContentType(.newPassword)
            }
        }
    }

    private var submitTitle: String {
        switch mode {
        case .account: return registering ? "Создать аккаунт" : "Войти"
        default: return "Подключиться"
        }
    }

    private var canSubmit: Bool {
        guard !baseURL.trimmingCharacters(in: .whitespaces).isEmpty || mode == .account && registering else {
            return false
        }
        guard mode == .account else { return true }
        let filled = !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        if registering {
            return filled && !invitation.trimmingCharacters(in: .whitespaces).isEmpty && !passwordAgain.isEmpty
        }
        return filled
    }

    private var footnote: String {
        if mode == .account {
            return "Аккаунты есть на сервере с MUSIK_MULTI_USER. Приглашение выдаёт администратор в веб-интерфейсе; телефон получает свой токен устройства, пароль не сохраняется."
        }
        return "Для LAN запусти player с MUSIK_PLAYER_ADDR=0.0.0.0:8787. Токен рекомендуется: он хранится в Keychain и работает и для потока, и для обложек."
    }

    /// The invitation field takes the whole link (`https://host/?invitation=…`), which
    /// also gives the server address, or the bare code with the address typed above.
    private func invitationTarget() -> (baseURL: String, code: String) {
        let text = invitation.trimmingCharacters(in: .whitespacesAndNewlines)
        if let link = ConnectLink(text), let code = link.invitation {
            return (link.baseURL, code)
        }
        return (baseURL, text)
    }

    // MARK: Actions

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
            content()
                .padding(14)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.white.opacity(0.08)))
        }
    }

    /// A scanned QR or a musik:// link fills the form; with a token it signs in at once.
    /// An invitation opens account creation with the address and the code filled in.
    private func usePendingLink() {
        guard let link = app.pendingConnect else { return }
        app.pendingConnect = nil
        baseURL = link.baseURL
        error = nil
        // The secret always comes from the link: a token or password typed for another
        // server must never be sent to the new address.
        secret = link.token ?? ""
        password = ""
        passwordAgain = ""
        if let code = link.invitation {
            mode = .account
            registering = true
            invitation = code
        } else if link.token != nil {
            mode = .token
            Task { await submit() }
        } else {
            error = "В QR только адрес сервера — введи токен или пароль."
        }
    }

    private func submit() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            switch mode {
            case .account where registering:
                let target = invitationTarget()
                baseURL = target.baseURL
                guard password.count >= 8 else {
                    error = "Пароль — не короче 8 символов"
                    return
                }
                guard password == passwordAgain else {
                    error = "Пароли не совпадают"
                    return
                }
                try await app.register(baseURL: target.baseURL, invitation: target.code,
                                       username: username.trimmingCharacters(in: .whitespaces),
                                       password: password)
            case .account:
                try await app.login(baseURL: baseURL,
                                    username: username.trimmingCharacters(in: .whitespaces),
                                    password: password)
            default:
                try await app.login(baseURL: baseURL, mode: mode, secret: secret)
            }
            secret = ""
            password = ""
            passwordAgain = ""
        } catch is AppState.AccountsRequired {
            mode = .account
            secret = ""
            self.error = AppState.AccountsRequired().localizedDescription
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}
