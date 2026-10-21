#!/usr/bin/env python3
"""Read Codex quota metadata through its local CLI. Never reads auth files."""
import argparse
import datetime as dt
import json
import math
import os
from pathlib import Path
import selectors
import shutil
import signal
import subprocess
import time


class QuotaError(Exception):
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


def utc_now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def number(value):
    return value if not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value) else None


def short_text(value):
    return value[:100] if isinstance(value, str) else None


def account_hint(account):
    email = account.get('email')
    if not isinstance(email, str) or '@' not in email:
        return None
    name, domain = email.rsplit('@', 1)
    return name[:2] + '***@' + domain[:80]


def normalize_window(value, log_format=False):
    if not isinstance(value, dict):
        return None
    used = number(value.get('used_percent' if log_format else 'usedPercent'))
    mins = number(value.get('window_minutes' if log_format else 'windowDurationMins'))
    reset = number(value.get('resets_at' if log_format else 'resetsAt'))
    valid = used is not None and 0 <= used <= 100
    return {'usedPercent': used if valid else None,
            'remainingPercent': 100 - used if valid else None,
            'windowMinutes': mins if mins and 0 < mins <= 525600 else None,
            'resetsAt': reset if reset and 0 < reset <= 253402300799 else None,
            'invalid': used is not None and not valid}


def normalize_bucket(value, limit_id, log_format=False):
    key = lambda a, b: value.get(a if log_format else b)
    return {'limitId': str(limit_id)[:100],
            'limitName': short_text(key('limit_name', 'limitName')),
            'planType': short_text(key('plan_type', 'planType')),
            'primary': normalize_window(value.get('primary'), log_format),
            'secondary': normalize_window(value.get('secondary'), log_format),
            'otherLimitsPresent': key('individual_limit', 'individualLimit') is not None,
            'spendControlReached': key('spend_control_reached', 'spendControlReached'),
            'rateLimitReachedType': key('rate_limit_reached_type', 'rateLimitReachedType')}


def discover_cli():
    found = shutil.which('codex')
    if found:
        return found
    for item in ['/opt/homebrew/bin/codex', '/usr/local/bin/codex',
                 '/Applications/Codex.app/Contents/Resources/codex',
                 '/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex']:
        if Path(item).is_file() and os.access(item, os.X_OK):
            return item
    raise QuotaError('cli_missing', '未找到 Codex CLI，请先安装或配置命令路径。')


