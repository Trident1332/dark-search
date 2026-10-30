#!/usr/bin/env python3
"""Check the exact downloads named by a feed, locally and after publication."""

import argparse
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit
from urllib.request import urlopen


def check(feed, artifacts, live=False):
    for field, hash_field in (("url", "sha256"), ("dmg", "dmgSha256")):
        url = feed[field]
        parsed = urlsplit(url)
        name = unquote(parsed.path.rsplit("/", 1)[-1])
        # GitHub normalizes spaces and other characters in uploaded filenames.
        # A valid local filename alone therefore does not prove a usable URL.
        if (parsed.scheme != "https" or not parsed.netloc or parsed.query
                or parsed.fragment or not re.fullmatch(r"[A-Za-z0-9._-]+", name)
                or name in (".", "..")):
            raise ValueError(f"{field}: not a portable release asset URL: {url}")
        expected = feed[hash_field]
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError(f"{hash_field}: missing SHA-256")
        asset = artifacts / name
        size = asset.stat().st_size
        digest = hashlib.sha256()
        with asset.open("rb") as local:
            while block := local.read(1 << 20):
                digest.update(block)
        if digest.hexdigest() != expected:
            raise ValueError(f"{name}: local file does not match the feed hash")
        if live:
            digest, received = hashlib.sha256(), 0
            with urlopen(url, timeout=60) as response:
                if response.status != 200:
                    raise ValueError(f"{url}: HTTP {response.status}")
                while block := response.read(1 << 20):
                    received += len(block)
                    if received > size:
                        raise ValueError(f"{url}: larger than the local release artifact")
                    digest.update(block)
            if received != size or digest.hexdigest() != expected:
                raise ValueError(f"{url}: published bytes do not match the release artifact")
        print(f"verified {'published' if live else 'local'}: {name} ({size} bytes)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("feed", type=Path)
    parser.add_argument("--artifacts", type=Path)
    parser.add_argument("--live", action="store_true")
    args = parser.parse_args()
    try:
        check(json.loads(args.feed.read_text()), args.artifacts or args.feed.parent, args.live)
    except (KeyError, OSError, ValueError) as error:
        parser.exit(1, f"release assets: {error}\n")


if __name__ == "__main__":
    main()
