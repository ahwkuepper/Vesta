#!/usr/bin/env python3
"""Regression tests for untracked leaks, binary assets and redacted output."""
import contextlib
import hashlib
import importlib.util
import io
import pathlib
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("scanner", pathlib.Path(__file__).with_name("check_public_tree.py"))
scanner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scanner)


class PublicationChecks(unittest.TestCase):
    def test_untracked_file_and_redaction(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            subprocess.run(["git", "init", "-q", d], check=True)
            secret = "GOCSPX-" + "x" * 24
            (root / "not tracked.json").write_text('{"client_secret":"' + secret + '"}')
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertTrue(scanner.scan(root))
            self.assertIn("not tracked.json", output.getvalue())
            self.assertNotIn(secret, output.getvalue())

    def test_identifier_exception_cannot_hide_token(self):
        value = "ghp_" + "a" * 36 + " // check-no-secrets: allow"
        self.assertTrue(list(scanner.text_findings(value)))

    def test_synthetic_and_real_assignment(self):
        self.assertFalse(list(scanner.text_findings('"refresh_token":"persistent-test-token"')))
        key = '"refresh_token":'
        self.assertTrue(list(scanner.text_findings(key + '"a-real-secret-value"')))

    def test_binary_and_symlink_fail_closed(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            subprocess.run(["git", "init", "-q", d], check=True)
            (root / "credentials.bin").write_bytes(b"\x00private")
            (root / "external").symlink_to("/etc/hosts")
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                self.assertTrue(scanner.scan(root))
            self.assertIn("unreviewed binary", output.getvalue())
            self.assertIn("symlink requires review", output.getvalue())

    def test_reviewed_binary_change_requires_new_review(self):
        with tempfile.TemporaryDirectory() as d:
            root = pathlib.Path(d)
            subprocess.run(["git", "init", "-q", d], check=True)
            (root / "tools").mkdir()
            data = b"\x00reviewed fixture"
            (root / "asset.bin").write_bytes(data)
            (root / "tools/public-assets.sha256").write_text(hashlib.sha256(data).hexdigest() + "  asset.bin\n")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertFalse(scanner.scan(root))
                (root / "asset.bin").write_bytes(b"\x00changed fixture")
                self.assertTrue(scanner.scan(root))


if __name__ == "__main__":
    unittest.main()
