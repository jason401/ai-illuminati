"""Loopback-only fixture of Google's Workspace MCP servers (drivemcp, docsmcp, slidesmcp, sheetsmcp; 2026-07-28, stateless)
plus its token and userinfo endpoints; never uses real accounts, documents or credentials. Writes ask for approval the
way Google does: resultType input_required with a form elicitation, answered by resending with inputResponses."""
import base64, json, re, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
lock = threading.Lock()
FOLDER, DOC, SHEET, SLIDES = ('application/vnd.google-apps.' + t for t in ('folder', 'document', 'spreadsheet', 'presentation'))
files = {
    'allowed': {'title': 'Allowed', 'mimeType': FOLDER, 'parentId': 'root'},
    'zeta': {'title': 'Zeta', 'mimeType': FOLDER, 'parentId': 'allowed'},
    'sub': {'title': 'alpha', 'mimeType': FOLDER, 'parentId': 'allowed'},
    'doc': {'title': 'Plan', 'mimeType': DOC, 'parentId': 'sub', 'text': 'Fixture doc text'},
    'outside': {'title': 'Plan outside', 'mimeType': DOC, 'parentId': 'root', 'text': 'secret'},
    'sheet': {'title': 'Book', 'mimeType': SHEET, 'parentId': 'allowed'},
    'slides': {'title': 'Deck', 'mimeType': SLIDES, 'parentId': 'allowed'},
    'shortcut': {'title': 'Link', 'mimeType': 'application/vnd.google-apps.shortcut', 'parentId': 'allowed', 'target': 'outside'},
    'bin': {'title': 'data.bin', 'mimeType': 'application/octet-stream', 'parentId': 'allowed', 'bytes': b'\x00\x01binary\xff'},
    'old': {'title': 'deck.pptx', 'mimeType': 'application/vnd.openxmlformats-officedocument.presentationml.presentation', 'parentId': 'allowed', 'bytes': b'v1', 'etag': 'e1'},
    'preview': {'title': 'Preview', 'mimeType': DOC, 'parentId': 'allowed', 'preview': True},
}
state = {'records': [], 'access': {'a-1'}, 'reject_next': False, 'n': 1, 'states': set()}
WRITES = {'create_file', 'copy_file', 'upload_file_revision', 'update_doc', 'update_presentation'}
PNG = b'\x89PNG\r\n\x1a\n' + b'fixture'

def file_json(fid):
    f = files[fid]
    out = {'id': fid, 'title': f['title'], 'mimeType': f['mimeType'], 'viewUrl': 'https://drive.google.com/open?id=' + fid,
           'trashed': False, 'etag': f.get('etag', 'e-' + fid), 'modifiedTime': '2026-11-25T00:00:00Z'}
    if f.get('parentId') and f['parentId'] != 'root': out['parentId'] = f['parentId']
    if 'bytes' in f: out['fileSize'] = str(len(f['bytes']))
    if 'target' in f: out['shortcutDetails'] = {'targetFileId': f['target']}
    return out

def ancestors(fid):
    seen = []
    while fid in files and files[fid].get('parentId'):
        fid = files[fid]['parentId']; seen.append(fid)
    return seen

def search(query):
    found = []
    for fid, f in files.items():
        m = re.search(r"parentId = '([^']*)'", query)
        if m and f.get('parentId') != m.group(1): continue
        allowed = re.findall(r"'([^']*)' in ancestors", query)
        if allowed and not set(allowed) & set(ancestors(fid)): continue
        m = re.search(r"mimeType = '([^']*)'", query)
        if m and f['mimeType'] != m.group(1): continue
        m = re.search(r"title = '((?:[^'\\]|\\.)*)'", query)
        if m and f['title'] != m.group(1).replace("\\'", "'"): continue
        words = re.findall(r"title contains '((?:[^'\\]|\\.)*)'", query)
        if any(w.lower() not in (f['title'] + f.get('text', '')).lower() for w in words): continue
        if 'sharedWithMe = true' in query: continue
        found.append(fid)
    return found

def ok(value): return {'structuredContent': value, 'content': [{'type': 'text', 'text': json.dumps(value)}]}
def fail(text): return {'isError': True, 'content': [{'type': 'text', 'text': text}]}

