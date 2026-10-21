#!/usr/bin/env python3
"""kindle-send: fetch open-format ebooks and deliver them to a Kindle via Send-to-Kindle email.

Sources:
  - Project Gutenberg, by ID ("1342"), search query ("pride and prejudice") or book URL
  - Any direct URL to an EPUB / PDF / TXT / HTML / DOCX / RTF file (Standard Ebooks, etc.)
  - Local files

Delivery providers: Gmail, iCloud, Fastmail, Yahoo, any SMTP server, Amazon SES, Resend.

Only the Python standard library is used (Python 3.9+, so the python3 that ships with macOS works).
"""

from __future__ import annotations

import argparse
import base64
import configparser
import getpass
import hashlib
import hmac
import json
import mimetypes
import os
import re
import smtplib
import ssl
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
from email.message import EmailMessage
from pathlib import Path

try:
    import tomllib
except ImportError:  # Python < 3.11, e.g. the python3 that ships with macOS
    tomllib = None

USER_AGENT = "kindle-send/1.0 (+personal use)"
GUTENDEX = "https://gutendex.com/books/"
GUTENBERG = "https://www.gutenberg.org"

# Formats Amazon's Send-to-Kindle email service accepts.
SUPPORTED_EXT = {".epub", ".pdf", ".txt", ".doc", ".docx", ".rtf", ".htm", ".html"}
MB = 1024 * 1024
MAX_EMAIL_BYTES = 50 * MB  # Amazon's per-email limit

CONFIG_PATH = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "kindle-send" / "config.toml"
HISTORY_PATH = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "kindle-send" / "sent.json"


# --------------------------------------------------------------------------- providers

class DeliveryError(Exception):
    pass


@dataclass(frozen=True)
class SmtpPreset:
    label: str
    host: str
    port: int
    max_bytes: int  # message size cap, after base64 encoding (kept conservative)
    password_help: str


SMTP_PRESETS = {
    "gmail": SmtpPreset(
        "Gmail", "smtp.gmail.com", 465, 25 * MB,
        "Use an App Password (needs 2-Step Verification): https://myaccount.google.com/apppasswords",
    ),
    "icloud": SmtpPreset(
        "iCloud Mail", "smtp.mail.me.com", 587, 20 * MB,
        "Use an app-specific password: https://account.apple.com → Sign-In and Security → App-Specific Passwords.\n"
        "  The user name is your full @icloud.com / @me.com address.",
    ),
    "fastmail": SmtpPreset(
        "Fastmail", "smtp.fastmail.com", 465, 50 * MB,
        "Use an app password: Fastmail Settings → Privacy & Security → Manage app passwords",
    ),
    "yahoo": SmtpPreset(
        "Yahoo Mail", "smtp.mail.yahoo.com", 465, 25 * MB,
        "Use an app password: Yahoo Account Security → Generate app password",
    ),
}

PROVIDERS = {
    **{name: p.label for name, p in SMTP_PRESETS.items()},
    "smtp": "Any other SMTP server",
    "ses": "Amazon SES (API keys; needs a verified sender and SES production access)",
    "resend": "Resend (API key; needs a verified domain)",
}


class SmtpSender:
    def __init__(self, host: str, port: int, user: str, password: str, from_addr: str, max_bytes: int):
        self.host, self.port, self.user, self.password = host, port, user, password
        self.from_addr, self.max_bytes = from_addr, max_bytes

    def _connect(self) -> smtplib.SMTP:
        ctx = ssl.create_default_context()
        if self.port == 465:
            s = smtplib.SMTP_SSL(self.host, self.port, context=ctx, timeout=60)
        else:
            s = smtplib.SMTP(self.host, self.port, timeout=60)
            s.starttls(context=ctx)
        try:
            s.login(self.user, self.password)
        except smtplib.SMTPAuthenticationError as e:
            s.close()
            raise DeliveryError(f"{self.host} rejected the login for {self.user} (use an app password): {e}") from e
        return s

    def send(self, msg: EmailMessage) -> None:
        with self._connect() as s:
            s.send_message(msg)

    def check(self) -> list[str]:
        with self._connect():
            pass
        return []


