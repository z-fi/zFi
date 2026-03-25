#!/usr/bin/env python3
"""Dev server with gzip compression and /proxy endpoint for CORS-blocked metadata fetches."""
import http.server, urllib.request, urllib.parse, os, gzip

COMPRESSIBLE = {
    'text/html', 'text/css', 'application/javascript', 'text/javascript',
    'application/json', 'image/svg+xml', 'application/xml', 'text/plain',
}

class Handler(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith('/proxy?'):
            qs = urllib.parse.urlparse(self.path).query
            params = urllib.parse.parse_qs(qs)
            url = params.get('url', [''])[0]
            if not url:
                self.send_error(400, 'Missing url param')
                return
            try:
                req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
                with urllib.request.urlopen(req, timeout=10) as resp:
                    body = resp.read()
                self._send_body(body, 'application/json')
            except Exception as e:
                self.send_error(502, str(e))
            return
        # For normal files, serve with compression
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            # Let SimpleHTTPRequestHandler find index.html
            for index in ('index.html', 'index.htm'):
                idx = os.path.join(path, index)
                if os.path.exists(idx):
                    path = idx
                    break
        if os.path.isfile(path):
            ctype = self.guess_type(path)
            try:
                with open(path, 'rb') as f:
                    body = f.read()
            except OSError:
                self.send_error(404, 'File not found')
                return
            self._send_body(body, ctype)
        else:
            super().do_GET()

    def _send_body(self, body, content_type):
        accepts_gzip = 'gzip' in self.headers.get('Accept-Encoding', '')
        if accepts_gzip and content_type.split(';')[0] in COMPRESSIBLE and len(body) > 256:
            body = gzip.compress(body)
            self.send_response(200)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Encoding', 'gzip')
        else:
            self.send_response(200)
            self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        super().end_headers()

if __name__ == '__main__':
    os.chdir(os.path.dirname(os.path.abspath(__file__)))
    print('Serving on http://localhost:8080 (gzip enabled)')
    http.server.HTTPServer(('', 8080), Handler).serve_forever()
