#!/usr/bin/env python3
"""Bundle the authenticated, pinned Tor engine; run --self-test offline.

Vendor signatures for these pins were verified against the Tor Browser
Developers primary key; see ThirdParty/Tor/README.md. Every build verifies
the complete archive before reading or executing any of its contents.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from urllib.request import urlopen


VERSION = "15.0.26"
TOR_VERSION = "0.4.9.14"
SIGNER = "EF6E286DDA85EA2A4BA7DE684E2C6E8793298290"
ARCHIVES = {
    "arm64": ("aarch64", "a3febb6179152b0b4f56a0f5cc57bf5cc8ecef7db35e7c3e9d5a044c8158c26c"),
    "x86_64": ("x86_64", "e1ae4d4a734d28bb590839188511deb3cebc26fcbce9df66d01b2c452060fe95"),
}
FILES = {
    "tor/tor": "tor",
    "tor/libevent-2.1.7.dylib": "libevent-2.1.7.dylib",
    "docs/tor.txt": "licenses/tor.txt",
    "docs/libevent.txt": "licenses/libevent.txt",
    "docs/openssl.txt": "licenses/openssl.txt",
}
MAX_ARCHIVE = 64 * 1024 * 1024
MAX_EXPANDED = 128 * 1024 * 1024
ROOT = Path(__file__).resolve().parent.parent


class BundleError(Exception):
    pass


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def archive_for(arch, cache):
    platform, expected = ARCHIVES[arch]
    name = f"tor-expert-bundle-macos-{platform}-{VERSION}.tar.gz"
    url = f"https://dist.torproject.org/torbrowser/{VERSION}/{name}"
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / name
    if path.is_symlink():
        raise BundleError(f"Refusing a symlink in the Tor archive cache: {path}")
    if not path.exists():
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(dir=cache, prefix=".tor-", delete=False) as output:
                temporary = Path(output.name)
                with urlopen(url, timeout=90) as response:
                    size = 0
                    for chunk in iter(lambda: response.read(1024 * 1024), b""):
                        size += len(chunk)
                        if size > MAX_ARCHIVE:
                            raise BundleError("The Tor archive exceeds its download size limit")
                        output.write(chunk)
            if digest(temporary) != expected:
                raise BundleError("The downloaded Tor archive does not match its authenticated hash")
            os.replace(temporary, path)
            temporary = None
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)
    if path.stat().st_size > MAX_ARCHIVE or digest(path) != expected:
        raise BundleError(f"The cached Tor archive has an unexpected hash; remove it and retry: {path}")
    return path, url, expected


def checked_members(archive):
    members = {}
    expanded = 0
    for member in archive.getmembers():
        path = PurePosixPath(member.name)
        if (path.is_absolute() or ".." in path.parts or "\\" in member.name
                or not path.parts or member.name in members):
            raise BundleError("The Tor archive contains an unsafe or duplicate path")
        if not member.isfile() and not member.isdir():
            raise BundleError("The Tor archive contains a link or unsupported entry")
        expanded += member.size
        if member.size < 0 or expanded > MAX_EXPANDED:
            raise BundleError("The Tor archive exceeds its expanded size limit")
        members[member.name] = member
    if any(name not in members or not members[name].isfile() for name in FILES):
        raise BundleError("The Tor archive is missing an expected engine or license file")
    return members


def copy_payload(archive_path, destination):
    with tarfile.open(archive_path, "r:gz") as archive:
        members = checked_members(archive)
        for source, relative in FILES.items():
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.extractfile(members[source]) as incoming, target.open("xb") as output:
                shutil.copyfileobj(incoming, output)
            target.chmod(0o755 if relative in ("tor", "libevent-2.1.7.dylib") else 0o644)


def sign_payload(destination, arch, identity):
    binaries = [destination / "libevent-2.1.7.dylib", destination / "tor"]
    for path in binaries:
        actual = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], text=True).strip()
        if actual != arch:
            raise BundleError(f"The Tor payload architecture is {actual}, expected {arch}")
        linked = subprocess.check_output(["/usr/bin/otool", "-L", str(path)], text=True).splitlines()[1:]
        # A dylib's first entry is its own install name, not a dependency.
        if path.suffix == ".dylib":
            linked = linked[1:]
        for line in linked:
            dependency = line.strip().split(" (", 1)[0]
            if (dependency != "@executable_path/libevent-2.1.7.dylib"
                    and not dependency.startswith(("/usr/lib/", "/System/Library/"))):
                raise BundleError(f"The Tor engine has an unbundled dependency: {dependency}")
        subprocess.run(["/usr/bin/codesign", "--force", "--options", "0", "--sign", identity, str(path)], check=True)

    # Developer ID helpers use the hardened runtime. A local, self-signed
    # identity has no Apple Team ID; library validation would reject its
    # own libevent even though both signatures use the same certificate.
    details = subprocess.run(["/usr/bin/codesign", "-dv", "--verbose=2", str(destination / "tor")],
                             capture_output=True, text=True, check=True).stderr
    has_team = any(line.startswith("TeamIdentifier=") and line.partition("=")[2] not in ("", "not set")
                   for line in details.splitlines())
    if has_team:
        for path in binaries:
            subprocess.run(["/usr/bin/codesign", "--force", "--timestamp", "--options", "runtime",
                            "--sign", identity, str(path)], check=True)
    for path in binaries:
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True)


def bundle(arch, destination, cache, identity):
    if destination.exists() or destination.is_symlink():
        raise BundleError(f"Refusing to replace an existing Tor payload: {destination}")
    archive, source, expected = archive_for(arch, cache)
    destination.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=".tor-bundle-", dir=destination.parent))
    try:
        copy_payload(archive, staging)
        shutil.copyfile(ROOT / "ThirdParty/Tor/GPL-3.0.txt", staging / "licenses/GPL-3.0.txt")
        shutil.copyfile(ROOT / "ThirdParty/Tor/README.md", staging / "README.md")
        (staging / "version.json").write_text(json.dumps({
            "expertBundle": VERSION, "tor": TOR_VERSION, "architecture": arch,
            "source": source, "archiveSHA256": expected, "vendorSigningKey": SIGNER,
        }, indent=2) + "\n", encoding="utf-8")
        sign_payload(staging, arch, identity)
        staging.rename(destination)
        staging = None
    finally:
        if staging is not None:
            shutil.rmtree(staging)
    print(f"Tor {TOR_VERSION}: verified and bundled for {arch}")


class ArchiveTests(unittest.TestCase):
    def archive(self, extra=None, missing=None):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:gz") as archive:
            for name in FILES:
                if name == missing:
                    continue
                entry = tarfile.TarInfo(name)
                entry.size = 4
                archive.addfile(entry, io.BytesIO(b"test"))
            if extra is not None:
                archive.addfile(extra)
        stream.seek(0)
        return tarfile.open(fileobj=stream, mode="r:gz")

    def test_expected_files(self):
        with self.archive() as archive:
            self.assertEqual(set(checked_members(archive)), set(FILES))

    def test_parent_traversal_is_rejected(self):
        with self.archive(tarfile.TarInfo("../outside")) as archive:
            with self.assertRaises(BundleError): checked_members(archive)

    def test_absolute_path_is_rejected(self):
        with self.archive(tarfile.TarInfo("/outside")) as archive:
            with self.assertRaises(BundleError): checked_members(archive)

    def test_symlink_is_rejected(self):
        entry = tarfile.TarInfo("link")
        entry.type = tarfile.SYMTYPE
        entry.linkname = "../outside"
        with self.archive(entry) as archive:
            with self.assertRaises(BundleError): checked_members(archive)

    def test_duplicate_file_is_rejected(self):
        with self.archive(tarfile.TarInfo("tor/tor")) as archive:
            with self.assertRaises(BundleError): checked_members(archive)

    def test_missing_engine_is_rejected(self):
        with self.archive(missing="tor/tor") as archive:
            with self.assertRaises(BundleError): checked_members(archive)

    def test_tampered_cached_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = Path(directory)
            (cache / f"tor-expert-bundle-macos-aarch64-{VERSION}.tar.gz").write_bytes(b"tampered")
            with self.assertRaises(BundleError): archive_for("arm64", cache)

    def test_existing_payload_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "Tor"
            output.mkdir()
            marker = output / "keep"
            marker.write_bytes(b"existing")
            with self.assertRaises(BundleError): bundle("arm64", output, Path(directory), "-")
            self.assertEqual(marker.read_bytes(), b"existing")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--arch", choices=ARCHIVES)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--cache", type=Path, default=ROOT / ".build/tor-downloads")
    parser.add_argument("--identity", default="-")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(ArchiveTests)
        return 0 if unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful() else 1
    if not args.arch or not args.output:
        parser.error("--arch and --output are required")
    try:
        bundle(args.arch, args.output.absolute(), args.cache.absolute(), args.identity)
    except (BundleError, OSError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f"Tor bundling failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