def _sigv4_signing_key(secret: str, datestamp: str, region: str, service: str) -> bytes:
    key = ("AWS4" + secret).encode()
    for part in (datestamp, region, service, "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    return key


def sigv4_headers(
    method: str, url: str, body: bytes, region: str, service: str,
    access_key: str, secret_key: str, session_token: str | None = None, now: datetime | None = None,
) -> dict[str, str]:
    """AWS Signature Version 4 headers for a JSON request with no query string."""
    now = now or datetime.now(timezone.utc)
    amz_date, datestamp = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    u = urllib.parse.urlsplit(url)
    headers = {"content-type": "application/json", "host": u.netloc, "x-amz-date": amz_date}
    if session_token:
        headers["x-amz-security-token"] = session_token
    signed = ";".join(sorted(headers))
    canonical = "\n".join([
        method, u.path or "/", u.query,
        "".join(f"{k}:{headers[k]}\n" for k in sorted(headers)),
        signed, hashlib.sha256(body).hexdigest(),
    ])
    scope = f"{datestamp}/{region}/{service}/aws4_request"
    to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
    sig = hmac.new(_sigv4_signing_key(secret_key, datestamp, region, service), to_sign.encode(), hashlib.sha256).hexdigest()
    headers["authorization"] = f"AWS4-HMAC-SHA256 Credential={access_key}/{scope}, SignedHeaders={signed}, Signature={sig}"
    return headers


def _json_request(req: urllib.request.Request, who: str) -> dict:
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        raise DeliveryError(f"{who} returned HTTP {e.code}: {e.read().decode(errors='replace')[:500]}") from e
    return json.loads(raw) if raw.strip() else {}


class SesSender:
    max_bytes = 40 * MB

    def __init__(self, from_addr: str, region: str, access_key: str, secret_key: str, session_token: str | None):
        self.from_addr, self.region = from_addr, region
        self.access_key, self.secret_key, self.session_token = access_key, secret_key, session_token

    def _call(self, method: str, path: str, payload: dict | None = None) -> dict:
        url = f"https://email.{self.region}.amazonaws.com{path}"
        body = json.dumps(payload).encode() if payload is not None else b""
        headers = sigv4_headers(method, url, body, self.region, "ses", self.access_key, self.secret_key, self.session_token)
        headers["user-agent"] = USER_AGENT
        req = urllib.request.Request(url, data=body if payload is not None else None, method=method, headers=headers)
        return _json_request(req, "Amazon SES")

    def send(self, msg: EmailMessage) -> None:
        self._call("POST", "/v2/email/outbound-emails", {
            "FromEmailAddress": self.from_addr,
            "Destination": {"ToAddresses": [msg["To"]]},
            "Content": {"Raw": {"Data": base64.b64encode(msg.as_bytes()).decode()}},
        })

    def check(self) -> list[str]:
        acct = self._call("GET", "/v2/email/account")
        warnings = []
        if not acct.get("SendingEnabled", True):
            warnings.append("Sending is disabled on this SES account.")
        if not acct.get("ProductionAccessEnabled"):
            warnings.append(
                "This SES account is still in the sandbox, so it can only send to verified addresses, and a "
                "@kindle.com address can't be verified. Request production access in the SES console "
                f"(region {self.region}) before sending."
            )
        return warnings


class ResendSender:
    max_bytes = 40 * MB
    api = "https://api.resend.com"

    def __init__(self, from_addr: str, api_key: str):
        self.from_addr, self.api_key = from_addr, api_key

    def _request(self, method: str, path: str, payload: dict | None = None) -> dict:
        req = urllib.request.Request(
            self.api + path, method=method,
            data=json.dumps(payload).encode() if payload is not None else None,
            headers={"Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json", "User-Agent": USER_AGENT},
        )
        return _json_request(req, "Resend")

    def send(self, msg: EmailMessage) -> None:
        self._request("POST", "/emails", {
            "from": self.from_addr,
            "to": [msg["To"]],
            "subject": msg["Subject"],
            "text": "Sent by kindle-send.",
            "attachments": [
                {"filename": part.get_filename(), "content": base64.b64encode(part.get_content()).decode()}
                for part in msg.iter_attachments()
            ],
        })

    def check(self) -> list[str]:
        try:
            domains = self._request("GET", "/domains").get("data", [])
        except DeliveryError as e:
            if "restricted_api_key" not in str(e):
                raise
            return ["This is a send-only key, so the sender domain can't be checked from here."]
        sender_domain = self.from_addr.rsplit("@", 1)[-1].strip("> ").lower()
        for d in domains:
            if d.get("name", "").lower() == sender_domain:
                return [] if d.get("status") == "verified" else [f"Domain {sender_domain} is {d.get('status')}, not verified."]
        return [f"Domain {sender_domain} isn't set up in this Resend account."]


# --------------------------------------------------------------------------- config

def _parse_simple_toml(text: str) -> dict:
    """The TOML subset this tool reads and writes: [tables], and keys set to strings, ints or booleans."""
    data: dict = {}
    table = data
    for n, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if m := re.fullmatch(r"\[\s*([A-Za-z0-9_-]+)\s*\](\s*#.*)?", line):
            table = data.setdefault(m.group(1), {})
            continue
        key, sep, rest = line.partition("=")
        if not sep:
            raise ValueError(f"config line {n}: expected key = value")
        key, rest = key.strip().strip('"'), rest.strip()
        if rest.startswith('"'):
            value, end = json.JSONDecoder().raw_decode(rest)  # TOML basic strings use JSON-style escapes
            rest = rest[end:]
        elif rest.startswith("'"):
            end = rest.index("'", 1)
            value, rest = rest[1:end], rest[end + 1:]
        else:
            token, _, comment = rest.partition("#")
            rest = "#" + comment if comment else ""
            token = token.strip()
            value = {"true": True, "false": False}.get(token)
            if value is None:
                value = int(token.replace("_", ""))
        if rest.strip() and not rest.strip().startswith("#"):
            raise ValueError(f"config line {n}: unexpected text after value")
        table[key] = value
    return data


def _read_toml(path: Path) -> dict:
    if not path.exists():
        return {}
    if tomllib:
        with path.open("rb") as f:
            data = tomllib.load(f)
    else:
        data = _parse_simple_toml(path.read_text(encoding="utf-8"))
    # Configs from the first version were flat smtp_* keys; fold them into a provider table.
    if "smtp_user" in data:
        host = data.pop("smtp_host", "smtp.gmail.com")
        name = next((n for n, p in SMTP_PRESETS.items() if p.host == host), "smtp")
        section = {"user": data.pop("smtp_user")}
        if name == "smtp":
            section |= {"host": host, "port": data.pop("smtp_port", 587)}
        else:
            data.pop("smtp_port", None)
        for old, new in (("smtp_password", "password"), ("from_addr", "from")):
            if old in data:
                section[new] = data.pop(old)
        data.setdefault(name, section)
        data.setdefault("provider", name)
    return data


def _toml_value(v) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return json.dumps(str(v), ensure_ascii=False)  # a JSON string is a valid TOML basic string


def _write_toml(path: Path, data: dict) -> None:
    lines = [f"{k} = {_toml_value(v)}" for k, v in data.items() if not isinstance(v, dict)]
    for name, table in data.items():
        if isinstance(table, dict):
            lines += ["", f"[{name}]"] + [f"{k} = {_toml_value(v)}" for k, v in table.items() if v not in (None, "")]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.touch(mode=0o600, exist_ok=True)
    path.chmod(0o600)
    path.write_text("\n".join(lines) + "\n")


def _aws_profile_credentials() -> dict:
    path = Path(os.environ.get("AWS_SHARED_CREDENTIALS_FILE", Path.home() / ".aws" / "credentials"))
    cp = configparser.ConfigParser()
    cp.read(path)
    profile = os.environ.get("AWS_PROFILE", "default")
    return dict(cp[profile]) if cp.has_section(profile) else {}


@dataclass
class Config:
    kindle_email: str | None
    provider: str
    tables: dict = field(default_factory=dict)
    path: Path = CONFIG_PATH

    @classmethod
    def load(cls, provider: str | None = None, path: Path | None = None) -> "Config":
        path = path or CONFIG_PATH
        data = _read_toml(path)
        provider = (provider or os.environ.get("KINDLE_SEND_PROVIDER") or data.get("provider") or "gmail").lower()
        if provider not in PROVIDERS:
            sys.exit(f"Unknown provider {provider!r}. Choose from: {', '.join(PROVIDERS)}")
        kindle = os.environ.get("KINDLE_SEND_KINDLE_EMAIL") or data.get("kindle_email")
        return cls(kindle, provider, {k: v for k, v in data.items() if isinstance(v, dict)}, path)

    def get(self, key: str, *env_fallbacks: str):
        """Env var KINDLE_SEND_<PROVIDER>_<KEY>, then the config table, then any standard env vars."""
        value = os.environ.get(f"KINDLE_SEND_{self.provider.upper()}_{key.upper()}")
        value = value or self.tables.get(self.provider, {}).get(key)
        for env in env_fallbacks:
            value = value or os.environ.get(env)
        return value

    def sender(self):
        p, missing = self.provider, []

        def need(key: str, value):
            if not value:
                missing.append(f"{key} (config [{p}] {key}, or env KINDLE_SEND_{p.upper()}_{key.upper()})")
            return value

        if not self.kindle_email:
            missing.append("kindle_email (config top level, or env KINDLE_SEND_KINDLE_EMAIL)")

        if p in SMTP_PRESETS or p == "smtp":
            preset = SMTP_PRESETS.get(p)
            host = need("host", self.get("host") or (preset and preset.host))
            port = int(self.get("port") or (preset.port if preset else 587))
            user = need("user", self.get("user"))
            password = need("password", self.get("password"))
            from_addr = self.get("from") or user
            make = lambda: SmtpSender(host, port, user, password, from_addr, preset.max_bytes if preset else MAX_EMAIL_BYTES)
        elif p == "ses":
            profile = _aws_profile_credentials()
            from_addr = need("from", self.get("from"))
            region = self.get("region", "AWS_REGION", "AWS_DEFAULT_REGION") or "us-east-1"
            key = need("access_key_id", self.get("access_key_id", "AWS_ACCESS_KEY_ID") or profile.get("aws_access_key_id"))
            secret = need("secret_access_key", self.get("secret_access_key", "AWS_SECRET_ACCESS_KEY") or profile.get("aws_secret_access_key"))
            token = self.get("session_token", "AWS_SESSION_TOKEN") or profile.get("aws_session_token")
            make = lambda: SesSender(from_addr, region, key, secret, token)
        else:  # resend
            from_addr = need("from", self.get("from"))
            api_key = need("api_key", self.get("api_key", "RESEND_API_KEY"))
            make = lambda: ResendSender(from_addr, api_key)

        if missing:
            sys.exit(
                f"Missing settings for provider '{p}':\n  - " + "\n  - ".join(missing)
                + f"\nRun `kindle_send.py init` to set them up (config file: {self.path})."
            )
        return make()


def _ask(prompt: str, default=None, secret: bool = False) -> str:
    shown = " [saved]" if secret and default else (f" [{default}]" if default else "")
    answer = (getpass.getpass if secret else input)(f"{prompt}{shown}: ").strip()
    return answer or (default or "")


def cmd_init(args) -> None:
    data = _read_toml(CONFIG_PATH)
    print(f"Config file: {CONFIG_PATH}\n")
    data["kindle_email"] = _ask("Your Send-to-Kindle address (…@kindle.com)", data.get("kindle_email"))

    names = list(PROVIDERS)
    provider = args.via
    if not provider:
        print("\nHow should books be sent?")
        for i, name in enumerate(names, 1):
            configured = " (configured)" if name in data else ""
            print(f"  {i}. {name:<9} {PROVIDERS[name]}{configured}")
        choice = _ask("Pick a number", str(names.index(data.get("provider", "gmail")) + 1))
        if not choice.isdigit() or not 1 <= int(choice) <= len(names):
            sys.exit("No provider chosen.")
        provider = names[int(choice) - 1]

    t = dict(data.get(provider, {}))
    print()
    if provider in SMTP_PRESETS or provider == "smtp":
        if provider == "smtp":
            t["host"] = _ask("SMTP host", t.get("host"))
            t["port"] = int(_ask("SMTP port (465 = SSL, 587 = STARTTLS)", str(t.get("port", 587))))
        t["user"] = _ask("Your email address (login)", t.get("user"))
        if provider in SMTP_PRESETS:
            print(SMTP_PRESETS[provider].password_help)
        t["password"] = _ask("Password (blank = use env var)", t.get("password"), secret=True)
        from_addr = _ask("Send from (blank = same as login)", t.get("from"))
        t["from"] = from_addr if from_addr and from_addr != t["user"] else None
        sender = t.get("from") or t["user"]
    elif provider == "ses":
        print("Needs a verified sender, SES production access, and an IAM key allowed ses:SendEmail,\n"
              "ses:SendRawEmail and ses:GetAccount (see README → Amazon SES setup).")
        print("Leave the keys blank to use AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY or ~/.aws/credentials.")
        t["from"] = sender = _ask("Verified sender address", t.get("from"))
        t["region"] = _ask("SES region", t.get("region", "us-east-1"))
        t["access_key_id"] = _ask("Access key ID", t.get("access_key_id"))
        t["secret_access_key"] = _ask("Secret access key", t.get("secret_access_key"), secret=True)
    else:
        print("Needs a domain verified in Resend (https://resend.com/domains).")
        t["from"] = sender = _ask("Sender address on that domain", t.get("from"))
        t["api_key"] = _ask("API key (blank = use RESEND_API_KEY env var)", t.get("api_key"), secret=True)

    data[provider] = t
    if "provider" not in data or data["provider"] == provider:
        data["provider"] = provider
    elif _ask(f"Make {provider} the default instead of {data['provider']}? (y/N)").lower().startswith("y"):
        data["provider"] = provider
    # Keep top-level keys first so the file reads cleanly.
    data = {k: data[k] for k in ("kindle_email", "provider")} | {k: v for k, v in data.items() if k not in ("kindle_email", "provider")}
    _write_toml(CONFIG_PATH, data)

    print(f"\nSaved [{provider}] (default provider: {data['provider']}).")
    print(f"Next: add {sender} to Amazon's Approved Personal Document E-mail List:")
    print("  amazon.com → Manage Your Content and Devices → Preferences → Personal Document Settings")
    print(f"Then test it: kindle_send.py check --via {provider}")


def cmd_check(args) -> None:
    cfg = Config.load(args.via)
    sender = cfg.sender()
    print(f"Checking {cfg.provider} ({PROVIDERS[cfg.provider]}) …")
    try:
        warnings = sender.check()
    except (DeliveryError, OSError, smtplib.SMTPException) as e:
        sys.exit(f"Failed: {e}")
    for w in warnings:
        print(f"  ! {w}")
    print(f"{'Credentials OK' if not warnings else 'Credentials OK, with warnings above'}.")
    print(f"Books will be sent from {sender.from_addr} to {cfg.kindle_email}. That sender must be on Amazon's approved list.")


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

def resolve(item: str, workdir: Path, images: bool, pick_first: bool, max_bytes: int = MAX_EMAIL_BYTES) -> Path | None:
    """Turn a CLI argument into a local file ready to send."""
    p = Path(item).expanduser()
    if p.is_file():
        return p

    if item.isdigit():
        return fetch_gutenberg(int(item), workdir, images, max_bytes=max_bytes)

    if m := GUTENBERG_URL_RE.search(item):
        return fetch_gutenberg(int(m.group(1)), workdir, images, max_bytes=max_bytes)

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
    return fetch_gutenberg(choice.id, workdir, images, choice, max_bytes)


def fetch_gutenberg(
    book_id: int, workdir: Path, images: bool, book: Book | None = None, max_bytes: int = MAX_EMAIL_BYTES,
) -> Path:
    book = book or gutenberg_book(book_id)
    print(f"Downloading Gutenberg #{book.id}: {book.title} — {book.authors}")
    path = download(gutenberg_epub_url(book.id, images), workdir, book.filename())
    if images and encoded_size(path) > max_bytes:
        print("  Too large for email with images; retrying without images.")
        path.unlink()
        path = download(gutenberg_epub_url(book.id, False), workdir, book.filename())
    return path


# --------------------------------------------------------------------------- send

def build_message(from_addr: str, to_addr: str, files: list[Path]) -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = from_addr
    msg["To"] = to_addr
    msg["Subject"] = "kindle-send: " + ", ".join(f.stem for f in files)[:200]
    msg.set_content("Sent by kindle-send.")
    for f in files:
        ctype = mimetypes.guess_type(f.name)[0] or "application/octet-stream"
        if f.suffix.lower() == ".epub":
            ctype = "application/epub+zip"
        maintype, subtype = ctype.split("/", 1)
        msg.add_attachment(f.read_bytes(), maintype=maintype, subtype=subtype, filename=f.name)
    return msg


def encoded_size(path: Path) -> int:
    return path.stat().st_size * 4 // 3 + 4096  # base64 plus headers


def batch_by_size(files: list[Path], limit: int = MAX_EMAIL_BYTES, max_count: int = 25) -> list[list[Path]]:
    batches, cur, cur_size = [], [], 0
    for f in files:
        size = encoded_size(f)
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

    cfg = sender = None
    max_bytes = MAX_EMAIL_BYTES
    if not args.dry_run:
        cfg = Config.load(args.via)
        sender = cfg.sender()
        max_bytes = min(MAX_EMAIL_BYTES, sender.max_bytes)
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
                path = resolve(item, workdir, images=not args.no_images, pick_first=args.yes, max_bytes=max_bytes)
            except Exception as e:  # keep going with the rest of the list
                print(f"  Failed: {item!r}: {e}", file=sys.stderr)
                continue
            if not path:
                continue
            if path.suffix.lower() not in SUPPORTED_EXT:
                print(f"  Skipping {path.name}: Send-to-Kindle doesn't accept {path.suffix or 'this type'}", file=sys.stderr)
                continue
            if encoded_size(path) > max_bytes:
                print(f"  Skipping {path.name}: too large to email (limit {max_bytes // MB} MB)", file=sys.stderr)
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

        for batch in batch_by_size(files, max_bytes):
            print(f"\nEmailing {len(batch)} file(s) to {cfg.kindle_email} via {cfg.provider} …")
            try:
                sender.send(build_message(sender.from_addr, cfg.kindle_email, batch))
            except (DeliveryError, OSError, smtplib.SMTPException) as e:
                sys.exit(f"Send failed: {e}")
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

    i = sub.add_parser("init", help="set up your Kindle address and a delivery provider (run again to add more)")
    i.add_argument("--via", choices=PROVIDERS, help="provider to configure (skips the menu)")
    i.set_defaults(func=cmd_init)

    c = sub.add_parser("check", help="verify a provider's credentials without sending anything")
    c.add_argument("--via", choices=PROVIDERS, help="provider to check (default: your configured default)")
    c.set_defaults(func=cmd_check)

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
    p.add_argument("--via", choices=PROVIDERS, help="delivery provider for this run (default: from config)")
    p.set_defaults(func=cmd_send)

    args = ap.parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
