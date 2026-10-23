import KindleSendKit
import SwiftUI

/// The Settings window (⌘,). Text fields edit drafts that are trimmed and committed on Return or
/// when focus leaves them; the password is committed to the Keychain the same way.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private enum Field: Hashable { case kindle, user, password, from }
    private enum TestState: Equatable { case idle, testing, ok, failed(String) }

    @FocusState private var focus: Field?
    @State private var kindleDraft = ""
    @State private var userDraft = ""
    @State private var passwordDraft = ""
    @State private var fromDraft = ""
    @State private var passwordError: String?
    @State private var test = TestState.idle

    private static let mycdURL = URL(string: "https://www.amazon.com/mycd")!
    private static let languageCodes = ["en", "fr", "de", "es", "it", "pt", "nl", "fi", "sv", "la", "el", "ru", "zh", "ja"]

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Kindle") {
                TextField("Kindle address", text: $kindleDraft, prompt: Text("name@kindle.com"))
                    .focused($focus, equals: .kindle)
                    .onSubmit(commitKindle)
                if !kindleDraft.trimmed.isEmpty && !isKindleDraftValid {
                    Text("A Kindle address ends in @kindle.com.")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Link("Find your Kindle address", destination: Self.mycdURL)
            }

            Section("Email account") {
                Picker("Provider", selection: $model.settings.provider) {
                    ForEach(Provider.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: model.settings.provider) { _, provider in
                    if provider == .custom && model.settings.customPort == nil { model.settings.customPort = AppSettings.defaultCustomPort }
                    test = .idle
                }
                if model.settings.provider == .custom {
                    TextField("SMTP server", text: customHost, prompt: Text("smtp.example.com"))
                    TextField("Port", value: customPort, format: .number.grouping(.never),
                              prompt: Text("465 (TLS) or 587 (STARTTLS)"))
                }
                TextField("User", text: $userDraft, prompt: Text("you@example.com"))
                    .focused($focus, equals: .user)
                    .onSubmit(commitUser)
                SecureField("App password", text: $passwordDraft)
                    .focused($focus, equals: .password)
                    .onSubmit(commitPassword)
                if let passwordError {
                    Text(passwordError).font(.callout).foregroundStyle(.red)
                }
                TextField("From (optional)", text: $fromDraft, prompt: Text("Same as user"))
                    .focused($focus, equals: .from)
                    .onSubmit(commitFrom)
                if let help = model.settings.provider.appPasswordHelpURL {
                    Link("Create an app password for \(model.settings.provider.displayName)", destination: help)
                }
                HStack {
                    Button("Test", action: runTest)
                        .disabled(test == .testing)
                    testResult
                }
            }

            Section("Books") {
                Picker("Language", selection: $model.settings.language) {
                    ForEach(languageOptions, id: \.self) { code in
                        Text(languageName(code)).tag(Optional(code))
                    }
                    Divider()
                    Text("All languages").tag(String?.none)
                }
            }

            Section {
                Label {
                    Text("Add \(effectiveFrom) to Amazon's Approved Personal Document E-mail List, or Amazon will silently drop your books.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear(perform: loadDrafts)
        .onChange(of: model.importCount) { loadDrafts() }
        .onChange(of: model.settings.kindleEmail) { _, new in kindleDraft = new }
        .onChange(of: model.settings.user) { _, new in
            userDraft = new
            // The password belongs to the account: show the new user's if one is stored, else keep
            // what was typed so it can be saved for this user.
            if let stored = model.storedPassword() { passwordDraft = stored }
        }
        .onChange(of: focus) { old, _ in commit(old) }
        .onDisappear { commit(focus) }
    }

    @ViewBuilder private var testResult: some View {
        switch test {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .ok:
            Label("Login OK", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case let .failed(message):
            Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
        }
    }

    // MARK: - Derived values

    private var isKindleDraftValid: Bool {
        AppSettings(kindleEmail: kindleDraft.trimmed).isValidKindleEmail
    }

    private var effectiveFrom: String {
        let from = fromDraft.trimmed.isEmpty ? userDraft.trimmed : fromDraft.trimmed
        return from.isEmpty ? "your sending address" : from
    }

    private var customHost: Binding<String> {
        Binding(get: { model.settings.customHost ?? "" },
                set: { model.settings.customHost = $0.trimmed.isEmpty ? nil : $0.trimmed })
    }

    private var customPort: Binding<Int> {
        Binding(get: { model.settings.customPort ?? AppSettings.defaultCustomPort }, set: { model.settings.customPort = $0 })
    }

    /// The fixed list, with the Mac's language added when it is not on it.
    private var languageOptions: [String] {
        let system = Locale.current.language.languageCode?.identifier
        guard let system, !Self.languageCodes.contains(system) else { return Self.languageCodes }
        return [system] + Self.languageCodes
    }

    private func languageName(_ code: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return code == Locale.current.language.languageCode?.identifier ? "\(name) (system default)" : name
    }

    // MARK: - Commits

    private func loadDrafts() {
        kindleDraft = model.settings.kindleEmail
        userDraft = model.settings.user
        fromDraft = model.settings.from ?? ""
        passwordDraft = model.storedPassword() ?? ""
    }

    private func commit(_ field: Field?) {
        switch field {
        case .kindle: commitKindle()
        case .user: commitUser()
        case .password: commitPassword()
        case .from: commitFrom()
        case nil: break
        }
    }

    private func commitKindle() {
        kindleDraft = kindleDraft.trimmed
        model.settings.kindleEmail = kindleDraft
    }

    private func commitUser() {
        userDraft = userDraft.trimmed
        guard userDraft != model.settings.user else { return }
        model.settings.user = userDraft
        test = .idle
        passwordError = nil
    }

    private func commitPassword() {
        guard passwordDraft != (model.storedPassword() ?? "") else { return }
        do {
            try model.savePassword(passwordDraft)
            passwordError = nil
            test = .idle
        } catch {
            passwordError = error.localizedDescription
        }
    }

    private func commitFrom() {
        fromDraft = fromDraft.trimmed
        model.settings.from = fromDraft.isEmpty ? nil : fromDraft
    }

    private func runTest() {
        commitKindle()
        commitUser()
        commitPassword()
        commitFrom()
        test = .testing
        Task {
            switch await model.testLogin() {
            case .success: test = .ok
            case let .failure(error): test = .failed(error.localizedDescription)
            }
        }
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
