"""Loopback-only Google fixture; never uses real accounts, documents or credentials."""
import json
import os
import threading
import time
import sys
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit, parse_qs, unquote

root = Path(sys.argv[1])

def pdf():
    stream = b'BT /F1 12 Tf 40 700 Td (Drive PDF fixture) Tj ET'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
               b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream']
    data, offsets = b'%PDF-1.4\n', [0]
    for i, value in enumerate(objects, 1):
        offsets.append(len(data)); data += str(i).encode() + b' 0 obj\n' + value + b'\nendobj\n'
    start = len(data)
    data += b'xref\n0 6\n0000000000 65535 f \n'
    data += b''.join(('%010d 00000 n \n' % n).encode() for n in offsets[1:])
    return data + b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n' + str(start).encode() + b'\n%%EOF'

class H(BaseHTTPRequestHandler):
    records = []
    counts = {}
    def log_message(self, *args): pass
    def reply(self, value, status=200, headers=None):
        body = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.end_headers()
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_POST(self):
        fields = parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
        H.records.append({'path': self.path, 'fields': fields})
        if self.path == '/revoke': return self.reply({})
        if fields.get('refresh_token') == ['revoked-fixture']:
            return self.reply({'error': 'invalid_grant'}, 400)
        if fields.get('code') == ['slow-code']: time.sleep(1)
        if fields.get('code') == ['bad-code']:
            return self.reply({'error': 'invalid_grant'}, 400)
        result = {'access_token': 'fixture-access', 'expires_in': 3600,
                  'scope': 'https://www.googleapis.com/auth/drive.readonly'}
        if fields.get('grant_type') == ['authorization_code']: result['refresh_token'] = 'fixture-refresh'
        self.reply(result)
    def do_GET(self):
        parsed = urlsplit(self.path)
        path, query = unquote(parsed.path), parse_qs(parsed.query)
        if path == '/records': return self.reply(H.records)
        if path == '/counts': return self.reply(H.counts)
        H.records.append({'path': path, 'query': query, 'authorization': self.headers.get('Authorization')})
        H.counts[path] = H.counts.get(path, 0) + 1
        if path.endswith('/unauthorized') and H.counts[path] == 1: return self.reply({}, 401)
        if path.endswith('/rate') and H.counts[path] == 1: return self.reply({}, 429, {'Retry-After': '0'})
        if path.endswith('/forbidden'): return self.reply({}, 403)
        if path.endswith('/missing'): return self.reply({}, 404)
        if path.endswith('/redirect'): return self.reply(b'', 302, {'Location': 'http://127.0.0.1:1/steal'})
        if path.endswith('/large-response'): return self.reply(b'', headers={'Content-Length': '999999999'})
        if path == '/drive/files':
            return self.reply({'files': [{'id': 'doc', 'name': 'Fixture Doc', 'mimeType': 'application/vnd.google-apps.document',
                                         'modifiedTime': '2026-01-01T00:00:00Z', 'webViewLink': 'https://docs.google.com/document/d/doc/edit'}],
                               'nextPageToken': 'fixture-next'})
        if path.startswith('/sheets/spreadsheets/'):
            if '/values/' in path:
                return self.reply({'values': [['Second tab', '247']] if "O''Brien/2026" in path else [['Main tab', '386']]})
            return self.reply({'sheets': [{'properties': {'title': 'Main', 'index': 0}},
                                         {'properties': {'title': "O'Brien/2026", 'index': 1}}]})
        if path.startswith('/drive/files/'):
            bits = path.split('/')
            ident = bits[3]
            if len(bits) > 4 and bits[4] == 'export':
                if ident == 'slow': time.sleep(1)
                if ident == 'fallback' and query.get('mimeType') == ['text/markdown']: return self.reply({}, 400)
                return self.reply(('Slide one\nSlide two' if ident == 'slides' else '# Fixture\nRead-only 한글 text.').encode())
            if query.get('alt') == ['media']:
                if ident == 'pdf': return self.reply(pdf())
                if ident == 'office': return self.reply((root / 'material-fixtures/large.docx').read_bytes())
                return self.reply(b'Fixture download')
            mime = {'sheet': 'application/vnd.google-apps.spreadsheet', 'slides': 'application/vnd.google-apps.presentation',
                    'pdf': 'application/pdf', 'office': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
                    'folder': 'application/vnd.google-apps.folder', 'download': 'text/plain', 'huge': 'application/pdf',
                    'shortcut': 'application/vnd.google-apps.shortcut'}.get(ident, 'application/vnd.google-apps.document')
            result = {'id': ident, 'name': 'fixture.docx' if ident == 'office' else 'Fixture ' + ident, 'mimeType': mime,
                      'size': '999999999' if ident == 'huge' else '100', 'modifiedTime': '2026-01-01T00:00:00Z'}
            if ident == 'shortcut': result['shortcutDetails'] = {'targetId': 'doc'}
            return self.reply(result)
        self.reply({}, 404)

server = ThreadingHTTPServer(('127.0.0.1', 0), H)
(root / 'google-port').write_text(str(server.server_port))
parent = os.getppid()
def watch_parent():
    while os.getppid() == parent:
        time.sleep(0.25)
    server.shutdown()
threading.Thread(target=watch_parent, daemon=True).start()
server.serve_forever()
