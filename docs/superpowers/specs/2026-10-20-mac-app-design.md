# Kindle Send for Mac: design

_2026-10-20 · status: draft for approval_

## Intent

A native macOS app that turns "I want to read X" into "X is on my Kindle" with as little friction as
possible. It replaces the command-line `kindle_send.py` for everyday use: find free public-domain books
by typing, searching loosely or browsing, queue them up, press Send.

Ben is the first user. It is built so it can be open sourced and used by anyone: each person enters
their own Kindle address and their own sending email account. There is no server, no account and no
telemetry.

**What success feels like:** search is instant while you type, covers make browsing pleasant, and
sending a queue of books Just Works with clear feedback. **The main way to fail even if everything
technically works:** search that feels clunky or slow.

## Goals

- Instant, as-you-type search across Project Gutenberg and Standard Ebooks.
- Browse by category when you don't know what you want.
- A queue: add books from anywhere in the app, review the queue, send everything in one go.
- Real cover art everywhere.
- Credentials entered once in Settings, stored securely, with a way to test them without sending.
- Delivery behavior at parity with `kindle_send.py` for the providers it supports (see Sending).

## Non-goals (v1)

- Internet Archive / Open Library, Wikisource or other libraries. The source layer must make adding
  one later a contained change, but none ship in v1.
- Amazon SES and Resend providers (the CLI keeps supporting them). v1 is SMTP only.
- Local files and arbitrary URLs (the CLI covers these).
- Scheduled or automatic sending, reading-list import, iOS/iPadOS.
- A web or server version (considered and rejected: it would either hold strangers' email
  passwords or require running a shared sender).

## Anti-goals

- Slow or janky search. No search ever waits on the network.
- Storing passwords anywhere except the macOS Keychain.
- Silent failure. Every book in a send ends visibly as sent or failed with a reason.

## Decided (by Ben)

- **Native SwiftUI Mac app** (not a web app, not a wrapper around the Python script).
- **Main window = cover grid** ("option C" from the mockups): a search field in the toolbar, category
  chips under it, a grid of real cover images. Each cover has a ＋ button that becomes ✓ once queued.
- **Queue lives in a toolbar popover**: a "Queue" button with a count badge opens a popover listing
  queued books (cover thumbnail, title, author, ✕ to remove) and a "Send N to Kindle" button, with
  the destination Kindle address and provider shown underneath.
- **Sources: Project Gutenberg + Standard Ebooks.** When a book exists in both, show both editions
  but default to the Standard Ebooks one.
- **Catalog freshness:** refresh on launch if the local copy is more than a day old (and daily while
  the app stays open).

Mockup of the main window and queue popover:
`.superpowers/brainstorm/47384-1792544453/content/layout-c-v2.html`.

## How it works

### Search: local catalog index

Recon (2026-10-20) found that a live search would be slow and fragile: Gutenberg's own search page
takes ~0.2 s per request, the Gutendex API returned 403 to a plain client, and Standard Ebooks' OPDS
catalog requires a paid membership. So the app keeps **a local, searchable copy of both catalogs**:

- **Gutenberg:** `https://www.gutenberg.org/cache/epub/feeds/pg_catalog.csv.gz` (~5.6 MB, updated
  daily). Has ID, title, authors, language, subjects/bookshelves. Text-type entries only
  (skip audio etc.).
- **Standard Ebooks:** the public listing pages `https://standardebooks.org/ebooks?per-page=48&page=N`
  (~1,000 books over ~25 pages), plus each book's page as needed for download and cover URLs.
  Fetch politely (sequential, identifying User-Agent, only when the daily refresh is due).
- Index both into an on-device SQLite database with FTS5 over title and author (subjects as a lower
  weight). Search runs on every keystroke against the local index; target well under 50 ms.
- First launch: build the index with a visible progress bar. Afterward the existing index is always
  searchable while a refresh runs in the background and is swapped in when complete. If a refresh
  fails, keep the old index and retry next time; never block the UI.
- **Forgiving search (my call, from the "clunky search" anti-goal):** prefix/word matching alone is
  not enough. "pride predjudice" and "dostoyevsky" (catalog: Dostoevsky) must find the book. Use FTS5
  for exact/prefix hits plus a typo-tolerant fallback (e.g. an FTS5 trigram table or edit-distance
  re-rank) when exact hits are few. Benchmark against the 50 ms target on the full catalog.
- **Language (my call):** the index stores each book's language. Settings has a language filter that
  defaults to the Mac's system language (English for Ben), with an "All languages" option. Search and
  chips respect it.
