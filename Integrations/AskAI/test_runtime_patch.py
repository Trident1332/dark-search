import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('patch_rea_runtime', Path(__file__).with_name('patch_rea_runtime.py'))
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)


class RuntimePatchTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name).resolve()
        self.private = self.root / 'private'
        self.package = self.private / 'node_modules/rea-agents'
        self.package.mkdir(parents=True)
        self.old_private = patcher.PRIVATE
        patcher.PRIVATE = self.private
        (self.package / 'package.json').write_text(json.dumps({'name': 'rea-agents', 'version': '6.7.0'}))
        (self.package / 'LICENSE').write_text('MIT license fixture, preserved verbatim\n')
        relatives = {relative for _, _, files in patcher.PATCHES for relative in files}
        for relative in relatives:
            file = self.package / relative
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('\n'.join(old for old, _, files in patcher.PATCHES if relative in files))

    def tearDown(self):
        patcher.PRIVATE = self.old_private
        self.directory.cleanup()

    def contents(self):
        return {str(file.relative_to(self.package)): file.read_bytes()
                for file in self.package.rglob('*') if file.is_file()}

    def test_dry_run_changes_nothing_and_creates_no_manifest(self):
        before = self.contents()
        result = patcher.patch(self.package, False)
        self.assertEqual(len(result['changes']), 6)
        self.assertEqual(before, self.contents())
        self.assertFalse((self.package / '.search-patches').exists())

    def test_apply_is_idempotent_with_verifiable_manifest_and_preserves_license(self):
        license_before = (self.package / 'LICENSE').read_bytes()
        patcher.patch(self.package, True)
        manifest = json.loads((self.package / '.search-patches/manifest.json').read_text())
        self.assertEqual(manifest['patch'], 'search-private-hopper-isolation-2')
        self.assertEqual(len(manifest['files']), 6)
        for relative, digest in manifest['files'].items():
            self.assertEqual(hashlib.sha256((self.package / relative).read_bytes()).hexdigest(), digest)
        first = self.contents()
        result = patcher.patch(self.package, True)
        self.assertTrue(all(change['alreadyApplied'] for change in result['changes']))
        self.assertEqual(first, self.contents())
        self.assertEqual(license_before, (self.package / 'LICENSE').read_bytes())

    def test_unknown_version_leaves_all_sources_unchanged(self):
        (self.package / 'package.json').write_text(json.dumps({'name': 'rea-agents', 'version': '6.8.0'}))
        before = self.contents()
        with self.assertRaises(ValueError): patcher.patch(self.package, True)
        self.assertEqual(before, self.contents())

    def test_unexpected_source_shape_is_rejected_before_any_write(self):
        relative = 'dist/process/HopperLease.js'
        (self.package / relative).write_text('unexpected source tree')
        before = self.contents()
        with self.assertRaises(ValueError): patcher.patch(self.package, True)
        self.assertEqual(before, self.contents())

    def test_external_package_and_symlinked_private_root_are_rejected(self):
        external = self.root / 'global'
        external.mkdir()
        with self.assertRaises(ValueError): patcher.patch(external, True)
        alias = self.root / 'alias'
        alias.symlink_to(self.private, target_is_directory=True)
        patcher.PRIVATE = alias
        with self.assertRaises(ValueError): patcher.patch(self.package, True)

    def test_source_symlink_cannot_read_or_modify_an_external_file(self):
        file = self.package / 'dist/process/HopperLease.js'
        original = file.read_bytes()
        outside = self.root / 'global-source.js'
        outside.write_bytes(original)
        file.unlink();file.symlink_to(outside)
        with self.assertRaises(ValueError): patcher.patch(self.package, True)
        self.assertEqual(outside.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
