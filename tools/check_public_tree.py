#!/usr/bin/env python3
"""Publication gate: reports locations/categories, never matched secret values.

Git-ignored files are not publication candidates. Binary assets require a reviewed
SHA-256 in public-assets.sha256. This is a leak detector, not proof of secrecy.
"""
import hashlib
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SECRET_PATTERNS = {
    "private key": r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----",
    "Google credential": r"\b(?:GOCSPX-[A-Za-z0-9_-]{12,}|ya29\.[A-Za-z0-9._-]{20,}|1//[A-Za-z0-9_-]{20,})",
    "GitHub credential": r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})",
    "AWS access key": r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    "Google OAuth client": r"\b[0-9]{6,}-[a-z0-9]{12,}\.apps\.googleusercontent\.com\b",
    "credential assignment": r'''(?i)["']?(?:refresh_token|client_secret|password|access_token)["']?\s*[:=]\s*["']([^"'\n]{8,})["']''',
    "authorization URL": r"https://www\.google\.com/?\?[^\s\"<>]*code=([A-Za-z0-9_/-]{12,})",
}
IDENTIFIERS = re.compile(
    r"192\.168\.[0-9]|10\.[0-9]+\.[0-9]+\.[0-9]+|172\.(?:1[6-9]|2[0-9]|3[01])\."
    r"|(?:[0-9a-f]{2}:){5}[0-9a-f]{2}|latitude_i\"?[: ]+-?[0-9]{4,}|longitude_i\"?[: ]+-?[0-9]{4,}"
    r"|[0-9a-f]{6}fffe[0-9a-f]{6}|[0-9a-f]{12}\.local|(?:[0-9a-f]{1,4}:){4,}[0-9a-f]{0,4}", re.I)
SYNTHETIC_IDS = {"aa:bb:cc:11:22:33", "aa:bb:cc:dd:ee:ff", "aabbccfffe112233", "aabbcc112233.local"}
SYNTHETIC_CREDENTIALS = {"synthetic", "synthetic-test-password", "temporary-test-token", "persistent-test-token", "renewed-test-token"}


def text_findings(text):
    for number, line in enumerate(text.splitlines(), 1):
        for category, pattern in SECRET_PATTERNS.items():
            for match in re.finditer(pattern, line):
                if category == "authorization URL" and match.group(1) == "one-use-test-code":
                    continue
                if category == "credential assignment" and match.group(1) in SYNTHETIC_CREDENTIALS:
                    continue
                yield number, category
        # The explicit marker permits intentional LAN range tests, never secrets.
        if "check-no-secrets: allow" not in line:
            for match in IDENTIFIERS.finditer(line):
                if match.group().lower() not in SYNTHETIC_IDS:
                    yield number, "home/network identifier"


def scan(root):
    names = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root
    ).decode().split("\0")
    assets = {}
    manifest = root / "tools/public-assets.sha256"
    if manifest.exists():
        for line in manifest.read_text().splitlines():
            if line and not line.startswith("#"):
                digest, name = line.split("  ", 1)
                assets[name] = digest
    failures = []
    text_count = binary_count = 0
    for name in sorted(set(filter(None, names))):
        path = root / name
        if path.is_symlink():
            failures.append((name, 0, "symlink requires review"))
            continue
        if not path.exists():
            continue
        if not path.is_file():
            failures.append((name, 0, "non-file requires review"))
            continue
        data = path.read_bytes()
        try:
            text = data.decode("utf-8")
            if "\0" in text:
                raise UnicodeError()
        except UnicodeError:
            binary_count += 1
            if assets.get(name) != hashlib.sha256(data).hexdigest():
                failures.append((name, 0, "unreviewed binary asset"))
            continue
        text_count += 1
        failures.extend((name, line, category) for line, category in text_findings(text))
    for name, line, category in failures:
        print(f"{name!r}:{line}: {category}")
    print(f"Checked {text_count} text files and {binary_count} binary assets (tracked + untracked); {len(failures)} findings.")
    return bool(failures)


if __name__ == "__main__":
    if len(sys.argv) != 1:
        sys.exit("usage: tools/check-no-secrets.sh")
    sys.exit(scan(ROOT))
