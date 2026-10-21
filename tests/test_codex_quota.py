import datetime as dt
import json
import os
from pathlib import Path
import tempfile
import time
import unittest

from scripts.codex_quota import QuotaError, RpcClient, account_hint, fetch_live, fetch_logs, normalize_window


class QuotaParsingTests(unittest.TestCase):
    def test_zero_is_available_not_unknown(self):
        self.assertEqual(normalize_window({'usedPercent': 0})['remainingPercent'], 100)
        self.assertIsNone(normalize_window({'usedPercent': None})['remainingPercent'])
        self.assertIsNone(normalize_window({})['remainingPercent'])

    def test_invalid_numbers_do_not_become_quota(self):
        for value in [True, '12', float('inf'), float('nan'), -1, 101]:
            with self.subTest(value=value):
                self.assertIsNone(normalize_window({'usedPercent': value})['remainingPercent'])

    def test_log_fields_and_fractional_remaining(self):
        value = normalize_window({'used_percent': 99.6, 'window_minutes': 300, 'resets_at': 1900000000}, True)
        self.assertAlmostEqual(value['remainingPercent'], .4)
        self.assertEqual(value['windowMinutes'], 300)
        self.assertEqual(value['resetsAt'], 1900000000)

    def test_account_hint_does_not_expose_full_email(self):
        self.assertEqual(account_hint({'email': 'private@example.com'}), 'pr***@example.com')
        self.assertIsNone(account_hint({'email': None}))

    def test_log_merge_uses_event_time_not_file_order_or_maximum(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            now = dt.datetime.now(dt.timezone.utc)
            def event(minutes, used, ident='codex'):
                return {'type': 'event_msg', 'timestamp': (now - dt.timedelta(minutes=minutes)).isoformat(),
                        'payload': {'type': 'token_count', 'rate_limits': {'limit_id': ident, 'primary': {'used_percent': used, 'window_minutes': 300}}}}
            # A later modified file contains an older observation with higher usage.
            first = root / 'rollout-a.jsonl'
            first.write_text(json.dumps(event(2, 5)) + '\n' + json.dumps(event(1, 0, 'other')) + '\n')
            second = root / 'rollout-b.jsonl'
            second.write_text('bad json\n' + json.dumps(event(20, 90)) + '\n' +
                              json.dumps({'type': 'event_msg', 'payload': 'malformed'}) + '\n' +
                              json.dumps({'type': 'event_msg', 'timestamp': now.isoformat(), 'payload': {'type': 'token_count', 'rate_limits': {'limit_id': 'codex', 'primary': None}}}) + '\n')
            os.utime(second, (time.time() + 1, time.time() + 1))
            value = fetch_logs(root)
            buckets = {item['limitId']: item for item in value['buckets']}
            self.assertEqual(buckets['codex']['primary']['remainingPercent'], 95)
            self.assertEqual(buckets['other']['primary']['remainingPercent'], 100)
            self.assertFalse(value['account']['identityVerified'])
            self.assertEqual(value['source'], 'logs')

    def test_empty_directory_is_not_zero_usage(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaises(QuotaError) as caught:
                fetch_logs(directory)
            self.assertEqual(caught.exception.code, 'no_snapshots')


class ProtocolTests(unittest.TestCase):
    def fake_cli(self, directory, body):
        executable = Path(directory) / 'fake-codex'
        executable.write_text('#!/usr/bin/env python3\n' + body)
        executable.chmod(0o700)
        return str(executable)

    def test_full_handshake_large_stderr_and_multibucket(self):
        script = '''import sys,json
sys.stderr.write('x'*200000);sys.stderr.flush()
for line in sys.stdin:
 m=json.loads(line);method=m['method']
 if 'id' not in m:continue
 if method=='initialize':r={'userAgent':'test'}
 elif method=='account/read':r={'account':{'type':'chatgpt','planType':'plus','email':'private@example.com'}}
 elif method=='account/rateLimits/read':r={'rateLimits':{'primary':{'usedPercent':99}},'rateLimitsByLimitId':{'codex':{'primary':{'usedPercent':16,'windowDurationMins':300}},'other':{'secondary':{'usedPercent':3,'windowDurationMins':10080}}}}
 print(json.dumps({'method':'account/rateLimits/updated','params':{}}),flush=True)
 print(json.dumps({'id':m['id'],'result':r}),flush=True)
'''
        with tempfile.TemporaryDirectory() as directory:
            value = fetch_live(binary=self.fake_cli(directory, script))
            self.assertEqual(len(value['buckets']), 2)
            self.assertEqual(value['buckets'][0]['primary']['remainingPercent'], 84)
            self.assertEqual(value['buckets'][1]['secondary']['remainingPercent'], 97)
            self.assertEqual(value['account']['label'], 'pr***@example.com')
            self.assertNotIn('private@example.com', json.dumps(value))

    def test_timeout_can_be_cancelled_and_process_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            client = RpcClient(self.fake_cli(directory, 'import time\ntime.sleep(30)\n'))
            try:
                with self.assertRaises(QuotaError) as caught:
                    client.call('initialize', {}, timeout=.15)
                self.assertEqual(caught.exception.code, 'timeout')
            finally:
                client.close()
            self.assertIsNotNone(client.proc.poll())

    def test_disallowed_methods_are_never_sent(self):
        with tempfile.TemporaryDirectory() as directory:
            client = RpcClient(self.fake_cli(directory, 'import time\ntime.sleep(30)\n'))
            try:
                with self.assertRaises(QuotaError):
                    client.send('turn/start', {})
                with self.assertRaises(QuotaError):
                    client.send('account/rateLimitResetCredit/consume', {})
            finally:
                client.close()


if __name__ == '__main__':
    unittest.main()
