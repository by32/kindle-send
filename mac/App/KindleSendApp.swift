import KindleSendKit
import SwiftUI

@main
struct KindleSendApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.onLaunch() }
        }
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The main window: index progress until the first index exists, then browsing.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            if model.hasIndex {
                BrowseView()
            } else {
                IndexProgressView()
            }
            if let warning = model.saveWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.bar)
            }
        }
        .frame(minWidth: 640, minHeight: 440)
        .alert("Import settings from kindle-send?", isPresented: $model.isOfferingCLIImport) {
            Button("Import") { model.importCLIConfig() }
            Button("Not now", role: .cancel) { model.declineCLIImport() }
        } message: {
            Text("Copies your Kindle address and email account from the kindle-send command-line tool. The password is stored in your Keychain; the CLI's config file is left untouched.")
        }
        .alert("Import incomplete", isPresented: Binding(
            get: { model.cliImportError != nil }, set: { if !$0 { model.cliImportError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.cliImportError ?? "")
        }
    }
}

/// Placeholder until Task 12 builds the real browser.
struct BrowseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading) {
            TextField("Search books", text: $model.query.text)
                .textFieldStyle(.roundedBorder)
                .onChange(of: model.query.text) { model.updateSearch() }
            List(model.results) { work in
                VStack(alignment: .leading) {
                    Text(work.defaultEdition.title)
                    Text(work.defaultEdition.authors.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }
}
