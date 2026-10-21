# Kindle Send for Mac

A native SwiftUI Mac app for sending free ebooks to your Kindle. Search
Project Gutenberg and Standard Ebooks, browse a cover grid, queue books, and
email them to your Kindle with Amazon's Send-to-Kindle email service.

<!-- TODO: screenshot -->

It is the GUI companion to the Python CLI in the repo root. It has no
third-party dependencies.

## Requirements

- macOS 15 or later
- Xcode 27
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```sh
cd mac && xcodegen generate && open KindleSend.xcodeproj
```

Then run the `KindleSend` scheme in Xcode.

## Tests

Run from the repository root (not `mac/`):

```sh
swift test --package-path mac/KindleSendKit
```

## First run

The app downloads both catalogs and builds a local search index. A progress
bar shows while it works, and it takes about 15 seconds. After that the index
refreshes in the background once a day, and on launch when it is stale.
Search is fully local and instant.

Books come from Project Gutenberg and Standard Ebooks. When a book exists in
both, the Standard Ebooks edition is preferred.

## Settings

Open Settings with **⌘,**.

- **Kindle address**: your `yourname_abc123@kindle.com` address, found in
  Amazon's *Manage Your Content and Devices* → *Preferences* →
  *Personal Document Settings*.
- **Provider**: iCloud Mail, Gmail, Fastmail, Yahoo Mail, or a custom SMTP
  server. Use an app password, not your normal account password.
- **Passwords** are stored in the macOS Keychain.
- **Test** checks the login without sending anything.
- If `~/.config/kindle-send/config.toml` exists (from the CLI), the app
  offers a one-time import.

## Amazon setup

Add the From address you send with to the **Approved Personal Document E-mail
List** (same Amazon page as above). Amazon silently drops mail from
unapproved senders, so the books would never arrive.

## Where books show up

Books arrive in your Kindle library under **Docs**, not **Books**. This is how
Amazon files everything sent by email, and no app can change it. On the
Kindle, set the library filter to **All**, or put the books in a collection.

## Developers

Check a login from the command line without sending anything. It reads the
CLI config:

```sh
swift run --package-path mac/KindleSendKit KindleSendSmoke verify
```
