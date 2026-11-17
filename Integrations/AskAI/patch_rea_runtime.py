#!/usr/bin/env python3
"""Narrow, repeatable patch for Search's private MIT-licensed REA 6.7 runtime.

Does not modify Hopper, license files, global npm packages, or agent config.
"""
import argparse
import hashlib
import json
import os
import stat
from pathlib import Path

PRIVATE = Path.home() / 'Library/Application Support/Search/Tools/rea'
PATCHES = [
    (
        'join("/tmp", `rea-hopper-${process.getuid?.() ?? 0}`)',
        'join(process.env.TMPDIR || "/tmp", `.rea-hopper-${process.getuid?.() ?? 0}`)',
        ['dist/process/HopperLease.js', 'dist/mcp/main-Cx-Z7m_n.js',
         'dist/cli-runtime/SharedStartupAttempt-BxKyf3Uv.js'],
    ),
    (
        'process.platform === "darwin" ? "/tmp" : tmpdir()',
        '(process.env.SEARCH_HOPPER_ISOLATED === "1" ? tmpdir() : (process.platform === "darwin" ? "/tmp" : tmpdir()))',
        ['dist/hopper/HopperClient.js', 'dist/mcp/main-Cx-Z7m_n.js',
         'dist/cli-runtime/binary-CWVNJhAC.js'],
    ),
    (
        'const ownsProcessLifetime = usesLinuxDemo(this.options);',
        'const ownsProcessLifetime = usesLinuxDemo(this.options) || (this.options.environment.SEARCH_HOPPER_ISOLATED === "1" && this.options.launcherPath.endsWith("/search-hopper-offline-launcher"));',
        ['dist/hopper/BridgeLauncher.js', 'dist/mcp/main-Cx-Z7m_n.js',
         'dist/cli-runtime/binary-CWVNJhAC.js'],
    ),
]



def patch(package: Path, apply: bool) -> dict:
    private = PRIVATE.resolve(strict=True)
    if private != PRIVATE.absolute():
        raise ValueError('Search\'s private REA root must not redirect through a symlink')
    package = package.resolve(strict=True)
    if not package.is_relative_to(private):
        raise ValueError('Only Search\'s private REA installation may be patched')
    metadata = json.loads((package / 'package.json').read_text())
    if metadata.get('name') != 'rea-agents' or metadata.get('version') != '6.7.0':
        raise ValueError('This patch supports rea-agents 6.7.0 exactly')
    prepared = []
    relatives = sorted({relative for _, _, files in PATCHES for relative in files})
    for relative in relatives:
        file = package / relative
        identity = file.lstat()
        if (not stat.S_ISREG(identity.st_mode) or identity.st_nlink != 1
                or identity.st_uid != os.getuid()
                or not file.resolve(strict=True).is_relative_to(package)):
            raise ValueError(f'Untrusted package source path {relative}; no files changed')
        original = file.read_bytes()
        text = original.decode('utf-8')
        already = True
        for old, new, files in PATCHES:
            if relative not in files:
                continue
            if text.count(new) == 1 and text.replace(new, '').count(old) == 0:
                continue
            if text.count(new) != 0 or text.count(old) != 1:
                raise ValueError(f'Unexpected source shape in {relative}; no files changed')
            text = text.replace(old, new)
            already = False
        prepared.append((file, relative, original, text.encode('utf-8'), already))
    changes = []
    for file, relative, original, replacement, already in prepared:
        before, after = hashlib.sha256(original).hexdigest(), hashlib.sha256(replacement).hexdigest()
        if apply and not already:
            backups = package / '.search-patches'
            backups.mkdir(mode=0o700, exist_ok=True)
            if backups.resolve(strict=True) != backups:
                raise ValueError('The private backup folder must not be a symlink')
            backup = backups / (before + '.original')
            if not backup.exists():
                descriptor = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(descriptor, 'wb') as stream:
                    stream.write(original)
            temporary = file.with_suffix(file.suffix + '.search-tmp')
            with temporary.open('xb') as stream:
                stream.write(replacement)
                stream.flush()
                os.fsync(stream.fileno())
            temporary.chmod(file.stat().st_mode & 0o777)
            temporary.replace(file)
        changes.append({'file': relative, 'beforeSha256': before, 'afterSha256': after,
                        'alreadyApplied': already, 'applied': apply})
    report = {'package': str(package), 'version': '6.7.0', 'patch': 'search-private-hopper-isolation-2',
              'purpose': 'Private sockets and verified child-owned offline Hopper lifetime',
              'changes': changes, 'hopperModified': False, 'licenseModified': False}
    if apply:
        manifest = {'format': 'search-rea-runtime-1', 'version': '6.7.0',
                    'patch': 'search-private-hopper-isolation-2',
                    'files': {item['file']: item['afterSha256'] for item in changes}}
        folder = package / '.search-patches'
        folder.mkdir(mode=0o700, exist_ok=True)
        if folder.resolve(strict=True) != folder:
            raise ValueError('The private patch manifest folder must not be a symlink')
        destination = folder / 'manifest.json'
        temporary = folder / 'manifest.json.tmp'
        with temporary.open('x') as stream:
            json.dump(manifest, stream, indent=2)
            stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
        temporary.chmod(0o600)
        temporary.replace(destination)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, default=PRIVATE / 'node_modules/rea-agents')
    parser.add_argument('--apply', action='store_true')
    options = parser.parse_args()
    print(json.dumps(patch(options.package, options.apply), indent=2))
