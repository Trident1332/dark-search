#!/usr/bin/env python3
"""Release URLs must survive GitHub filename normalization and serve exact bytes."""

import hashlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_assets", ROOT / "scripts/check-release-assets.py")
ASSETS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ASSETS)


class ReleaseAssetTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.folder = Path(self.temporary.name)
        self.zip = b"synthetic app archive"
        self.dmg = b"synthetic disk image"
        (self.folder / "Search.zip").write_bytes(self.zip)
        (self.folder / "Search.dmg").write_bytes(self.dmg)
        self.feed = {
            "url": "https://github.com/example/browser/releases/download/test/Search.zip",
            "dmg": "https://github.com/example/browser/releases/download/test/Search.dmg",
            "sha256": hashlib.sha256(self.zip).hexdigest(),
            "dmgSha256": hashlib.sha256(self.dmg).hexdigest(),
        }

    def testRealFeedGeneratorNamesPortableMatchingDownloads(self):
        source = (ROOT / "build.sh").read_text()
        start = source.index("write_appcast() {")
        function = source[start:source.index('\nif [ "$STEP"', start)]
        # Run the real generator with tiny stand-ins, without building/signing an app.
        script = '''set -euo pipefail
OUT="$1"; BASE="https://github.com/example/browser/releases/download/test"
ZIP="$OUT/Dark Search.zip"; DMG="$OUT/Dark Search.dmg"
printf 'archive fixture' > "$ZIP"; printf 'image fixture' > "$DMG"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
VERSION=1.1.0; BUILD=202610300001; NOTES="fixture"; MINIMUM=14.0
AIBLOCK=""; ARCH=arm64; IDENTITY=""
write_engine() { :; }
'''
        subprocess.run(["/bin/bash", "-c", script + function + "\nwrite_appcast", "fixture", str(self.folder)],
                       check=True, capture_output=True)
        generated = json.loads((self.folder / "appcast.json").read_text())
        ASSETS.check(generated, self.folder)

    def testPortableAliasesPass(self):
        ASSETS.check(self.feed, self.folder)

    def testSpaceNamedLocalFileDoesNotProveGitHubURLWorks(self):
        (self.folder / "Dark Search.zip").write_bytes(self.zip)
        self.feed["url"] = self.feed["url"].replace("Search.zip", "Dark%20Search.zip")
        with self.assertRaisesRegex(ValueError, "portable"):
            ASSETS.check(self.feed, self.folder)

    def testLocalHashMismatchIsRejected(self):
        (self.folder / "Search.zip").write_bytes(b"different release")
        with self.assertRaisesRegex(ValueError, "local file"):
            ASSETS.check(self.feed, self.folder)

    def response(self, url, **kwargs):
        result = io.BytesIO(self.zip if url.endswith(".zip") else self.dmg)
        result.status = 200
        return result

    def testPublishedBytesMustMatchBothLocalArtifacts(self):
        with patch.object(ASSETS, "urlopen", side_effect=self.response) as fetch:
            ASSETS.check(self.feed, self.folder, live=True)
        self.assertEqual(fetch.call_count, 2)

    def testPublishedWrongBytesAreRejected(self):
        wrong = io.BytesIO(b"wrong")
        wrong.status = 200
        with patch.object(ASSETS, "urlopen", return_value=wrong):
            with self.assertRaisesRegex(ValueError, "published bytes"):
                ASSETS.check(self.feed, self.folder, live=True)

    def testPublishedOversizeResponseStopsAtLocalSize(self):
        oversized = io.BytesIO(b"x" * (3 << 20))
        oversized.status = 200
        with patch.object(ASSETS, "urlopen", return_value=oversized):
            with self.assertRaisesRegex(ValueError, "larger"):
                ASSETS.check(self.feed, self.folder, live=True)


if __name__ == "__main__":
    unittest.main()