def approval(name, params):
    """None when approved; else the input_required answer (or a refusal)."""
    responses = params.get('inputResponses')
    if responses is None:
        with lock:
            token = 'st-%d' % state['n']; state['n'] += 1; state['states'].add(token)
        schema = {'type': 'object', 'properties': {'approval_choice': {'type': 'string', 'enum': ['ALLOW_ONCE', 'ALLOW_ALWAYS', 'DENY'],
                  'enumNames': ['Allow once', 'Always allow', 'Deny']}}, 'required': ['approval_choice']}
        return {'resultType': 'input_required', 'requestState': token,
                'inputRequests': {'approval': {'method': 'elicitation/create', 'params': {'mode': 'form', 'message': 'Allow the agent to run ' + name + '?', 'requestedSchema': schema}}}}
    if params.get('requestState') not in state['states']: return fail('stale request state')
    choice = responses.get('approval', {}).get('content', {}).get('approval_choice')
    if responses.get('approval', {}).get('action') != 'accept' or choice not in ('ALLOW_ONCE', 'ALLOW_ALWAYS'): return fail('declined')
    return None

def call(server, name, args, params):
    if name in WRITES:
        asked = approval(name, params)
        if asked is not None: return asked
    if server == 'drivemcp':
        fid = args.get('fileId')
        if fid and fid not in files: return fail('File not found: ' + fid)
        if fid and files[fid].get('preview'):
            return fail('Access to this tool requires that your Google Cloud project (1) is enrolled in the Google Workspace Developer Preview Program.')
        if name == 'get_file_metadata': return ok(file_json(fid))
        if name == 'search_files':
            ids = search(args.get('query', '')); size = args.get('pageSize', 100); start = int(args.get('pageToken') or 0)
            value = {'files': [file_json(i) for i in ids[start:start + size]]}
            if start + size < len(ids): value['nextPageToken'] = str(start + size)
            return ok(value)
        if name == 'read_file_content': return ok({'title': files[fid]['title'], 'fileContent': files[fid].get('text', 'text of ' + fid)})
        if name == 'download_file_content':
            data = files[fid].get('bytes', ('export of %s as %s' % (fid, args.get('exportMimeType'))).encode())
            return {'content': [{'type': 'resource', 'resource': {'uri': 'drive://' + fid, 'mimeType': files[fid]['mimeType'], 'blob': base64.b64encode(data).decode()}}]}
        if name == 'create_file':
            with lock:
                new = 'new-%d' % state['n']; state['n'] += 1
            data = base64.b64decode(args['base64Content']) if 'base64Content' in args else args.get('textContent', '').encode()
            mime = args.get('contentMimeType', DOC)
            if mime == 'text/plain' and not args.get('disableConversionToGoogleType'): mime = DOC
            files[new] = {'title': args['title'], 'mimeType': mime, 'parentId': args.get('parentId', 'root'), 'bytes': data}
            return ok(file_json(new))
        if name == 'upload_file_revision':
            if args.get('etag') and args['etag'] != files[fid].get('etag', 'e-' + fid): return fail('FAILED_PRECONDITION: etag mismatch')
            files[fid]['bytes'] = base64.b64decode(args['base64Content']); files[fid]['etag'] = 'e2'
            return ok({'id': fid, 'mimeType': files[fid]['mimeType'], 'fileEtag': 'e2'})
        if name == 'copy_file':
            with lock:
                new = 'copy-%d' % state['n']; state['n'] += 1
            files[new] = dict(files[fid], title=args.get('title') or 'Copy of ' + files[fid]['title'], parentId=args.get('parentId', files[fid]['parentId']))
            return ok(file_json(new))
    if server == 'docsmcp':
        if name == 'read_doc': return ok({'content': {'documentId': args['documentId'], 'revisionId': 'rev-1', 'title': 'Plan'}})
        if name == 'update_doc':
            if args.get('writeControl', {}).get('requiredRevisionId') != 'rev-1': return fail('revision mismatch')
            return ok({'replies': [{'replaceAllText': {'occurrencesChanged': 1}}], 'writeControl': {'requiredRevisionId': 'rev-2'}})
    if server == 'slidesmcp':
        deck = {'presentationId': 'slides', 'title': 'Deck', 'revisionId': 's-1', 'slides': [{'objectId': 'p1'}, {'objectId': 'p2'}],
                'pageSize': {'width': {'magnitude': 9144000, 'unit': 'EMU'}, 'height': {'magnitude': 5143500, 'unit': 'EMU'}}}
        if name == 'read_presentation':
            if args.get('fields') == ['slides.objectId']: deck = {'slides': deck['slides']}
            return ok({'content': deck})
        if name == 'read_slide_page_thumbnail':
            return ok({'contentUrl': 'http://127.0.0.1:%d/thumb/%s' % (port, args['pageId']), 'widthPx': 800, 'heightPx': 450})
        if name == 'update_presentation':
            if args.get('writeControl', {}).get('requiredRevisionId') != 's-1': return fail('revision mismatch')
            return ok({'replies': [{} for _ in args.get('requests', [])]})
    if server == 'sheetsmcp':
        if name == 'get_spreadsheet': return ok({'content': {'sheets': [{'properties': {'title': 'Tab B', 'index': 1}}, {'properties': {'title': 'Tab A', 'index': 0}}]}})
        if name == 'get_values': return ok({'range': args['range'], 'values': [['x', 1], ['y', 2]] if 'Tab B' in args['range'] else [['a']]})
    return fail('Tool is not authorized/disabled: ' + name)

