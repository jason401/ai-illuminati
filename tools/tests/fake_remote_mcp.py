"""Loopback-only remote MCP fixture for the app tests: no real servers, accounts or tokens.
/modern  2026-07-28 only: per-request _meta and headers, checked like a strict server; JSON and SSE answers.
/legacy  2025-06-18 Streamable HTTP: initialize + Mcp-Session-Id; the session expires once.
/key     needs `Authorization: Bearer k-1`; no OAuth metadata.
/oauth   OAuth 2.1: RFC 9728 metadata, RFC 8414 metadata, DCR, PKCE S256, resource, iss, refresh."""
import base64, hashlib, json, sys, threading, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
state = {'records': [], 'sessions': 0, 'expire': False, 'clients': {}, 'codes': {}, 'access': set(), 'refresh': set(),
         'n': 0, 'description': 'Writes a page'}
lock = threading.Lock()
MODERN = '2026-07-28'

def tools():
    return [
        {'name': 'search', 'description': 'Search', 'inputSchema': {'type': 'object'}, 'annotations': {'readOnlyHint': True}},
        {'name': 'write', 'description': state['description'], 'inputSchema': {'type': 'object'}},
        {'name': 'region', 'description': 'Region header', 'annotations': {'readOnlyHint': True},
         'inputSchema': {'type': 'object', 'properties': {'region': {'type': 'string', 'x-mcp-header': 'Region'}, 'q': {'type': 'string'}}}},
        {'name': 'bad', 'description': 'Header in an array', 'inputSchema': {'type': 'object', 'properties': {
            'list': {'type': 'array', 'items': {'type': 'string', 'x-mcp-header': 'Item'}}}}},
        {'name': 'say', 'description': 'Answers on SSE', 'inputSchema': {'type': 'object'}, 'annotations': {'readOnlyHint': True}},
    ]

