import SwiftUI
import UIKit

/// Profile → "Настройки сервера": what the web UI's account panel does, on a server
/// with accounts. Profiles, devices and the password for everyone; invitations and
/// users for administrators. It works through the account session (AccountClient),
/// which asks for the password once and then lasts 14 days.
struct ServerSettingsView: View {
    @EnvironmentObject var app: AppState

    @State private var signedIn = false
    @State private var me: AccountMe?
    @State private var tokens: [DeviceTokenInfo] = []
    @State private var invitations: [InvitationInfo] = []
    @State private var users: [AccountInfo] = []
    @State private var loading = false

    // Sign-in form
    @State private var username = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var signInError: String?

    // Profiles
    @State private var selectedProfile: ServerProfile?
    @State private var profileToDelete: ServerProfile?
    @State private var renameTarget: ServerProfile?
    @State private var profileName = ""
    @State private var creatingProfile = false

    // Users
    @State private var selectedUser: AccountInfo?

    @State private var sheet: SettingsSheet?

    var body: some View {
        List {
            serverSection
            if !app.settings.multiUser {
                Section {
                    Text("На этом сервере нет аккаунтов: вход по общему паролю или токену. Профили, устройства и приглашения появляются, когда на сервере включён MUSIK_MULTI_USER.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            } else if !signedIn {
                signInSection
            } else if let me {
                accountSection(me)
                profilesSection(me)
                devicesSection
                if me.isAdmin {
                    invitationsSection
                    usersSection
                }
                Section {
                    Button("Выйти из управления сервером", role: .destructive) {
                        Task {
                            await app.account.signOut()
                            signedIn = false
                            self.me = nil
                        }
                    }
                } footer: {
                    Text("Музыка на этом iPhone продолжит играть: она работает по токену устройства.")
                }
            } else if loading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.backdrop)
        .navigationTitle("Настройки сервера")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task {
            await app.refreshServerMode()
            if username.isEmpty { username = app.settings.username ?? "" }
            await load()
        }
        .sheet(item: $sheet) { which in
            NavigationStack { sheetContent(which) }
                .environmentObject(app)
                .presentationDetents([.medium, .large])
        }
        .confirmationDialog(selectedProfile?.name ?? "", isPresented: present($selectedProfile),
                            titleVisibility: .visible, presenting: selectedProfile) { profile in
            if profile.id != app.settings.profileId {
                Button("Слушать в этом профиле на iPhone") { run { try await app.useProfile(profile) } }
            }
            Button("Переименовать") {
                profileName = profile.name
                renameTarget = profile
            }
            if (me?.profiles?.count ?? 0) > 1 {
                Button("Удалить профиль", role: .destructive) { profileToDelete = profile }
            }
        }
        .confirmationDialog("Удалить профиль «\(profileToDelete?.name ?? "")»?", isPresented: present($profileToDelete),
                            titleVisibility: .visible, presenting: profileToDelete) { profile in
            Button("Удалить", role: .destructive) { run { try await app.account.deleteProfile(profile.id) } }
        } message: { _ in
            Text("История, любимое и плейлисты профиля сохранятся в архиве на сервере.")
        }
        .alert("Новый профиль", isPresented: $creatingProfile) {
            TextField("Название", text: $profileName)
            Button("Создать") {
                let name = profileName.trimmingCharacters(in: .whitespaces)
                run { _ = try await app.account.createProfile(name: name) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("У профиля свои история, любимое, плейлисты и настройки радио.")
        }
        .alert("Переименовать профиль", isPresented: present($renameTarget)) {
            TextField("Название", text: $profileName)
            Button("Сохранить") {
                guard let target = renameTarget else { return }
                let name = profileName.trimmingCharacters(in: .whitespaces)
                run { try await app.account.renameProfile(target.id, name: name) }
            }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog(selectedUser?.displayName ?? "", isPresented: present($selectedUser),
                            titleVisibility: .visible, presenting: selectedUser) { user in
            let active = user.status == "active"
            Button(active ? "Отключить вход" : "Включить вход", role: active ? .destructive : nil) {
                run { try await app.account.updateUser(user.id, status: active ? "disabled" : "active", admin: user.admin) }
            }
            Button(user.admin ? "Снять права администратора" : "Сделать администратором") {
                run { try await app.account.updateUser(user.id, status: user.status, admin: !user.admin) }
            }
        }
    }

    // MARK: Sections

    private var serverSection: some View {
        Section("Сервер") {
            LabeledContent("Адрес", value: app.settings.baseURL)
            LabeledContent("Аккаунты", value: app.settings.multiUser ? "есть" : "нет")
        }
    }

    private var signInSection: some View {
        Section {
            TextField("Имя", text: $username)
                .textContentType(.username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Пароль", text: $password)
                .textContentType(.password)
            if let signInError {
                Text(signInError).font(.footnote).foregroundStyle(.red)
            }
            Button {
                Task { await signIn() }
            } label: {
                HStack {
                    Text("Войти")
                    if signingIn { Spacer(); ProgressView() }
                }
            }
            .disabled(signingIn || username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
        } header: {
            Text("Вход в аккаунт")
        } footer: {
            Text("Нужен для профилей, устройств и приглашений — как вход на сайте. Пароль не сохраняется, сессия действует 14 дней.")
        }
    }

    private func accountSection(_ me: AccountMe) -> some View {
        Section("Аккаунт") {
            LabeledContent("Имя", value: me.user?.displayName ?? "—")
            LabeledContent("Роль", value: me.isAdmin ? "Администратор" : "Пользователь")
            if me.localAccount == true {
                Button("Сменить пароль") { sheet = .password }
            }
        }
    }

    private func profilesSection(_ me: AccountMe) -> some View {
        Section {
            ForEach(me.profiles ?? []) { profile in
                Button {
                    selectedProfile = profile
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name).foregroundStyle(.primary)
                            if profile.isDefault == true {
                                Text("основной").font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                        Spacer()
                        if profile.id == app.settings.profileId {
                            Text("на этом iPhone").font(.caption.weight(.semibold)).foregroundStyle(Theme.teal)
                        }
                    }
                }
            }
            Button {
                profileName = ""
                creatingProfile = true
            } label: {
                Label("Новый профиль", systemImage: "plus.circle")
            }
        } header: {
            Text("Профили")
        } footer: {
            Text("У каждого профиля свои история, любимое, плейлисты и настройки радио. Нажми на профиль, чтобы слушать в нём на этом iPhone, переименовать или удалить.")
        }
    }

    private var devicesSection: some View {
        Section {
            ForEach(tokens) { token in
                let current = token.id == app.settings.deviceTokenId
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(token.name).font(.subheadline.weight(.semibold))
                        if current {
                            Text("этот iPhone").font(.caption.weight(.semibold)).foregroundStyle(Theme.teal)
                        }
                    }
                    Text("Профиль: \(token.profileName ?? "—")")
                    Text("Последнее использование: \(ServerDate.text(token.lastUsedAt))")
                    if let revoked = token.revokedAt {
                        Text("Отозван: \(ServerDate.text(revoked))").foregroundStyle(.red)
                    } else {
                        Text("Действует до \(ServerDate.text(token.expiresAt))")
                    }
                }
                .font(.caption)
                .foregroundStyle(token.revokedAt == nil ? Color.primary : Theme.muted)
                .swipeActions {
                    if token.revokedAt == nil && !current {
                        Button(role: .destructive) {
                            run { try await app.account.revokeDeviceToken(token.id) }
                        } label: { Label("Отозвать", systemImage: "xmark.circle") }
                        Button {
                            run {
                                let issued = try await app.account.replaceDeviceToken(token.id)
                                sheet = .secret(.deviceToken(issued, baseURL: app.settings.baseURL))
                            }
                        } label: { Label("Перевыпустить", systemImage: "arrow.triangle.2.circlepath") }
                            .tint(Theme.accent)
                    }
                }
            }
            Button {
                sheet = .newToken
            } label: {
                Label("Создать токен устройства", systemImage: "plus.circle")
            }
        } header: {
            Text("Устройства и токены")
        } footer: {
            Text("Токен действует 180 дней и привязан к профилю. Другой телефон сканирует его QR в приложении. Свайп влево — отозвать или перевыпустить.")
        }
    }

    private var invitationsSection: some View {
        Section {
            Button {
                sheet = .invite
            } label: {
                Label("Пригласить пользователя", systemImage: "person.badge.plus")
            }
            ForEach(invitations) { invite in
                VStack(alignment: .leading, spacing: 3) {
                    Text(invite.email ?? "Без привязки к email").font(.subheadline.weight(.semibold))
                    Text("\(invite.state) · до \(ServerDate.text(invite.expiresAt))")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                .swipeActions {
                    if invite.isPending {
                        Button(role: .destructive) {
                            run { try await app.account.revokeInvitation(invite.id) }
                        } label: { Label("Отозвать", systemImage: "xmark.circle") }
                    }
                }
            }
        } header: {
            Text("Приглашения")
        } footer: {
            Text("Ссылка одноразовая: по ней человек сам придумывает имя и пароль. Свайп влево — отозвать неиспользованное.")
        }
    }

    private var usersSection: some View {
        Section {
            ForEach(users) { user in
                Button {
                    selectedUser = user
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(user.displayName).foregroundStyle(.primary)
                            Text("профилей: \(user.profiles)").font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            if user.admin {
                                Text("админ").font(.caption.weight(.semibold)).foregroundStyle(Theme.accentBright)
                            }
                            Text(user.status == "active" ? "активен" : "отключён")
                                .font(.caption)
                                .foregroundStyle(user.status == "active" ? Theme.teal : .red)
                        }
                    }
                }
            }
        } header: {
            Text("Пользователи")
        } footer: {
            Text("Нажми на пользователя, чтобы отключить или включить вход и выдать или снять права администратора. Последнего администратора сервер не даст лишить прав.")
        }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ which: SettingsSheet) -> some View {
        switch which {
        case .password:
            PasswordChangeView { current, new in
                try await app.account.changePassword(current: current, new: new)
                app.show("Пароль изменён")
            }
        case .newToken:
            NewDeviceTokenView(profiles: me?.profiles ?? []) { name, profileId in
                let issued = try await app.account.createDeviceToken(name: name, profileId: profileId)
                await load()
                sheet = .secret(.deviceToken(issued, baseURL: app.settings.baseURL))
            }
        case .invite:
            NewInvitationView { email, hours in
                let created = try await app.account.createInvitation(email: email, hours: hours)
                await load()
                sheet = .secret(.invitation(created))
            }
        case .secret(let info):
            SecretView(info: info)
        }
    }

    // MARK: Actions

    private func signIn() async {
        signingIn = true
        signInError = nil
        defer { signingIn = false }
        do {
            try await app.account.signIn(username: username.trimmingCharacters(in: .whitespaces), password: password)
            password = ""
            await load()
        } catch {
            signInError = error.localizedDescription
        }
    }

    private func load() async {
        guard app.settings.multiUser else { return }
        signedIn = app.account.isSignedIn
        guard signedIn else { return }
        loading = true
        defer { loading = false }
        do {
            let account = try await app.account.me()
            me = account
            tokens = try await app.account.deviceTokens()
            if account.isAdmin {
                invitations = try await app.account.invitations()
                users = try await app.account.users()
            }
        } catch is AccountClient.SignInRequired {
            signedIn = false
            me = nil
        } catch {
            app.show(error)
        }
    }

    /// Runs a change, then reloads the screen; a lost session brings back the sign-in.
    private func run(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                await load()
            } catch is AccountClient.SignInRequired {
                signedIn = false
                me = nil
            } catch {
                app.show(error)
            }
        }
    }

    private func present<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

// MARK: - Sheets

enum SettingsSheet: Identifiable {
    case password
    case newToken
    case invite
    case secret(SecretInfo)

    var id: String {
        switch self {
        case .password: return "password"
        case .newToken: return "newToken"
        case .invite: return "invite"
        case .secret(let info): return "secret-" + info.value
        }
    }
}

/// A secret shown once: a new device token or an invitation link, with its QR.
struct SecretInfo {
    var title: String
    var note: String
    var value: String
    var qrPayload: String
    var shareText: String

    static func deviceToken(_ issued: IssuedDeviceToken, baseURL: String) -> SecretInfo {
        SecretInfo(title: "Токен «\(issued.device.name)»",
                   note: "Полный токен больше не будет показан. Отсканируй QR в приложении на другом телефоне или скопируй токен в поле «API token».",
                   value: issued.token,
                   qrPayload: ConnectLink.payload(baseURL: baseURL, token: issued.token),
                   shareText: issued.token)
    }

    static func invitation(_ created: CreatedInvitation) -> SecretInfo {
        SecretInfo(title: "Приглашение",
                   note: "Передай ссылку или покажи QR. По ссылке человек один раз придумывает имя и пароль — в браузере или в приложении musik.",
                   value: created.url,
                   qrPayload: created.url,
                   shareText: created.url)
    }
}

private struct SecretView: View {
    let info: SecretInfo
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text(info.note)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                QRCodeImage(payload: info.qrPayload)
                    .frame(maxWidth: 260)
                Text(info.value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = info.value
                        app.show("Скопировано")
                    } label: {
                        Label("Копировать", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChipButtonStyle(active: false))
                    Button {
                        sharing = true
                    } label: {
                        Label("Поделиться", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChipButtonStyle(active: true))
                }
            }
            .padding(20)
        }
        .background(Theme.backdrop)
        .navigationTitle(info.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
        }
        .sheet(isPresented: $sharing) {
            ActivityView(items: [info.shareText]).presentationDetents([.medium, .large])
        }
    }
}

