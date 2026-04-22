#!/usr/bin/env python3
"""Simple mock embedding HTTP server for testing.

POST /v1/embeddings
Request JSON: { "model": "...", "input": ["text1", "text2", ...] }
Response JSON: { "data": [ { "embedding": [float,...] }, ... ] }

Embeddings are 1024-dim deterministic floats (i/1000.0) so the client
can exercise truncation to 256 dims.
"""
import json
from http.server import BaseHTTPRequestHandler, HTTPServer
import threading


class Handler(BaseHTTPRequestHandler):
    def _set_headers(self, status=200):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()

    def do_POST(self):
        if self.path != '/v1/embeddings':
            self._set_headers(404)
            self.wfile.write(json.dumps({'error': 'not found'}).encode())
            return

        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8') if length else '{}'
        try:
            req = json.loads(body)
        except Exception:
            req = {}

        inputs = req.get('input') or req.get('inputs') or []
        # Normalize: if inputs is a single string, wrap it
        if isinstance(inputs, str):
            inputs = [inputs]

        data = []
        for i, _ in enumerate(inputs):
            # 1024-dim predictable vector
            vec = [float(j) / 1000.0 for j in range(1024)]
            data.append({'embedding': vec})

        resp = {'data': data}
        self._set_headers(200)
        self.wfile.write(json.dumps(resp).encode('utf-8'))

    def log_message(self, format, *args):
        # Keep logs minimal
        print("[mock-server] %s - - %s" % (self.address_string(), format % args))


def run(server_class=HTTPServer, handler_class=Handler, port=1234):
    server_address = ('', port)
    httpd = server_class(server_address, handler_class)
    print(f"Mock embedding server listening on http://0.0.0.0:{port}/v1/embeddings")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    httpd.server_close()


if __name__ == '__main__':
    run()
