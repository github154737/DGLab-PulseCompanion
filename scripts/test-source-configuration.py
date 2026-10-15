"""Offline tests for deployment configuration and candidate-source scanning."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from cloud_configuration import deployment, relay_base, certificate_san

spec = importlib.util.spec_from_file_location('source_audit', Path(__file__).with_name('check-source-release.py'))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class SourceConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.environ = patch.dict(os.environ, {'AIHAPTICS_CLOUD_HOME':str(self.root),
            'AIHAPTICS_DEPLOYMENT_CONFIG':str(self.root/'deployment.json')})
        self.environ.start()
        self.addCleanup(self.environ.stop)

    def write(self, **values):
        config = {'host':'relay.example.com','ssh_user':'operator','ssh_port':22,
                  'ssh_key':'~/.ssh/fixture_key','proxy_host':'','proxy_port':0}
        config.update(values)
        (self.root/'deployment.json').write_text(json.dumps(config))

    def test_missing_configuration_does_not_use_shared_host(self):
        with self.assertRaises(FileNotFoundError): deployment()

    def test_valid_metadata_and_certificate_names(self):
        self.write()
        self.assertEqual(deployment()['host'], 'relay.example.com')
        self.assertTrue(certificate_san('relay.example.com').startswith('DNS:'))
        self.assertTrue(certificate_san('192.0.2.1').startswith('IP:'))

    def test_invalid_host_and_ports_rejected(self):
        for host in ['example.com;echo nope','https://example.com','a\nb','']:
            self.write(host=host)
            with self.assertRaises(ValueError): deployment()
        for port in [True, -1, 65536, '22', 0]:
            self.write(ssh_port=port)
            with self.assertRaises(ValueError): deployment()

    def test_relay_url_config_and_https_enforced(self):
        (self.root/'android-defines.json').write_text(json.dumps({'VENICE_RELAY_URL':'https://relay.example.com/api/v1/'}))
        with patch.dict(os.environ, {'AIHAPTICS_RELAY_URL':''}):
            self.assertEqual(relay_base(), 'https://relay.example.com/api/v1')
        for url in ['http://example.com','https://a:b@example.com','https://example.com/?token=fixture']:
            with patch.dict(os.environ, {'AIHAPTICS_RELAY_URL':url}):
                with self.assertRaises(ValueError): relay_base()

    def test_secret_audit_returns_rule_names_not_values(self):
        marker=b'fixture-secret-for-audit'
        result=audit.inspect(marker,[marker])
        self.assertEqual(result,['private_configuration_value'])
        self.assertNotIn(marker.decode(),str(result))
        self.assertEqual(audit.inspect(b'public example',[]),[])

    def test_private_key_marker_detected(self):
        value=('-----BEGIN '+'OPENSSH PRIVATE KEY-----').encode()
        self.assertIn('private_key',audit.inspect(value,[]))


if __name__ == '__main__': unittest.main()