private struct PasswordChangeView: View {
    let save: (String, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var again = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            SecureField("Текущий пароль", text: $current).textContentType(.password)
            SecureField("Новый пароль, не короче 8", text: $new).textContentType(.newPassword)
            SecureField("Новый пароль ещё раз", text: $again).textContentType(.newPassword)
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("Смена пароля")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Сохранить") {
                    guard new.count >= 8 else { error = "Новый пароль — не короче 8 символов"; return }
                    guard new == again else { error = "Пароли не совпадают"; return }
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await save(current, new)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .disabled(busy || current.isEmpty || new.isEmpty)
            }
        }
    }
}

private struct NewDeviceTokenView: View {
    let profiles: [ServerProfile]
    let create: (String, String) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var profileId = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            TextField("Имя устройства, например «Планшет»", text: $name)
            Picker("Профиль", selection: $profileId) {
                ForEach(profiles) { Text($0.isDefault == true ? "\($0.name) · основной" : $0.name).tag($0.id) }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("Новый токен")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if profileId.isEmpty { profileId = (profiles.first { $0.isDefault == true } ?? profiles.first)?.id ?? "" }
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Создать") {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await create(name.trimmingCharacters(in: .whitespaces), profileId)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty || profileId.isEmpty)
            }
        }
    }
}

private struct NewInvitationView: View {
    let create: (String, Int) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var hours = 24
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                TextField("Email (необязательно)", text: $email)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Stepper("Действует \(hours) ч", value: $hours, in: 1...168)
            } footer: {
                Text("С email приглашение примет только вход через OIDC с этим адресом; без email — любой, кто получит ссылку. Срок — от 1 часа до 7 дней.")
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        }
        .navigationTitle("Пригласить")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Создать") {
                    Task {
                        busy = true
                        defer { busy = false }
                        do {
                            try await create(email.trimmingCharacters(in: .whitespaces), hours)
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                .disabled(busy)
            }
        }
    }
}