class H(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass
    def send(self, status, value, kind='application/json'):
        data = value if isinstance(value, bytes) else json.dumps(value).encode()
        self.send_response(status); self.send_header('Content-Type', kind); self.send_header('Content-Length', str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError): pass
    def do_GET(self):
        if self.path == '/records': return self.send(200, state['records'])
        if self.path == '/userinfo':
            if self.headers.get('Authorization', '')[7:] not in state['access']: return self.send(401, {})
            return self.send(200, {'sub': 'fixture-sub', 'email': 'fixture@example.com'})
        if self.path.startswith('/thumb/'): return self.send(200, PNG, 'image/png')
        self.send(404, {})
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length') or 0))
        if self.path == '/reject-next': state['reject_next'] = True; return self.send(200, {})
        if self.path == '/token':
            fields = dict(p.split('=', 1) for p in body.decode().split('&') if '=' in p)
            with lock:
                access = 'a-%d' % state['n']; state['n'] += 1; state['access'].add(access)
            state['records'].append({'token': fields.get('grant_type')})
            return self.send(200, {'access_token': access, 'expires_in': 3600, 'refresh_token': 'r-1',
                                   'scope': 'openid email https://www.googleapis.com/auth/drive https://www.googleapis.com/auth/documents https://www.googleapis.com/auth/presentations https://www.googleapis.com/auth/spreadsheets'})
        m = re.fullmatch(r'/(drivemcp|docsmcp|slidesmcp|sheetsmcp)/mcp/v1', self.path)
        if not m: return self.send(404, {})
        message = json.loads(body)
        params = message.get('params', {})
        meta = params.get('_meta', {})
        auth = self.headers.get('Authorization', '')
        record = {'server': m.group(1), 'tool': params.get('name'), 'answered': 'inputResponses' in params,
                  'choice': params.get('inputResponses', {}).get('approval', {}).get('content', {}).get('approval_choice'),
                  'args': {k: (len(v) if k == 'base64Content' else v) for k, v in params.get('arguments', {}).items()},
                  'mcpName': self.headers.get('Mcp-Name'), 'version': self.headers.get('MCP-Protocol-Version'),
                  'elicitation': 'form' in meta.get('io.modelcontextprotocol/clientCapabilities', {}).get('elicitation', {})}
        state['records'].append(record)
        if state['reject_next'] or auth[7:] not in state['access']:
            state['reject_next'] = False; record['status'] = 401
            return self.send(401, {'error': 'unauthorized'})
        if message.get('method') != 'tools/call' or meta.get('io.modelcontextprotocol/protocolVersion') != '2026-07-28':
            return self.send(200, {'jsonrpc': '2.0', 'id': message.get('id'), 'error': {'code': -32602, 'message': 'bad request'}})
        result = call(m.group(1), params.get('name'), params.get('arguments', {}), params)
        self.send(200, {'jsonrpc': '2.0', 'id': message.get('id'), 'result': result})

server = ThreadingHTTPServer(('127.0.0.1', 0), H)
port = server.server_address[1]
(root / 'google-mcp-port').write_text(str(port))
server.serve_forever()
