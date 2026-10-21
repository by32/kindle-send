# kindle-send

Send free, open-format ebooks (Project Gutenberg, Standard Ebooks, any EPUB/PDF URL, or local files)
to your Kindle in one command, using Amazon's Send-to-Kindle email service.
Needs only Python 3.9+, with no extra packages. The `python3` that ships with macOS works.

## Setup

1. **Find your Kindle address**: amazon.com → *Manage Your Content and Devices* → *Preferences* →
   *Personal Document Settings*. It looks like `yourname_abc123@kindle.com`.
2. **Pick a provider and run `./kindle_send.py init`.** It asks for your Kindle address and the
   provider's credentials, then saves them to `~/.config/kindle-send/config.toml` (owner-only).
   Run it again to add more providers. Each gets its own section, and one is the default.
3. **Approve the sending address** in the same Amazon page, under *Approved Personal Document
   E-mail List*. Use the full address: Amazon stopped accepting domain-only entries in 2025.
   Amazon silently drops mail from unapproved senders.
4. **Test it** with `./kindle_send.py check`. This logs in or calls the API without sending anything.

### Providers

| Provider | What you need | Size cap used |
|---|---|---|
| `gmail` | An [App Password](https://myaccount.google.com/apppasswords) (needs 2-Step Verification) | 25 MB |
| `icloud` | An [app-specific password](https://account.apple.com) (Sign-In and Security). Log in with your full @icloud.com address | 20 MB |
| `fastmail` | An app password (Settings → Privacy & Security) | 50 MB |
| `yahoo` | An app password (Account Security → Generate app password) | 25 MB |
| `smtp` | Host, port (465 SSL or 587 STARTTLS), user, password for any other server | 50 MB |
| `ses` | Amazon SES: a verified sender, an IAM access key, and **production access** (see below) | 40 MB |
| `resend` | A [Resend](https://resend.com) API key and a verified domain | 40 MB |

The size cap is per email. Bigger sends are split across several emails automatically, and a Gutenberg
book that's too large falls back to its no-images edition.

### Amazon SES setup

1. In the SES console, pick a region and stay in it. Identities and limits are per region.
2. **Verified identities → Create identity.** Verify a domain you own (best deliverability) or a
   single email address (click the link AWS sends).
3. **Request production access** (Account dashboard). New accounts start in a *sandbox* that can
   only email verified addresses, and a `@kindle.com` address can't be verified. For the use case,
   describe it as personal, low-volume mail to your own Kindle. Review usually takes about a day.
4. **Create an IAM user** with this policy, then create an access key for it:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Action": ["ses:SendEmail", "ses:SendRawEmail", "ses:GetAccount"],
       "Resource": "*"
     }]
   }
   ```
5. Run `./kindle_send.py init --via ses`, then `./kindle_send.py check --via ses`. `check` reports
   whether the account is still in the sandbox.

Instead of storing keys in the config, SES also reads the standard `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` / `AWS_REGION` env vars and `~/.aws/credentials` (respecting `AWS_PROFILE`).

### Example config

```toml
kindle_email = "yourname_abc123@kindle.com"
provider = "icloud"            # the default; override per run with --via

[icloud]
user = "you@icloud.com"
password = "abcd-efgh-ijkl-mnop"

[gmail]
user = "you@gmail.com"
password = "abcd efgh ijkl mnop"
from = "alias@gmail.com"       # optional; defaults to user

[smtp]
host = "mail.example.com"
port = 587
user = "you"
password = "..."

[ses]
from = "books@yourdomain.com"
region = "us-east-1"
access_key_id = "AKIA..."      # optional if set in env or ~/.aws/credentials
secret_access_key = "..."

[resend]
from = "books@yourdomain.com"
api_key = "re_..."             # or RESEND_API_KEY
```

Every setting can also come from an env var named `KINDLE_SEND_<PROVIDER>_<KEY>`
(e.g. `KINDLE_SEND_GMAIL_PASSWORD`), plus `KINDLE_SEND_KINDLE_EMAIL` and `KINDLE_SEND_PROVIDER`.
That's handy for keeping passwords out of the file. Env vars take precedence over the file.

## Usage

```sh
./kindle_send.py search "jane austen"           # browse Gutenberg
./kindle_send.py send 1342                       # by Gutenberg ID
./kindle_send.py send "moby dick"                # search, then pick from a numbered list
./kindle_send.py send "moby dick" -y             # take the top hit
./kindle_send.py send 1342 --via ses             # use a non-default provider
./kindle_send.py send https://example.org/book.epub ~/Downloads/paper.pdf
./kindle_send.py send -f reading-list.txt -y     # a whole reading list
./kindle_send.py send 1342 --dry-run --out ./books   # download only
./kindle_send.py check --via gmail               # verify credentials
```

Options: `--no-images` gives smaller Gutenberg files. `--force` resends something already sent;
sent items are tracked in `~/.local/state/kindle-send/sent.json` so reading lists can be re-run safely.

## Notes

- Accepted formats: EPUB, PDF, TXT, DOC/DOCX, RTF, HTML. MOBI/AZW3 are no longer accepted by Amazon.
- Amazon also caps each email at 25 attachments; batching handles that too.
- To run on a schedule (e.g. a nightly reading-list drop), use cron:
  `0 21 * * * /path/to/kindle_send.py send -f ~/reading-list.txt -y`

## Development

```sh
python3 -m unittest discover -s tests
```

Tests run offline. With `botocore` installed, they also cross-check the SES request signing against AWS's own library.
