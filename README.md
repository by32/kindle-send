# kindle-send

Send free, open-format ebooks (Project Gutenberg, Standard Ebooks, any EPUB/PDF URL, or local files)
to your Kindle in one command, using Amazon's Send-to-Kindle email service.
Needs only Python 3.11+, with no extra packages.

## One-time setup

1. **Find your Kindle address**: amazon.com → *Manage Your Content and Devices* → *Preferences* →
   *Personal Document Settings*. It looks like `yourname_abc123@kindle.com`.
2. **Approve your sending address** on the same page, under *Approved Personal Document E-mail List*.
3. **Get an SMTP password.** For Gmail, turn on 2-step verification, then create an App Password at
   https://myaccount.google.com/apppasswords. Your normal password won't work.
4. Run `./kindle_send.py init`. It writes `~/.config/kindle-send/config.toml` with mode 600.
   You can use env vars instead: `KINDLE_SEND_KINDLE_EMAIL`, `KINDLE_SEND_SMTP_USER`,
   `KINDLE_SEND_SMTP_PASSWORD`, `KINDLE_SEND_SMTP_HOST`, `KINDLE_SEND_SMTP_PORT`.

## Usage

```sh
./kindle_send.py search "jane austen"           # browse Gutenberg
./kindle_send.py send 1342                       # by Gutenberg ID
./kindle_send.py send "moby dick"                # search, then pick from a numbered list
./kindle_send.py send "moby dick" -y             # take the top hit
./kindle_send.py send https://example.org/book.epub ~/Downloads/paper.pdf
./kindle_send.py send -f reading-list.txt -y     # a whole reading list
./kindle_send.py send 1342 --dry-run --out ./books   # download only
```

Options: `--no-images` gives smaller Gutenberg files. `--force` resends something already sent;
sent items are tracked in `~/.local/state/kindle-send/sent.json` so reading lists can be re-run safely.

## Notes

- Accepted formats: EPUB, PDF, TXT, DOC/DOCX, RTF, HTML. MOBI/AZW3 are no longer accepted by Amazon.
- Amazon limits each email to 50 MB and 25 attachments. The tool batches files automatically, and if a
  Gutenberg book with images is too large it falls back to the version without images.
- To run on a schedule (e.g. a nightly reading-list drop), use cron:
  `0 21 * * * /path/to/kindle_send.py send -f ~/reading-list.txt -y`