def decode(value):
    if value and value.startswith('=?base64?') and value.endswith('?='): return base64.b64decode(value[9:-2]).decode()
    return value

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    @property
    def base(self): return 'http://127.0.0.1:%d' % self.server.server_address[1]

    def send(self, status, body=None, headers=None, kind='application/json'):
        data = b'' if body is None else (body if isinstance(body, bytes) else json.dumps(body).encode())
        self.send_response(status)
        if body is not None: self.send_header('Content-Type', kind)
        for k, v in (headers or {}).items(): self.send_header(k, v)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass

    def sse(self, messages):
        data = ''.join(': keep-alive\r\n\r\n' if m is None else 'event: message\r\ndata: ' + json.dumps(m) + '\r\n\r\n' for m in messages).encode()
        self.send(200, data, kind='text/event-stream')

    def do_GET(self):
        path, _, query = self.path.partition('?')
        q = dict(urllib.parse.parse_qsl(query))
        if path == '/records': return self.send(200, state['records'])
        if path == '/.well-known/oauth-protected-resource/oauth':
            return self.send(200, {'resource': self.base + '/oauth', 'authorization_servers': [self.base], 'scopes_supported': ['read']})
        if path == '/.well-known/oauth-authorization-server':
            b = self.base
            return self.send(200, {'issuer': b, 'authorization_endpoint': b + '/authorize', 'token_endpoint': b + '/token',
                                   'registration_endpoint': b + '/register', 'code_challenge_methods_supported': ['S256'],
                                   'authorization_response_iss_parameter_supported': True, 'scopes_supported': ['read', 'offline_access']})
        if path == '/authorize':
            client = state['clients'].get(q.get('client_id'))
            ok = (client and q.get('redirect_uri') in client['redirect_uris'] and q.get('response_type') == 'code'
                  and q.get('code_challenge_method') == 'S256' and q.get('resource') == self.base + '/oauth' and q.get('scope') == 'read offline_access')
            if not ok: return self.send(400, {'error': 'invalid_request', 'got': q})
            code = 'code-%d' % len(state['codes'])
            state['codes'][code] = q
            target = q['redirect_uri'] + '?' + urllib.parse.urlencode({'code': code, 'state': q['state'], 'iss': self.base})
            return self.send(302, headers={'Location': target})
        if path in ('/modern', '/legacy', '/key', '/oauth'): return self.send(405)
        self.send(404)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length') or 0))
        path = self.path.partition('?')[0]
        h = {k.lower(): v for k, v in self.headers.items()}
        if path == '/bump': state['description'] = 'Writes a page, now differently'; return self.send(200, {})
        if path == '/revoke': state['access'].clear(); return self.send(200, {})
        if path == '/register':
            body = json.loads(raw)
            if body.get('application_type') != 'native' or body.get('token_endpoint_auth_method') != 'none': return self.send(400, {'error': 'invalid_client_metadata'})
            client = 'c-%d' % len(state['clients'])
            state['clients'][client] = body
            return self.send(201, {'client_id': client, 'redirect_uris': body['redirect_uris']})
        if path == '/token':
            f = dict(urllib.parse.parse_qsl(raw.decode()))
            if f.get('resource') != self.base + '/oauth' or f.get('client_id') not in state['clients']: return self.send(400, {'error': 'invalid_target'})
            if f.get('grant_type') == 'authorization_code':
                asked = state['codes'].pop(f.get('code'), None)
                challenge = base64.urlsafe_b64encode(hashlib.sha256(f.get('code_verifier', '').encode()).digest()).decode().rstrip('=')
                if not asked or asked['code_challenge'] != challenge or asked['redirect_uri'] != f.get('redirect_uri'): return self.send(400, {'error': 'invalid_grant'})
            elif f.get('grant_type') == 'refresh_token':
                if f.get('refresh_token') not in state['refresh']: return self.send(400, {'error': 'invalid_grant'})
                state['refresh'].discard(f['refresh_token'])
            else: return self.send(400, {'error': 'unsupported_grant_type'})
            with lock: state['n'] += 1; n = state['n']
            state['access'].add('a-%d' % n); state['refresh'].add('r-%d' % n)
            return self.send(200, {'access_token': 'a-%d' % n, 'token_type': 'Bearer', 'expires_in': 3600, 'refresh_token': 'r-%d' % n, 'scope': 'read offline_access'})

        message = json.loads(raw)
        method, params, mid = message.get('method'), message.get('params') or {}, message.get('id')
        state['records'].append({'path': path, 'method': method, 'headers': h})
        if path == '/key' and h.get('authorization') != 'Bearer k-1':
            return self.send(401, {'error': 'unauthorized'}, {'WWW-Authenticate': 'Bearer realm="key"'})
        if path == '/oauth' and (h.get('authorization') or '')[7:] not in state['access']:
            return self.send(401, {'error': 'unauthorized'}, {'WWW-Authenticate':
                'Bearer resource_metadata="%s/.well-known/oauth-protected-resource/oauth", scope="read"' % self.base})
        if path == '/legacy': return self.legacy(method, params, mid, h)
        return self.modern(method, params, mid, h, path)

    def modern(self, method, params, mid, h, path):
        meta = params.get('_meta') or {}
        version = meta.get('io.modelcontextprotocol/protocolVersion')
        if h.get('mcp-protocol-version') is None or version is None or h.get('mcp-method') != method:
            return self.send(400, {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32020, 'message': 'Header mismatch or missing _meta'}})
        if h['mcp-protocol-version'] != version:
            return self.send(400, {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32020, 'message': 'Header mismatch'}})
        if version != MODERN:
            return self.send(400, {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32022, 'message': 'Unsupported protocol version',
                                                                          'data': {'supported': [MODERN], 'requested': version}}})
        if 'mcp-session-id' in h: return self.send(400, {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32600, 'message': 'no sessions here'}})
        if method == 'server/discover':
            return self.send(200, {'jsonrpc': '2.0', 'id': mid, 'result': {'resultType': 'complete', 'supportedVersions': [MODERN], 'capabilities': {'tools': {}}}})
        if method == 'tools/list': return self.send(200, {'jsonrpc': '2.0', 'id': mid, 'result': {'tools': tools()}})
        if method == 'tools/call':
            name = params.get('name')
            if decode(h.get('mcp-name')) != name: return self.send(400, {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32020, 'message': 'Mcp-Name mismatch'}})
            region = (params.get('arguments') or {}).get('region')
            if region is not None and decode(h.get('mcp-param-region')) != region:
                return self.send(400, {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32020, 'message': 'Mcp-Param-Region mismatch'}})
            text = '%s:%s team=%s auth=%s' % (name, json.dumps(params.get('arguments'), sort_keys=True), h.get('x-team'), h.get('authorization'))
            if region is not None: text = 'region header=' + h.get('mcp-param-region', '')
            result = {'jsonrpc': '2.0', 'id': mid, 'result': {'content': [{'type': 'text', 'text': text}], 'isError': False}}
            if name == 'say':
                return self.sse([{'jsonrpc': '2.0', 'method': 'notifications/progress', 'params': {'progress': 1}}, None, result])
            return self.send(200, result)
        self.send(404, {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32601, 'message': 'Method not found'}})

    def legacy(self, method, params, mid, h):
        if method == 'initialize':
            with lock: state['sessions'] += 1; session = 's-%d' % state['sessions']
            state['current'] = session
            return self.send(200, {'jsonrpc': '2.0', 'id': mid, 'result': {'protocolVersion': '2025-06-18', 'capabilities': {'tools': {}}, 'serverInfo': {'name': 'old'}}},
                             {'Mcp-Session-Id': session})
        if h.get('mcp-session-id') != state.get('current'):
            return self.send(400) if 'mcp-session-id' not in h else self.send(404)
        if h.get('mcp-protocol-version') != '2025-06-18': return self.send(400)
        if mid is None: return self.send(202)
        if method == 'tools/list':
            return self.send(200, {'jsonrpc': '2.0', 'id': mid, 'result': {'tools': [{'name': 'old', 'description': 'Old', 'inputSchema': {'type': 'object'}}]}})
        if method == 'tools/call':
            if state['expire']: state['expire'] = False; state['current'] = None; return self.send(404)
            return self.sse([{'jsonrpc': '2.0', 'method': 'notifications/message', 'params': {}},
                             {'jsonrpc': '2.0', 'id': mid, 'result': {'content': [{'type': 'text', 'text': 'old in ' + h['mcp-session-id']}]}}])
        self.send(200, {'jsonrpc': '2.0', 'id': mid, 'error': {'code': -32601, 'message': 'Method not found'}})

    def do_PUT(self):
        state['expire'] = True; self.send(200, {})

server = ThreadingHTTPServer(('127.0.0.1', 0), H)
(root / 'remote-mcp-port').write_text(str(server.server_address[1]))
server.serve_forever()
