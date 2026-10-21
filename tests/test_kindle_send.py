"""Offline tests: no network, no real mail. Run with `python3 -m unittest discover -s tests`."""

import base64
import email
import email.policy
import io
import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import kindle_send as ks  # noqa: E402

FIXED_NOW = datetime(2026, 10, 20, 12, 34, 56, tzinfo=timezone.utc)


def make_book(dirpath: Path, name: str = "Book.epub", size: int = 1000) -> Path:
    p = dirpath / name
    p.write_bytes(os.urandom(size))
    return p


class EnvTestCase(unittest.TestCase):
    """Isolates config, history and env vars in a temp dir."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.config_path = self.tmp / "config.toml"
        env = {k: v for k, v in os.environ.items() if not k.startswith(("KINDLE_SEND_", "AWS_", "RESEND_"))}
        env["AWS_SHARED_CREDENTIALS_FILE"] = str(self.tmp / "aws-credentials")
        patches = [
            mock.patch.dict(os.environ, env, clear=True),
            mock.patch.object(ks, "CONFIG_PATH", self.config_path),
            mock.patch.object(ks, "HISTORY_PATH", self.tmp / "sent.json"),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def write_config(self, text: str):
        self.config_path.write_text(text)

    def load(self, provider=None):
        return ks.Config.load(provider, self.config_path)


class SigV4Tests(unittest.TestCase):
    def test_signing_key_matches_aws_docs_example(self):
        # From the AWS SigV4 documentation ("Calculate the signature").
        key = ks._sigv4_signing_key("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20150830", "us-east-1", "iam")
        self.assertEqual(key.hex(), "c4afb1cc5771d871763a393e44b703571b55cc28424d1a5e86da6ed3c154a4b9")

    def test_matches_botocore(self):
        try:
            from botocore.auth import SigV4Auth
            from botocore.awsrequest import AWSRequest
            from botocore.credentials import Credentials
        except ImportError:
            self.skipTest("botocore not installed")
        url = "https://email.us-west-2.amazonaws.com/v2/email/outbound-emails"
        body = b'{"hello": "world"}'
        for token in (None, "session-token"):
            with self.subTest(token=token):
                ours = ks.sigv4_headers("POST", url, body, "us-west-2", "ses", "AKIDEXAMPLE", "secret", token, FIXED_NOW)
                req = AWSRequest(method="POST", url=url, data=body, headers={"content-type": "application/json"})
                with mock.patch("botocore.auth.get_current_datetime", return_value=FIXED_NOW.replace(tzinfo=None)):
                    SigV4Auth(Credentials("AKIDEXAMPLE", "secret", token), "ses", "us-west-2").add_auth(req)
                self.assertEqual(ours["authorization"], req.headers["Authorization"])


class ConfigTests(EnvTestCase):
    def test_legacy_flat_gmail_config_is_migrated(self):
        self.write_config('kindle_email = "me@kindle.com"\nsmtp_user = "me@gmail.com"\n'
                          'smtp_host = "smtp.gmail.com"\nsmtp_port = 465\nsmtp_password = "pw"\n')
        cfg = self.load()
        self.assertEqual(cfg.provider, "gmail")
        s = cfg.sender()
        self.assertEqual((s.host, s.port, s.user, s.password, s.from_addr), ("smtp.gmail.com", 465, "me@gmail.com", "pw", "me@gmail.com"))

    def test_legacy_custom_host_becomes_smtp(self):
        self.write_config('kindle_email = "k@kindle.com"\nsmtp_user = "u"\nsmtp_host = "mail.example.com"\n'
                          'smtp_port = 2525\nsmtp_password = "pw"\nfrom_addr = "books@example.com"\n')
        s = self.load().sender()
        self.assertEqual((s.host, s.port, s.from_addr), ("mail.example.com", 2525, "books@example.com"))

    def test_multiple_providers_and_via_override(self):
        self.write_config(
            'kindle_email = "k@kindle.com"\nprovider = "gmail"\n'
            '[gmail]\nuser = "me@gmail.com"\npassword = "g"\n'
            '[icloud]\nuser = "me@icloud.com"\npassword = "i"\n'
        )
        self.assertEqual(self.load().sender().host, "smtp.gmail.com")
        icloud = self.load("icloud").sender()
        self.assertEqual((icloud.host, icloud.port, icloud.max_bytes), ("smtp.mail.me.com", 587, 20 * ks.MB))

    def test_env_vars_override_file(self):
        self.write_config('kindle_email = "k@kindle.com"\n[resend]\nfrom = "a@x.com"\napi_key = "from-file"\n')
        os.environ["RESEND_API_KEY"] = "standard-env"
        self.assertEqual(self.load("resend").sender().api_key, "from-file")  # file beats generic env
        os.environ["KINDLE_SEND_RESEND_API_KEY"] = "specific-env"
        self.assertEqual(self.load("resend").sender().api_key, "specific-env")

    def test_ses_reads_aws_env_and_shared_credentials(self):
        self.write_config('kindle_email = "k@kindle.com"\n[ses]\nfrom = "books@example.com"\n')
        (self.tmp / "aws-credentials").write_text("[default]\naws_access_key_id = AKFILE\naws_secret_access_key = SFILE\n")
        s = self.load("ses").sender()
        self.assertEqual((s.access_key, s.secret_key, s.region), ("AKFILE", "SFILE", "us-east-1"))
        os.environ.update(AWS_ACCESS_KEY_ID="AKENV", AWS_SECRET_ACCESS_KEY="SENV", AWS_REGION="eu-west-1")
        s = self.load("ses").sender()
        self.assertEqual((s.access_key, s.secret_key, s.region), ("AKENV", "SENV", "eu-west-1"))

    def test_missing_settings_exit_with_names(self):
        self.write_config('[gmail]\nuser = "me@gmail.com"\n')
        with self.assertRaises(SystemExit) as cm:
            self.load().sender()
        msg = str(cm.exception)
        self.assertIn("kindle_email", msg)
        self.assertIn("KINDLE_SEND_GMAIL_PASSWORD", msg)

    def test_unknown_provider(self):
        with self.assertRaises(SystemExit):
            self.load("pigeon")

    def test_fallback_toml_parser_matches_tomllib(self):
        if ks.tomllib is None:
            self.skipTest("tomllib needs Python 3.11+")
        readme = (Path(__file__).resolve().parents[1] / "README.md").read_text()
        example = readme.split("```toml\n", 1)[1].split("```", 1)[0]
        tricky = 'a = "q\\"uote \\\\ back # not a comment"  # comment\nb = \'lit#eral\'\n[t] # c\nn = 1_000\nf = false\n'
        for text in (example, tricky):
            self.assertEqual(ks._parse_simple_toml(text), ks.tomllib.loads(text))

    def test_toml_round_trip_with_awkward_password(self):
        data = {"kindle_email": "k@kindle.com", "provider": "smtp",
                "smtp": {"host": "h", "port": 587, "user": "u", "password": 'a"b\\c ü', "from": None}}
        ks._write_toml(self.config_path, data)
        self.assertEqual(self.config_path.stat().st_mode & 0o777, 0o600)
        loaded = ks._read_toml(self.config_path)
        self.assertEqual(loaded["smtp"]["password"], 'a"b\\c ü')
        self.assertNotIn("from", loaded["smtp"])


class InitTests(EnvTestCase):
    def run_init(self, answers, secrets, via=None):
        args = mock.Mock(via=via)
        with mock.patch("builtins.input", side_effect=answers), \
             mock.patch.object(ks.getpass, "getpass", side_effect=secrets), redirect_stdout(io.StringIO()):
            ks.cmd_init(args)

    def test_init_adds_providers_and_keeps_existing(self):
        names = list(ks.PROVIDERS)
        # kindle address, menu choice, user, from
        self.run_init(["me_1@kindle.com", str(names.index("gmail") + 1), "me@gmail.com", ""], ["app-pw"])
        # second run: keep kindle address, configure iCloud via flag, decline making it default
        self.run_init(["", "me@icloud.com", "", "n"], ["icloud-pw"], via="icloud")
        cfg = self.load()
        self.assertEqual((cfg.kindle_email, cfg.provider), ("me_1@kindle.com", "gmail"))
        self.assertEqual(cfg.sender().password, "app-pw")
        self.assertEqual(self.load("icloud").sender().password, "icloud-pw")


class FakeSMTP:
    instances = []

    def __init__(self, host, port, **kw):
        self.host, self.port, self.tls, self.logged_in, self.sent = host, port, False, None, []
        FakeSMTP.instances.append(self)

    def starttls(self, context=None):
        self.tls = True

    def login(self, user, pw):
        self.logged_in = (user, pw)

    def send_message(self, msg):
        self.sent.append(msg)

    def close(self):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *a):
        pass


class SenderTests(EnvTestCase):
    def setUp(self):
        super().setUp()
        FakeSMTP.instances = []
        self.book = make_book(self.tmp, "Pride and Prejudice - Austen.epub", 5000)
        self.msg = ks.build_message("books@example.com", "me@kindle.com", [self.book])

    def test_smtp_ssl_and_starttls(self):
        with mock.patch.object(ks.smtplib, "SMTP_SSL", FakeSMTP), mock.patch.object(ks.smtplib, "SMTP", FakeSMTP):
            ks.SmtpSender("smtp.gmail.com", 465, "u", "p", "u", ks.MB).send(self.msg)
            ks.SmtpSender("smtp.mail.me.com", 587, "u", "p", "u", ks.MB).send(self.msg)
        gmail, icloud = FakeSMTP.instances
        self.assertFalse(gmail.tls)
        self.assertTrue(icloud.tls)
        self.assertEqual(len(icloud.sent), 1)

    def capture_urlopen(self, response: dict):
        captured = []

        class Resp(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *a):
                pass

        def fake(req, timeout=None):
            captured.append(req)
            return Resp(json.dumps(response).encode())

        p = mock.patch.object(ks.urllib.request, "urlopen", fake)
        p.start()
        self.addCleanup(p.stop)
        return captured

    def test_ses_send_posts_signed_raw_mime(self):
        reqs = self.capture_urlopen({"MessageId": "x"})
        ks.SesSender("books@example.com", "us-west-2", "AKID", "secret", None).send(self.msg)
        req = reqs[0]
        self.assertEqual(req.full_url, "https://email.us-west-2.amazonaws.com/v2/email/outbound-emails")
        self.assertTrue(req.get_header("Authorization").startswith("AWS4-HMAC-SHA256 Credential=AKID/"))
        body = json.loads(req.data)
        self.assertEqual(body["Destination"]["ToAddresses"], ["me@kindle.com"])
        mime = email.message_from_bytes(base64.b64decode(body["Content"]["Raw"]["Data"]), policy=email.policy.default)
        (att,) = mime.iter_attachments()
        self.assertEqual((att.get_filename(), att.get_content_type()), (self.book.name, "application/epub+zip"))
        self.assertEqual(att.get_content(), self.book.read_bytes())

    def test_ses_check_warns_about_sandbox(self):
        self.capture_urlopen({"SendingEnabled": True, "ProductionAccessEnabled": False})
        warnings = ks.SesSender("a@x.com", "us-east-1", "AK", "S", None).check()
        self.assertTrue(any("sandbox" in w for w in warnings))

    def test_resend_send_payload(self):
        reqs = self.capture_urlopen({"id": "x"})
        ks.ResendSender("books@example.com", "re_key").send(self.msg)
        req = reqs[0]
        self.assertEqual(req.full_url, "https://api.resend.com/emails")
        self.assertEqual(req.get_header("Authorization"), "Bearer re_key")
        body = json.loads(req.data)
        self.assertEqual((body["from"], body["to"]), ("books@example.com", ["me@kindle.com"]))
        self.assertEqual(base64.b64decode(body["attachments"][0]["content"]), self.book.read_bytes())

    def test_resend_check_rejects_invalid_key_but_accepts_send_only_key(self):
        def http_error(code, body):
            return ks.urllib.error.HTTPError("u", code, "x", {}, io.BytesIO(body))

        invalid = http_error(400, b'{"message":"API key is invalid","name":"validation_error"}')
        with mock.patch.object(ks.urllib.request, "urlopen", side_effect=invalid):
            with self.assertRaises(ks.DeliveryError):
                ks.ResendSender("a@x.com", "bad").check()
        restricted = http_error(401, b'{"message":"This API key is restricted","name":"restricted_api_key"}')
        with mock.patch.object(ks.urllib.request, "urlopen", side_effect=restricted):
            self.assertIn("send-only", ks.ResendSender("a@x.com", "ok").check()[0])

    def test_http_errors_become_delivery_errors(self):
        err = ks.urllib.error.HTTPError("u", 403, "Forbidden", {}, io.BytesIO(b'{"message":"bad key"}'))
        with mock.patch.object(ks.urllib.request, "urlopen", side_effect=err):
            with self.assertRaisesRegex(ks.DeliveryError, "403.*bad key"):
                ks.ResendSender("a@x.com", "k").send(self.msg)


class SendFlowTests(EnvTestCase):
    def test_batches_respect_provider_limit_and_history(self):
        self.write_config('kindle_email = "k@kindle.com"\nprovider = "icloud"\n[icloud]\nuser = "me@icloud.com"\npassword = "p"\n')
        books = [make_book(self.tmp, f"b{i}.epub", 8 * ks.MB) for i in range(3)]  # ~10.7 MB each encoded
        args = mock.Mock(items=[str(b) for b in books], file=None, dry_run=False, via=None,
                         out=None, no_images=False, yes=True, force=False)
        FakeSMTP.instances = []
        with mock.patch.object(ks.smtplib, "SMTP", FakeSMTP), redirect_stdout(io.StringIO()):
            ks.cmd_send(args)
        self.assertEqual([len(s.sent[0].get_payload()) - 1 for s in FakeSMTP.instances], [1, 1, 1])  # 20 MB cap
        FakeSMTP.instances = []
        with mock.patch.object(ks.smtplib, "SMTP", FakeSMTP), redirect_stdout(io.StringIO()):
            ks.cmd_send(args)
        self.assertEqual(FakeSMTP.instances, [])  # all skipped via history

    def test_batch_by_size(self):
        files = [make_book(self.tmp, f"f{i}.epub", 3 * ks.MB) for i in range(5)]  # ~4 MB encoded each
        self.assertEqual([len(b) for b in ks.batch_by_size(files, 10 * ks.MB)], [2, 2, 1])
        self.assertEqual([len(b) for b in ks.batch_by_size(files, 100 * ks.MB, max_count=2)], [2, 2, 1])


if __name__ == "__main__":
    unittest.main()
