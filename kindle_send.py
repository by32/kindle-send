#!/usr/bin/env python3
"""kindle-send: fetch open-format ebooks and deliver them to a Kindle via Send-to-Kindle email.

Sources:
  - Project Gutenberg, by ID ("1342"), search query ("pride and prejudice") or book URL
  - Any direct URL to an EPUB / PDF / TXT / HTML / DOCX / RTF file (Standard Ebooks, etc.)
  - Local files

Only the Python standard library is used (Python 3.11+).
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import smtplib
import ssl
import sys
import tempfile
import tomllib
from datetime import date
import urllib.parse
import urllib.request
from dataclasses import dataclass
from email.message import EmailMessage
from pathlib import Path

USER_AGENT = "kindle-send/1.0 (+personal use)"
GUTENDEX = "https://gutendex.com/books/"
GUTENBERG = "https://www.gutenberg.org"

# Formats Amazon's Send-to-Kindle email service accepts.
SUPPORTED_EXT = {".epub", ".pdf", ".txt", ".doc", ".docx", ".rtf", ".htm", ".html"}
MAX_EMAIL_BYTES = 50 * 1024 * 1024  # Amazon's per-email limit

CONFIG_PATH = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "kindle-send" / "config.toml"
HISTORY_PATH = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "kindle-send" / "sent.json"


# --------------------------------------------------------------------------- config

@dataclass
class Config:
    kindle_email: str
    from_addr: str
    smtp_host: str
    smtp_port: int
    smtp_user: str
    smtp_password: str

    @classmethod
    def load(cls, path: Path = CONFIG_PATH) -> "Config":
        data: dict = {}
        if path.exists():
            with path.open("rb") as f:
                data = tomllib.load(f)

        def get(key: str, default=None):
            return os.environ.get(f"KINDLE_SEND_{key.upper()}", data.get(key, default))

        missing = [k for k in ("kindle_email", "smtp_user", "smtp_password") if not get(k)]
        if missing:
            sys.exit(
                f"Missing config: {', '.join(missing)}.\n"
                f"Run `kindle_send.py init` or set KINDLE_SEND_<KEY> env vars (config file: {path})."
            )
        return cls(
            kindle_email=get("kindle_email"),
            from_addr=get("from_addr") or get("smtp_user"),
            smtp_host=get("smtp_host", "smtp.gmail.com"),
            smtp_port=int(get("smtp_port", 465)),
            smtp_user=get("smtp_user"),
            smtp_password=get("smtp_password"),
        )


def cmd_init(_args) -> None:
    print(f"Writing config to {CONFIG_PATH}\n")
    kindle = input("Your Send-to-Kindle address (…@kindle.com): ").strip()
    user = input("Sending email address (must be on Amazon's approved list): ").strip()
    host = input("SMTP host [smtp.gmail.com]: ").strip() or "smtp.gmail.com"
    port = input("SMTP port (465 = SSL, 587 = STARTTLS) [465]: ").strip() or "465"
    print("SMTP password — for Gmail, use an App Password (https://myaccount.google.com/apppasswords).")
    print("Leave blank to supply it via the KINDLE_SEND_SMTP_PASSWORD env var instead.")
    import getpass
    pw = getpass.getpass("SMTP password: ")

    lines = [
        f'kindle_email = "{kindle}"',
        f'smtp_user = "{user}"',
        f'smtp_host = "{host}"',
        f"smtp_port = {int(port)}",
    ]
    if pw:
        lines.append(f'smtp_password = "{pw}"')
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text("\n".join(lines) + "\n")
    CONFIG_PATH.chmod(0o600)
    print(f"\nSaved. Remember to add {user} to Amazon's Approved Personal Document E-mail List:")
    print("  amazon.com → Manage Your Content and Devices → Preferences → Personal Document Settings")


# --------------------------------------------------------------------------- http

def http_get(url: str, timeout: int = 60) -> urllib.request.addinfourl:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    return urllib.request.urlopen(req, timeout=timeout)


def download(url: str, dest_dir: Path, filename: str | None = None) -> Path:
    with http_get(url) as resp:
        if not filename:
            cd = resp.headers.get("Content-Disposition", "")
            m = re.search(r'filename="?([^";]+)"?', cd)
            filename = m.group(1) if m else Path(urllib.parse.urlparse(resp.url).path).name
        if not Path(filename).suffix:
            ext = mimetypes.guess_extension(resp.headers.get_content_type()) or ""
            filename += ext
        path = dest_dir / filename
        with path.open("wb") as f:
            while chunk := resp.read(1 << 16):
                f.write(chunk)
    return path


# --------------------------------------------------------------------------- gutenberg

@dataclass
class Book:
    id: int
    title: str
    authors: str
    downloads: int = 0

    @classmethod
    def from_gutendex(cls, d: dict) -> "Book":
        authors = "; ".join(a["name"] for a in d.get("authors", [])) or "Unknown"
        return cls(d["id"], d["title"], authors, d.get("download_count", 0))

    def filename(self, ext: str = ".epub") -> str:
        author = self.authors.split(";")[0].split(",")[0].strip()
        stem = f"{self.title} - {author}" if author != "Unknown" else self.title
        stem = re.sub(r'[\\/:*?"<>|\r\n]+', " ", stem)
        return re.sub(r"\s+", " ", stem).strip()[:120] + ext


def gutenberg_search(query: str, limit: int = 10, language: str | None = None) -> list[Book]:
    params = {"search": query}
    if language:
        params["languages"] = language
    with http_get(f"{GUTENDEX}?{urllib.parse.urlencode(params)}", timeout=90) as resp:
        results = json.load(resp)["results"]
    return [Book.from_gutendex(r) for r in results[:limit]]


def gutenberg_book(book_id: int) -> Book:
    try:
        with http_get(f"{GUTENDEX}{book_id}", timeout=60) as resp:
            return Book.from_gutendex(json.load(resp))
    except Exception:
        # Gutendex can be slow/unavailable; the download still works without metadata.
        return Book(book_id, f"Gutenberg {book_id}", "Unknown")


def gutenberg_epub_url(book_id: int, images: bool = True) -> str:
    # Gutenberg has no EPUB3 without images, so fall back to the plain EPUB2 build.
    return f"{GUTENBERG}/ebooks/{book_id}." + ("epub3.images" if images else "epub.noimages")


GUTENBERG_URL_RE = re.compile(r"gutenberg\.org/(?:ebooks|cache/epub|files)/(\d+)")


# --------------------------------------------------------------------------- resolve

def resolve(item: str, workdir: Path, images: bool, pick_first: bool) -> Path | None:
    """Turn a CLI argument into a local file ready to send."""
    p = Path(item).expanduser()
    if p.is_file():
        return p

    if item.isdigit():
        return fetch_gutenberg(int(item), workdir, images)

    if m := GUTENBERG_URL_RE.search(item):
        return fetch_gutenberg(int(m.group(1)), workdir, images)

    if re.match(r"https?://", item):
        print(f"Downloading {item}")
        return download(item, workdir)

    # Otherwise treat it as a Gutenberg search.
    books = gutenberg_search(item, limit=8)
    if not books:
        print(f"No Gutenberg results for {item!r}", file=sys.stderr)
        return None
    if pick_first or len(books) == 1:
        choice = books[0]
    else:
        print(f"\nResults for {item!r}:")
        for i, b in enumerate(books, 1):
            print(f"  {i}. {b.title} — {b.authors}  [#{b.id}]")
        ans = input("Pick a number (blank to skip): ").strip()
        if not ans.isdigit() or not 1 <= int(ans) <= len(books):
            return None
        choice = books[int(ans) - 1]
    return fetch_gutenberg(choice.id, workdir, images, choice)


def fetch_gutenberg(book_id: int, workdir: Path, images: bool, book: Book | None = None) -> Path:
    book = book or gutenberg_book(book_id)
    print(f"Downloading Gutenberg #{book.id}: {book.title} — {book.authors}")
    path = download(gutenberg_epub_url(book.id, images), workdir, book.filename())
    if images and path.stat().st_size > MAX_EMAIL_BYTES:
        print("  Too large for email with images; retrying without images.")
        path.unlink()
        path = download(gutenberg_epub_url(book.id, False), workdir, book.filename())
    return path


# --------------------------------------------------------------------------- send

def build_message(cfg: Config, files: list[Path]) -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = cfg.from_addr
    msg["To"] = cfg.kindle_email
    msg["Subject"] = "kindle-send: " + ", ".join(f.stem for f in files)[:200]
    msg.set_content("Sent by kindle-send.")
    for f in files:
        ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
        if f.suffix.lower() == ".epub":
            ctype = "application/epub+zip"
        maintype, subtype = ctype.split("/", 1)
        msg.add_attachment(f.read_bytes(), maintype=maintype, subtype=subtype, filename=f.name)
    return msg


def send_email(cfg: Config, msg: EmailMessage) -> None:
    ctx = ssl.create_default_context()
    if cfg.smtp_port == 465:
        with smtplib.SMTP_SSL(cfg.smtp_host, cfg.smtp_port, context=ctx) as s:
            s.login(cfg.smtp_user, cfg.smtp_password)
            s.send_message(msg)
    else:
        with smtplib.SMTP(cfg.smtp_host, cfg.smtp_port) as s:
            s.starttls(context=ctx)
            s.login(cfg.smtp_user, cfg.smtp_password)
            s.send_message(msg)


def batch_by_size(files: list[Path], limit: int = MAX_EMAIL_BYTES, max_count: int = 25) -> list[list[Path]]:
    # Base64 inflates attachments by ~4/3.
    batches, cur, cur_size = [], [], 0
    for f in files:
        size = f.stat().st_size * 4 // 3
        if cur and (cur_size + size > limit or len(cur) >= max_count):
            batches.append(cur)
            cur, cur_size = [], 0
        cur.append(f)
        cur_size += size
    if cur:
        batches.append(cur)
    return batches


def load_history() -> dict:
    try:
        return json.loads(HISTORY_PATH.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save_history(history: dict) -> None:
    HISTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    HISTORY_PATH.write_text(json.dumps(history, indent=2))


def cmd_send(args) -> None:
    items = list(args.items)
    if args.file:
        items += [
            line.strip() for line in Path(args.file).read_text().splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]
    if not items:
        sys.exit("Nothing to send.")

    cfg = None if args.dry_run else Config.load()
    history = load_history()
    out_dir = Path(args.out).expanduser() if args.out else None
    if out_dir:
        out_dir.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as tmp:
        workdir = out_dir or Path(tmp)
        files: list[Path] = []
        sources: dict[Path, str] = {}
        for item in items:
            if item in history and not args.force:
                print(f"Skipping {item!r} (already sent {history[item]}; use --force to resend)")
                continue
            try:
                path = resolve(item, workdir, images=not args.no_images, pick_first=args.yes)
            except Exception as e:  # keep going with the rest of the list
                print(f"  Failed: {item!r}: {e}", file=sys.stderr)
                continue
            if not path:
                continue
            if path.suffix.lower() not in SUPPORTED_EXT:
                print(f"  Skipping {path.name}: Send-to-Kindle doesn't accept {path.suffix or 'this type'}", file=sys.stderr)
                continue
            if path.stat().st_size * 4 // 3 > MAX_EMAIL_BYTES:
                print(f"  Skipping {path.name}: over Amazon's 50 MB email limit", file=sys.stderr)
                continue
            print(f"  → {path.name} ({path.stat().st_size / 1e6:.1f} MB)")
            files.append(path)
            sources[path] = item

        if not files:
            print("No files to send.")
            return
        if args.dry_run:
            print(f"\nDry run: {len(files)} file(s) ready" + (f" in {workdir}" if out_dir else "") + ", nothing emailed.")
            return

        for batch in batch_by_size(files):
            print(f"\nEmailing {len(batch)} file(s) to {cfg.kindle_email} …")
            send_email(cfg, build_message(cfg, batch))
            for f in batch:
                history[sources[f]] = date.today().isoformat()
            save_history(history)
        print("Done. Books usually appear on your Kindle within a few minutes.")


def cmd_search(args) -> None:
    books = gutenberg_search(args.query, limit=args.limit, language=args.lang)
    if not books:
        print("No results.")
    for b in books:
        print(f"#{b.id:<6} {b.title} — {b.authors}  ({b.downloads:,} downloads)")


# --------------------------------------------------------------------------- main

def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="kindle_send", description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init", help="interactively write the config file").set_defaults(func=cmd_init)

    s = sub.add_parser("search", help="search Project Gutenberg")
    s.add_argument("query")
    s.add_argument("-n", "--limit", type=int, default=10)
    s.add_argument("--lang", help="language code filter, e.g. en, fr")
    s.set_defaults(func=cmd_search)

    p = sub.add_parser("send", help="fetch and email books to your Kindle")
    p.add_argument("items", nargs="*", help="Gutenberg ID, Gutenberg/other URL, local file, or search text")
    p.add_argument("-f", "--file", help="reading-list file, one item per line (# for comments)")
    p.add_argument("-y", "--yes", action="store_true", help="take the top search result without asking")
    p.add_argument("--no-images", action="store_true", help="smaller Gutenberg EPUBs without illustrations")
    p.add_argument("--out", help="keep downloaded files in this directory")
    p.add_argument("--dry-run", action="store_true", help="download only; don't email")
    p.add_argument("--force", action="store_true", help="resend items already in the sent history")
    p.set_defaults(func=cmd_send)

    args = ap.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
