import Foundation
import KindleSendKit

// Manual live check: `swift run KindleSendSmoke verify` logs in with the CLI config's credentials.
guard CommandLine.arguments.dropFirst().first == "verify" else {
    FileHandle.standardError.write(Data("usage: KindleSendSmoke verify\n".utf8))
    exit(2)
}
guard let imported = CLIConfigImporter.load(), let account = imported.settings.account,
      let password = imported.password, !password.isEmpty else {
    print("Could not read a usable SMTP account from \(CLIConfigImporter.defaultURL.path)")
    exit(1)
}
do {
    try await SMTPClient(account: account, password: password).verifyLogin()
    let mode = account.security == .implicitTLS ? "implicit TLS" : "STARTTLS"
    print("Login OK (\(account.host):\(account.port), \(mode))")
} catch {
    print(error.localizedDescription)
    exit(1)
}
