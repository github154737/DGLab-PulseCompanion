"""Offline release tooling regression tests with temporary repositories and archives."""
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


def load(name):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(name+'.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


export = load('export-connection')
audit = load('check-source-release')
apk = load('verify-public-apk')


class ReleaseToolsTests(unittest.TestCase):
    def test_git_scan_reads_compressed_archive_from_index_and_history(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            def git(*args):
                return subprocess.check_output(['git', *args], cwd=root, stderr=subprocess.DEVNULL)
            git('init')
            marker = b'compressed-synthetic-sensitive-marker'
            with zipfile.ZipFile(root/'fixture.zip', 'w', compression=zipfile.ZIP_DEFLATED) as z:
                z.writestr('config.txt', marker)
            git('add', 'fixture.zip')
            (root/'fixture.zip').unlink()
            with patch.object(audit, 'load_private_markers', return_value=[marker]):
                self.assertFalse(audit.audit_git_objects(root)['ok'])
                git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                    '-c', 'commit.gpgsign=false', 'commit', '-m', 'synthetic archive')
                self.assertFalse(audit.audit_git_objects(root, history=True)['ok'])

    def test_connection_export_does_not_copy_build_secrets_or_roles(self):
        result = export.connection(dict(VENICE_RELAY_URL='https://relay.example.com/api/v1',
            VENICE_RELAY_TOKEN='fixture-token', PILOT_ADMIN_HASH='fixture', APP_EDITION='pilot'))
        self.assertEqual(set(result), {'format','version','url','token','certificate'})
        self.assertEqual(result['version'],1)

    def test_connection_export_rejects_personal_key_http_and_header_injection(self):
        for url,token in [('http://example.com','fixture'),('https://example.com','VENICE_INFERENCE_KEY_fixture'),
                          ('https://example.com','x\ny'),('https://u:p@example.com','fixture')]:
            with self.assertRaises(ValueError): export.connection(dict(VENICE_RELAY_URL=url,VENICE_RELAY_TOKEN=token))

    def test_staged_and_history_scan_inspects_blobs_not_current_worktree(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            def git(*args):
                return subprocess.check_output(['git',*args],cwd=root,stderr=subprocess.DEVNULL)
            git('init')
            marker=b'only-a-synthetic-sensitive-marker'
            (root/'fixture.txt').write_bytes(marker)
            git('add','fixture.txt')
            (root/'fixture.txt').write_text('clean working tree')
            with patch.object(audit,'load_private_markers',return_value=[marker]):
                self.assertFalse(audit.audit_git_objects(root)['ok'])
                git('-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-m','synthetic')
                self.assertFalse(audit.audit_git_objects(root,history=True)['ok'])
                git('add','fixture.txt')
                self.assertTrue(audit.audit_git_objects(root)['ok'])

    def test_public_apk_content_accepts_public_bundle_rejects_private_wave_or_secret(self):
        def build(wave_name='README.txt', extra=b''):
            buffer=io.BytesIO()
            waves=io.BytesIO()
            with zipfile.ZipFile(waves,'w') as z: z.writestr(wave_name,'fixture')
            with zipfile.ZipFile(buffer,'w') as z:
                for abi in ['arm64-v8a','x86_64']:
                    for lib in ['libapp.so','libflutter.so','libhaptics_core.so']:
                        z.writestr(f'lib/{abi}/{lib}',b'fixture'+extra)
                z.writestr('assets/flutter_assets/assets/user-waveforms.zip',waves.getvalue())
                z.writestr('assets/flutter_assets/assets/rust-third-party-notices.txt','fixture notice')
            buffer.seek(0)
            return buffer
        self.assertEqual(apk.inspect_archive(build(),[]),[])
        self.assertIn('private_wave_bundle',apk.inspect_archive(build('private.pulse'),[]))
        self.assertTrue(apk.inspect_archive(build(extra=b'fixture-secret'),[b'fixture-secret']))


if __name__ == '__main__': unittest.main()
