import Foundation
import KindleSendKit
import Observation
import os

enum AppModelError: LocalizedError {
    case incompleteAccount, missingPassword, invalidKindleAddress, missingUser

    var errorDescription: String? {
        switch self {
        case .incompleteAccount: "Fill in the email account in Settings first."
        case .missingPassword: "Enter the app password in Settings first."
        case .invalidKindleAddress: "Enter your Kindle address (…@kindle.com) in Settings first."
        case .missingUser: "Enter the email user before the password."
        }
    }
}

/// App-wide state: settings, the local catalog index, the queue and sending.
@MainActor @Observable final class AppModel {
    nonisolated private static let logger = Logger(subsystem: "com.by32.KindleSend", category: "app")
    private static let cliImportOfferedKey = "cliImportOffered"
    /// How often to check whether the index has gone stale while the app runs.
    private static let staleCheckInterval: Duration = .seconds(60 * 60)

    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save(to: defaults)
            if settings.language != oldValue.language { updateSearch() }
        }
    }
    var query = SearchQuery(text: "", category: .popular, language: nil)
    var results: [Work] = []
    var indexPhase: CatalogUpdater.Phase = .idle
    private(set) var hasIndex = false

    let queue: QueueStore
    let history: SendHistory
    /// Cover images, cached under the data directory.
    @ObservationIgnored let covers: CoverCache
    private(set) var sendProgress = SendProgress()
    var sendEvents: [String: SendEvent] { sendProgress.status }
    private(set) var isSending = false
    /// Why the last send could not start (settings or password missing); nil once a send starts.
    private(set) var sendError: String?

    /// True while the one-time "Import settings from kindle-send?" alert should show.
    var isOfferingCLIImport = false
    /// Set when an accepted CLI import could not be completed.
    var cliImportError: String?
    /// Bumped by each completed import so an open Settings window reloads its drafts.
    private(set) var importCount = 0

    /// Disk-write failures for the queue or history, for a non-modal warning in the window.
    var saveWarning: String? {
        if let e = queue.lastSaveError { return "Couldn't save the queue: \(e)" }
        if let e = history.lastSaveError { return "Couldn't save the send history: \(e)" }
        return nil
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore
    @ObservationIgnored private let cliConfigURL: URL
    @ObservationIgnored private let http = URLSessionHTTPClient()
    @ObservationIgnored private let databaseURL: URL
    @ObservationIgnored private let updater: CatalogUpdater
    @ObservationIgnored private var database: CatalogDatabase?
    @ObservationIgnored private var searchToken = 0
    @ObservationIgnored private var launched = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var staleCheckTask: Task<Void, Never>?

    /// In Debug builds, `KINDLESEND_DATA_DIR` (and optionally `KINDLESEND_DEFAULTS_SUITE`) switch the
    /// data directory, preferences, Keychain service and CLI config path to test copies; see
    /// `AppEnvironment`. Release builds ignore the environment and always use the real locations.
    init() {
        #if DEBUG
        let env = AppEnvironment(environment: ProcessInfo.processInfo.environment)
        #else
        let env = AppEnvironment(environment: [:])
        #endif
        let dataDir = env.dataDirectory
        defaults = env.defaultsSuite.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        keychain = KeychainStore(service: env.keychainService)
        cliConfigURL = env.cliConfigURL
        settings = AppSettings.load(from: defaults)
        databaseURL = dataDir.appendingPathComponent("catalog.sqlite")
        updater = CatalogUpdater(http: http, databaseURL: databaseURL)
        queue = QueueStore(fileURL: dataDir.appendingPathComponent("queue.json"))
        history = SendHistory(fileURL: dataDir.appendingPathComponent("history.json"))
        covers = CoverCache(dataDirectory: dataDir, http: URLSessionHTTPClient())
    }

    // MARK: - Launch and the index lifecycle

    /// Opens the index if present, offers the CLI import, refreshes when stale and keeps checking.
    /// Safe to call more than once; only the first call does anything.
    func onLaunch() async {
        guard !launched else { return }
        launched = true
        openDatabase()
        updateSearch()
        offerCLIImportIfNeeded()
        staleCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.staleCheckInterval)
                guard let self, !Task.isCancelled else { return }
                if self.isIndexStale { await self.refreshIndex() }
            }
        }
        if isIndexStale { await refreshIndex() }
    }

    private var isIndexStale: Bool {
        updater.isStale(builtAt: database?.builtAt, schemaVersion: database?.storedSchemaVersion)
    }

    /// Rebuilds the index; on success swaps it in and re-runs the current search. A failure keeps
    /// the old index and leaves `indexPhase` at `.failed`. The work runs in a task this model owns,
    /// so a cancelled caller (a closing window) does not cancel the refresh.
    func refreshIndex() async {
        if let refreshTask { return await refreshTask.value }
        let task = Task {
            await self.runRefresh()
            self.refreshTask = nil
        }
        refreshTask = task
        await task.value
    }

    private func runRefresh() async {
        let (phases, continuation) = AsyncStream.makeStream(of: CatalogUpdater.Phase.self)
        let reporter = Task { for await phase in phases { self.indexPhase = phase } }
        do {
            try await updater.refresh { continuation.yield($0) }
            continuation.finish()
            await reporter.value
            database?.close()
            database = nil
            openDatabase()
            updateSearch()
        } catch {
            continuation.finish()
            await reporter.value
            if Self.isCancellation(error) || error as? CatalogUpdaterError == .refreshInProgress {
                // Not a failure: no error UI.
                indexPhase = .idle
            } else {
                Self.logger.error("Catalog refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func openDatabase() {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            hasIndex = false
            return
        }
        do {
            database = try CatalogDatabase(url: databaseURL)
        } catch {
            Self.logger.error("Opening the catalog failed: \(error.localizedDescription, privacy: .public)")
            database = nil
        }
        hasIndex = database != nil
    }

    // MARK: - Search

    /// Runs the current query against the local index off the main actor; results from a query
    /// that has since been superseded are dropped.
    func updateSearch() {
        searchToken += 1
        let token = searchToken
        guard let database else {
            results = []
            return
        }
        var q = query
        q.language = settings.language
        Task.detached(priority: .userInitiated) {
            let found: [Work]?
            do {
                found = try database.search(q)
            } catch CatalogDatabaseError.closed {
                // The index was swapped mid-search; the swap re-runs the query.
                found = nil
            } catch {
                Self.logger.error("Search failed: \(error.localizedDescription, privacy: .public)")
                found = nil
            }
            await self.publish(found, token: token)
        }
    }

    private func publish(_ found: [Work]?, token: Int) {
        guard token == searchToken, let found else { return }
        results = found
    }

    // MARK: - Account

    func storedPassword() -> String? {
        guard !settings.user.isEmpty else { return nil }
        return try? keychain.password(for: settings.user)
    }

    /// Stores the app password for the current user; an empty password removes it.
    func savePassword(_ p: String) throws {
        guard !settings.user.isEmpty else { throw AppModelError.missingUser }
        if p.isEmpty {
            try keychain.delete(account: settings.user)
        } else {
            try keychain.setPassword(p, for: settings.user)
        }
    }

    /// Logs in to the SMTP server without sending anything.
    func testLogin() async -> Result<Void, Error> {
        do {
            let (account, password) = try credentials()
            try await SMTPClient(account: account, password: password).verifyLogin()
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func credentials() throws -> (SMTPAccount, String) {
        guard let account = settings.account else { throw AppModelError.incompleteAccount }
        guard let password = try keychain.password(for: account.user), !password.isEmpty else {
            throw AppModelError.missingPassword
        }
        return (account, password)
    }

    // MARK: - Sending

    /// Sends every queued book. Single-flight: a call while a send runs does nothing. The stream is
    /// consumed by one task this model owns, so leaving a view does not cancel the send.
    func sendQueue() async {
        guard !isSending else { return }
        let account: SMTPAccount, password: String
        do {
            guard settings.isValidKindleEmail else { throw AppModelError.invalidKindleAddress }
            (account, password) = try credentials()
        } catch {
            sendError = error.localizedDescription
            return
        }
        sendError = nil
        let items = queue.items
        guard !items.isEmpty else { return }

        isSending = true
        sendProgress = SendProgress()
        for item in items where item.lastError != nil { queue.setError(nil, for: item.id) }
        let job = SendJob(downloader: EditionDownloader(http: http),
                          mailer: SMTPClient(account: account, password: password),
                          from: account.from, to: settings.kindleEmail, maxBytes: account.maxBytes)
        let task = Task {
            for await event in job.run(items.map(\.edition)) {
                self.sendProgress.apply(event, queue: self.queue, history: self.history, at: .now)
            }
            self.isSending = false
        }
        await task.value
    }

    // MARK: - CLI import

    private func offerCLIImportIfNeeded() {
        guard !defaults.bool(forKey: Self.cliImportOfferedKey),
              FileManager.default.fileExists(atPath: cliConfigURL.path) else { return }
        isOfferingCLIImport = true
    }

    /// Copies the CLI's Kindle address and SMTP account into settings and its password into the Keychain.
    func importCLIConfig() {
        defaults.set(true, forKey: Self.cliImportOfferedKey)
        guard let imported = CLIConfigImporter.load(from: cliConfigURL) else {
            cliImportError = "Couldn't read \(cliConfigURL.path)."
            return
        }
        settings = imported.applied(to: settings)
        importCount += 1
        guard let password = imported.password, !password.isEmpty else { return }
        do {
            try savePassword(password)
        } catch {
            cliImportError = "Imported the settings, but couldn't save the password: \(error.localizedDescription)"
        }
    }

    func declineCLIImport() {
        defaults.set(true, forKey: Self.cliImportOfferedKey)
    }
}