class RpcClient:
    ALLOWED = {'initialize', 'initialized', 'account/read', 'account/rateLimits/read'}

    def __init__(self, binary, transport='stdio'):
        args = [binary, 'app-server']
        args += ['proxy'] if transport == 'proxy' else ['--stdio', '-c', 'analytics.enabled=false']
        self.proc = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, start_new_session=True)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.proc.stdout, selectors.EVENT_READ, 'out')
        self.selector.register(self.proc.stderr, selectors.EVENT_READ, 'err')
        self.pending = {}
        self.buffer = b''
        self.stderr = b''
        self.counter = 0

    def send(self, method, params=None, notify=False):
        if method not in self.ALLOWED:
            raise QuotaError('method_denied', '探测程序只允许账号与额度读取。')
        request = {'method': method}
        if params is not None:
            request['params'] = params
        if not notify:
            self.counter += 1
            request['id'] = self.counter
        try:
            self.proc.stdin.write((json.dumps(request) + '\n').encode())
            self.proc.stdin.flush()
        except (OSError, ValueError):
            raise QuotaError('process_exited', 'Codex 进程已退出，尚未取得额度。')
        return request.get('id')

    def call(self, method, params=None, timeout=10):
        request_id = self.send(method, params)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if request_id in self.pending:
                value = self.pending.pop(request_id)
                if 'error' in value:
                    message = str(value['error'].get('message', '')).lower()
                    if any(s in message for s in ['auth', 'logged in', 'chatgpt account']):
                        raise QuotaError('auth_required', '此 Codex CLI 未提供可用的 ChatGPT 登录态。')
                    if 'method not found' in message or 'unsupported' in message:
                        raise QuotaError('unsupported', '当前 CLI 版本不支持该额度查询。')
                    raise QuotaError('query_failed', 'Codex 返回查询错误，未取得新的额度。')
                return value.get('result') or {}
            events = self.selector.select(min(0.2, max(0, deadline - time.monotonic())))
            for key, _ in events:
                chunk = os.read(key.fd, 65536)
                if not chunk:
                    self.selector.unregister(key.fileobj)
                    continue
                if key.data == 'err':
                    self.stderr = (self.stderr + chunk)[-16384:]
                    continue
                self.buffer += chunk
                if len(self.buffer) > 2 * 1024 * 1024:
                    raise QuotaError('response_too_large', 'Codex 响应超过安全读取上限。')
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    try:
                        value = json.loads(line)
                    except (ValueError, UnicodeError):
                        continue
                    if isinstance(value, dict) and isinstance(value.get('id'), int):
                        self.pending[value['id']] = value
                        if len(self.pending) > 64:
                            raise QuotaError('response_too_large', 'Codex 返回过多未匹配响应。')
            if self.proc.poll() is not None and not self.selector.get_map():
                if b'Operation not permitted' in self.stderr or b'Permission denied' in self.stderr:
                    raise QuotaError('permission_denied', '当前运行环境阻止 Codex 启动或连接本机服务。')
                raise QuotaError('process_exited', 'Codex 服务未能启动或本机服务未运行。')
        raise QuotaError('timeout', '额度查询超时，尚未取得新数据。')

    def close(self):
        # Only signal the process group created by this client; never other Codex processes.
        try:
            os.killpg(self.proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            self.proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(self.proc.pid, signal.SIGKILL)
            self.proc.wait(timeout=2)
        self.selector.close()
        for stream in [self.proc.stdin, self.proc.stdout, self.proc.stderr]:
            stream.close()


def fetch_live(transport='stdio', binary=None):
    client = RpcClient(binary or discover_cli(), transport)
    try:
        client.call('initialize', {'clientInfo': {'name': 'usagebar_local_preview', 'version': '0.1.0'}}, timeout=6)
        client.send('initialized', {}, notify=True)
        info = client.call('account/read', {'refreshToken': False}, timeout=6)
        account = info.get('account') or {}
        if not isinstance(account, dict):
            account = {}
        result = client.call('account/rateLimits/read', timeout=10)
        values = result.get('rateLimitsByLimitId')
        if not isinstance(values, dict):
            legacy = result.get('rateLimits')
            values = {legacy.get('limitId') or 'legacy': legacy} if isinstance(legacy, dict) else {}
        buckets = [normalize_bucket(v, k) for k, v in values.items() if isinstance(v, dict)]
        if not buckets:
            raise QuotaError('no_quota', '服务端未返回可展示的套餐额度。')
        for bucket in buckets:
            bucket['planType'] = bucket.get('planType') or short_text(account.get('planType'))
        return {'ok': True, 'source': 'live', 'transport': transport, 'observedAt': utc_now(),
                'account': {'type': short_text(account.get('type')), 'planType': short_text(account.get('planType')),
                            'label': account_hint(account),
                            'identityVerified': False}, 'buckets': buckets}
    finally:
        client.close()


def fetch_logs(root=None):
    base = Path(root) if root else Path(os.environ.get('CODEX_HOME', str(Path.home() / '.codex'))) / 'sessions'
    if not base.is_dir():
        raise QuotaError('logs_missing', '未发现本机 Codex 会话日志。')
    # Bound work in this UI prototype. A production app should reuse persistent file cursors.
    files = sorted(base.rglob('rollout-*.jsonl'), key=lambda p: p.stat().st_mtime, reverse=True)[:24]
    newest = {}
    scanned = 0
    for path in files:
        try:
            with path.open('rb') as stream:
                size = path.stat().st_size
                start = max(0, size - 2 * 1024 * 1024)
                stream.seek(start)
                if start:
                    stream.readline()  # Skip a partial line at the tail boundary.
                for line in stream:
                    try:
                        value = json.loads(line)
                    except (ValueError, UnicodeError):
                        continue
                    if not isinstance(value, dict):
                        continue
                    payload = value.get('payload') or {}
                    if not isinstance(payload, dict):
                        continue
                    if value.get('type') != 'event_msg' or payload.get('type') != 'token_count':
                        continue
                    quota = payload.get('rate_limits')
                    if not isinstance(quota, dict):
                        continue
                    stamp = value.get('timestamp')
                    try:
                        parsed = dt.datetime.fromisoformat(stamp.replace('Z', '+00:00'))
                        if parsed.tzinfo is None:
                            continue
                        epoch = parsed.timestamp()
                    except (ValueError, TypeError, AttributeError, OverflowError):
                        continue
                    if epoch > time.time() + 60:
                        continue
                    ident = quota.get('limit_id') or 'legacy'
                    if not isinstance(ident, str):
                        continue
                    if ident not in newest or epoch > newest[ident][0]:
                        normalized = normalize_bucket(quota, ident, True)
                        if not any(normalized.get(slot) and normalized[slot]['remainingPercent'] is not None for slot in ['primary', 'secondary']):
                            continue
                        normalized['observedAt'] = parsed.isoformat()
                        newest[ident] = (epoch, normalized)
            scanned += 1
        except (OSError, ValueError):
            continue
    if not newest:
        raise QuotaError('no_snapshots', '最近的本机日志中没有可用额度快照。')
    return {'ok': True, 'source': 'logs', 'observedAt': max(newest.values(), key=lambda v: v[0])[1]['observedAt'],
            'account': {'type': 'unknown', 'planType': None, 'identityVerified': False},
            'buckets': [v[1] for v in newest.values()], 'scannedFiles': scanned,
            'coverage': '最近修改的24份文件，每份最多读取末尾2MB；账号未核实'}


def safe_fetch(source='live', transport='stdio'):
    try:
        return fetch_logs() if source == 'logs' else fetch_live(transport)
    except QuotaError as error:
        return {'ok': False, 'error': {'code': error.code, 'message': str(error)}}
    except (OSError, ValueError, TypeError, AttributeError):
        return {'ok': False, 'error': {'code': 'read_failed', 'message': '无法读取本机额度，未修改登录状态。'}}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', choices=['live', 'logs'], default='live')
    parser.add_argument('--transport', choices=['stdio', 'proxy'], default='stdio')
    args = parser.parse_args()
    print(json.dumps(safe_fetch(args.source, args.transport), ensure_ascii=False, indent=2))