- **Ranking:** text match first, then popularity (Gutenberg download counts come from the catalog or
  a separate source the builder picks; Standard Ebooks books get a boost since they're curated).

### Editions and matching

- A Gutenberg book and a Standard Ebooks book are the same work if normalized title + primary author
  match (lowercased, punctuation and leading articles stripped, diacritics folded). Done once at index
  time. Occasional misses are acceptable.
- A matched work shows **once** in the grid as the Standard Ebooks edition, with a small "2 editions"
  label. Opening it (click on the cover) lets you switch the edition before queuing.
- **Multiple Gutenberg editions (my call, extending Ben's "show both, default to nice"):** Gutenberg
  often has several IDs for one work (translations, illustrated editions, re-releases). All editions
  of a work collapse into **one tile** labeled "N editions". The default edition is Standard Ebooks if
  one exists, otherwise the most-downloaded Gutenberg edition. The data model therefore has a *work*
  that groups many *editions*. Different translations stay grouped but are labeled distinctly in the
  edition picker (translator/credits where the catalog has them).

### Browsing

- Category chips: **Popular** (default view on launch), then a fixed set such as Fiction, Science
  Fiction, Mystery, Philosophy, History, Poetry, Children's. Map each chip to Gutenberg
  bookshelves/subjects and Standard Ebooks subjects.
- Search text and a chip can combine (search within a category).

### Covers

- Gutenberg: `https://www.gutenberg.org/cache/epub/{id}/pg{id}.cover.medium.jpg` (verified working).
- Standard Ebooks: the cover image from its listing/book page.
- Load lazily as tiles scroll into view; cache on disk; show a tasteful placeholder (title on a
  colored card) when a cover is missing.

### Queue

- Add/remove from the grid (＋/✓) or the popover (✕). Persists across app launches.
- Books already sent show a "Sent" indicator on their cover (from send history). Re-queuing a sent
  book is allowed after confirmation.

### Sending (parity with `kindle_send.py`)

Pressing Send runs the whole queue and the popover shows per-book progress (downloading → sending →
sent, or failed with a reason). Behavior to carry over from the Python script:

- Gutenberg download URL: `/ebooks/{id}.epub3.images`; if the encoded size exceeds the provider's cap,
  fall back to `/ebooks/{id}.epub.noimages`. Standard Ebooks: its compatible EPUB.
- Batch attachments into emails by encoded (base64) size under the provider cap and at most 25
  attachments per email.
- Record each sent book (ID, date) in a local history; successful books leave the queue, failed ones
  stay with their error so you can retry.
- Providers and caps: Gmail `smtp.gmail.com:465` (25 MB), iCloud `smtp.mail.me.com:587` STARTTLS
  (20 MB), Fastmail `smtp.fastmail.com:465` (50 MB), Yahoo `smtp.mail.yahoo.com:465` (25 MB), and a
  custom SMTP server (host, port 465 SSL or 587 STARTTLS, user; 50 MB cap). STARTTLS support is
  required because iCloud only offers port 587.

### Settings (⌘,)

- Kindle address (validated as `…@kindle.com`), provider picker, user/password/optional From address,
  custom SMTP fields when relevant.
- Passwords in the macOS Keychain; everything else in app preferences.
- **Test** button: logs in to the SMTP server without sending (same as `kindle_send.py check`).
- Inline guidance, with links: how to find the Kindle address, how to make an app password for the
  chosen provider, and a prominent reminder to add the From address to Amazon's approved sender list
  (Amazon drops unapproved mail without any error).
- **CLI import (my call):** if `~/.config/kindle-send/config.toml` exists on first launch, offer a
  one-time import of the Kindle address and default SMTP provider (password moved into the Keychain;
  the CLI file is left untouched). Send history is **not** shared: the CLI's `sent.json` keys entries
  by whatever text was typed, so the app keeps its own history keyed by edition.
- On first launch with no settings, the app opens Settings (or a short onboarding sheet) before the
  first send, but browsing and queuing work without settings.

## Builder's calls

- Project layout: a new Xcode project in this repo (`mac/`), alongside the existing Python CLI, which
  stays as is. One open source repo, one README covering both.
- Minimum macOS version, SwiftUI architecture, persistence choice (SwiftData vs plain files) for the
  queue and history.
- SMTP implementation: Foundation has no SMTP client. Options include a small client over
  Network.framework (needs a STARTTLS upgrade path) or a maintained Swift package. Prefer the fewest
  dependencies that handle both implicit TLS and STARTTLS correctly.
- Source of Gutenberg popularity numbers, exact category mapping, visual polish, app icon.
- Distribution (signed/notarized build on GitHub Releases, Homebrew cask later) is out of scope for
  the first working version but shouldn't be made hard.
