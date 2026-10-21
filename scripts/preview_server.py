#!/usr/bin/env python3
"""Local-only UI prototype with a restricted Codex quota reader. Standard library only."""
import argparse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import threading
import time
from urllib.parse import parse_qs, urlsplit

from codex_quota import safe_fetch

WEB = Path(__file__).resolve().parents[1] / 'prototype'
FILES = {'/': ('index.html', 'text/html; charset=utf-8'),
         '/index.html': ('index.html', 'text/html; charset=utf-8'),
         '/styles.css': ('styles.css', 'text/css; charset=utf-8'),
         '/app.js': ('app.js', 'text/javascript; charset=utf-8')}
cache = {}
query_lock = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    def send_body(self, code, body, content_type):
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        port = self.server.server_port
        hosts = {'127.0.0.1:' + str(port), 'localhost:' + str(port)}
        if self.headers.get('Host') not in hosts:
            self.send_body(403, b'Forbidden host', 'text/plain')
            return
        url = urlsplit(self.path)
        if url.path == '/api/quota':
            origins = {'http://' + host for host in hosts}
            if self.headers.get('X-UsageBar-Local') != 'preview' or self.headers.get('Origin') not in origins | {None}:
                self.send_body(403, b'Forbidden origin', 'text/plain')
                return
            source = parse_qs(url.query).get('source', ['logs'])[0]
            if source not in {'logs', 'live'}:
                self.send_body(400, b'Invalid source', 'text/plain')
                return
            with query_lock:
                cached = cache.get(source)
                if cached and time.monotonic() - cached[0] < 15:
                    value = cached[1]
                else:
                    value = safe_fetch(source)
                    cache[source] = (time.monotonic(), value)
            self.send_body(200, json.dumps(value, ensure_ascii=False, allow_nan=False).encode(), 'application/json; charset=utf-8')
            return
        if url.path in FILES:
            name, content_type = FILES[url.path]
            self.send_body(200, (WEB / name).read_bytes(), content_type)
            return
        self.send_body(404, b'Not found', 'text/plain')

    def log_message(self, format, *args):
        # Do not log account payloads or filesystem content.
        pass


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--port', type=int, default=8766)
    args = parser.parse_args()
    server = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    server.daemon_threads = True
    print('UsageBar preview: http://127.0.0.1:%d' % server.server_port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
