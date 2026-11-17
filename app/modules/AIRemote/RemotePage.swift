import Foundation
import AILocalization

// The one page the iPhone opens: the chat list like the Mac sidebar, a chat with its answers as they come,
// text and photos to send, and the chat's approval cards. The list is the start; a chat is `#c=<id>`, so Back,
// the left-edge swipe and the home-screen app all return to the list. It polls the App's /api/ while visible.
public enum RemotePage {
    public static func html() -> Data {
        let strings: [String: String] = [
            "lang": L("ko", "en"),
            "list": L("목록", "Chats"),
            "empty": L("채팅이 없어요.", "No chats."),
            "noKey": L("Mac의 'iPhone 연결' 창에서 QR을 다시 찍어 주세요.", "Scan the QR again in 'Connect iPhone' on the Mac."),
            "offline": L("Mac에 연결할 수 없어요.", "Cannot reach the Mac."),
            "working": L("답변 중", "Answering"),
            "approval": L("승인 필요", "Needs approval"),
            "allow": L("허용", "Allow"),
            "deny": L("거절", "Deny"),
            "message": L("메시지", "Message"),
            "send": L("보내기", "Send"),
            "photo": L("사진", "Photo"),
            "you": L("나", "You"),
            "failed": L("보내지 못했어요", "Could not send"),
            "details": L("자세히", "Details"),
        ]
        let json = String(data: (try? JSONSerialization.data(withJSONObject: strings)) ?? Data("{}".utf8), encoding: .utf8) ?? "{}"
        return Data(template.replacingOccurrences(of: "__STRINGS__", with: json)
            .replacingOccurrences(of: "__LANG__", with: L("ko", "en")).utf8)
    }

    static let template = #"""
<!doctype html>
<html lang="__LANG__">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="AI Illuminati">
<meta name="color-scheme" content="light dark">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<title>AI Illuminati</title>
<style>
:root { --bg:#f2f2f7; --card:#fff; --text:#000; --dim:#8e8e93; --line:#d1d1d6; --mine:#007aff; --ai:#e9e9eb; --accent:#007aff; }
@media (prefers-color-scheme: dark) { :root { --bg:#000; --card:#1c1c1e; --text:#fff; --dim:#8e8e93; --line:#38383a; --mine:#0a84ff; --ai:#262629; --accent:#0a84ff; } }
* { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
html, body { margin:0; height:100%; background:var(--bg); color:var(--text); font:17px -apple-system, system-ui, sans-serif; }
.view { position:fixed; inset:0; display:flex; flex-direction:column; }
.hidden { display:none !important; }
header { padding:calc(env(safe-area-inset-top) + 8px) 12px 8px; display:flex; align-items:center; gap:8px;
  background:var(--bg); border-bottom:0.5px solid var(--line); min-height:44px; }
header h1 { font-size:28px; margin:6px 4px; }
header .title { flex:1; text-align:center; font-weight:600; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; margin-right:56px; }
.back { color:var(--accent); background:none; border:0; font-size:17px; padding:6px 4px; width:64px; text-align:left; }
.scroll { flex:1; overflow-y:auto; -webkit-overflow-scrolling:touch; padding:0 12px calc(env(safe-area-inset-bottom) + 12px); }
.section { color:var(--dim); font-size:13px; text-transform:uppercase; margin:18px 8px 6px; }
.group { background:var(--card); border-radius:10px; overflow:hidden; }
.row { display:flex; align-items:center; gap:10px; padding:12px 14px; border-top:0.5px solid var(--line); }
.row:first-child { border-top:0; }
a.row { color:inherit; text-decoration:none; }
.row.folder { font-weight:600; }
.row .name { flex:1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.row .sub { color:var(--dim); font-size:13px; }
.row .chev { color:var(--dim); }
.dot { width:9px; height:9px; border-radius:50%; background:#34c759; flex:none; }
.dot.unread { background:var(--accent); }
.badge { background:#ff9500; color:#fff; font-size:12px; border-radius:9px; padding:1px 7px; }
.note { color:var(--dim); text-align:center; margin:40px 20px; }
#turns { padding-top:10px; }
.turn { margin:10px 0; display:flex; flex-direction:column; }
.turn.mine { align-items:flex-end; }
.who { color:var(--dim); font-size:13px; margin:0 6px 3px; }
.bubble { max-width:88%; padding:9px 13px; border-radius:18px; background:var(--ai); line-height:1.38; overflow-wrap:anywhere; }
.mine .bubble { background:var(--mine); color:#fff; }
.bubble pre { white-space:pre-wrap; background:rgba(127,127,127,.15); padding:8px; border-radius:8px; font-size:13px; overflow-x:auto; }
.bubble code { font:13px ui-monospace, Menlo, monospace; }
.bubble img { max-width:100%; border-radius:10px; display:block; margin:4px 0; }
.bubble p { margin:0 0 6px; } .bubble p:last-child { margin:0; }
.bubble.wait { color:var(--dim); }
.error { color:#ff3b30; font-size:13px; margin:3px 6px; }
.approval { background:var(--card); border:1px solid #ff9500; border-radius:12px; padding:12px; margin:10px 0; }
.approval b { display:block; margin-bottom:4px; }
.approval details { color:var(--dim); font-size:13px; margin:6px 0; }
.approval details pre { white-space:pre-wrap; overflow-wrap:anywhere; max-height:40vh; overflow:auto; }
.approval .buttons { display:flex; gap:10px; margin-top:8px; }
.approval button { flex:1; font-size:16px; padding:10px; border-radius:10px; border:0; }
.allow { background:var(--accent); color:#fff; } .deny { background:var(--ai); color:var(--text); }
footer { border-top:0.5px solid var(--line); background:var(--bg); padding:8px 10px calc(env(safe-area-inset-bottom) + 8px); }
#thumbs { display:flex; gap:8px; overflow-x:auto; }
#thumbs:not(:empty) { margin-bottom:8px; }
.thumb { position:relative; flex:none; }
.thumb img { width:64px; height:64px; object-fit:cover; border-radius:8px; display:block; }
.thumb button { position:absolute; top:-6px; right:-6px; width:22px; height:22px; border-radius:11px; border:0; background:#555; color:#fff; font-size:13px; line-height:22px; padding:0; }
.compose { display:flex; align-items:flex-end; gap:8px; }
.compose textarea { flex:1; resize:none; font:17px -apple-system, system-ui; padding:8px 12px; border-radius:18px; border:1px solid var(--line);
  background:var(--card); color:var(--text); max-height:140px; outline:none; }
.icon { width:36px; height:36px; border-radius:18px; border:0; font-size:20px; flex:none; }
#pick { background:var(--ai); color:var(--text); }
#send { background:var(--accent); color:#fff; }
#send:disabled { opacity:.4; }
</style>
</head>
<body>
<div id="listView" class="view">
  <header><h1>AI Illuminati</h1></header>
  <div class="scroll" id="list"></div>
</div>
<div id="chatView" class="view hidden">
  <header><button class="back" id="back">‹ <span id="backText"></span></button><div class="title" id="chatTitle"></div></header>
  <div class="scroll" id="chatScroll"><div id="turns"></div><div id="approvals"></div></div>
  <footer>
    <div id="thumbs"></div>
    <div class="compose">
      <button class="icon" id="pick" aria-label="photo">＋</button>
      <textarea id="text" rows="1"></textarea>
      <button class="icon" id="send" aria-label="send" disabled>↑</button>
    </div>
    <input type="file" id="file" accept="image/*" multiple class="hidden">
  </footer>
</div>
<script>
const S = __STRINGS__;
const params = new URLSearchParams(location.search);
if (params.get('k')) localStorage.setItem('k', params.get('k'));
const KEY = params.get('k') || localStorage.getItem('k') || '';
const $ = id => document.getElementById(id);
const drafts = {};
let current = null, opened = false, timer = null, lastList = '', lastChat = '', photos = [], sending = false;

function esc(s) { return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
function inline(s) {
  return esc(s).replace(/`([^`]+)`/g, '<code>$1</code>').replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>')
    .replace(/^#{1,6} +(.*)$/gm, '<b>$1</b>').replace(/\n/g, '<br>');
}
function markdown(text) {
  return String(text).split(/```[^\n]*\n?/).map((part, i) => i % 2 ? '<pre><code>' + esc(part.replace(/\n$/, '')) + '</code></pre>'
    : part.split(/\n{2,}/).filter(p => p.trim()).map(p => '<p>' + inline(p.trim()) + '</p>').join('')).join('');
}
function withKey(url) { return url + (url.includes('?') ? '&' : '?') + 'k=' + encodeURIComponent(KEY); }
async function api(path, body) {
  const r = await fetch(path, body === undefined ? { headers: { 'X-Remote-Key': KEY }, cache: 'no-store' }
    : { method: 'POST', headers: { 'X-Remote-Key': KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || r.status);
  return data;
}

function route() {
  const m = location.hash.match(/^#c=(.+)$/);
  const id = m ? decodeURIComponent(m[1]) : null;
  if (current !== null) drafts[current] = $('text').value;
  current = id; opened = false; lastChat = ''; photos = []; renderThumbs();
  $('listView').classList.toggle('hidden', !!id);
  $('chatView').classList.toggle('hidden', !id);
  if (id) { $('text').value = drafts[id] || ''; grow(); $('turns').innerHTML = ''; $('approvals').innerHTML = ''; $('chatTitle').textContent = ''; }
  poll();
}
function poll() {
  clearTimeout(timer);
  if (document.hidden) return;
  (current ? loadChat() : loadList()).finally(() => { timer = setTimeout(poll, current ? 1500 : 4000); });
}

async function loadList() {
  if (!KEY) { $('list').innerHTML = '<div class="note">' + esc(S.noKey) + '</div>'; return; }
  try {
    const data = await api('/api/chats');
    const text = JSON.stringify(data);
    if (text === lastList) return;
    lastList = text;
    if (!data.sections.length) { $('list').innerHTML = '<div class="note">' + esc(S.empty) + '</div>'; return; }
    $('list').innerHTML = data.sections.map(s => '<div class="section">' + esc(s.title) + '</div><div class="group">' +
      s.chats.map(c => c.folder ? '<div class="row folder"><span class="name">📁 ' + esc(c.folder) + '</span></div>' :
        '<a class="row" href="#c=' + encodeURIComponent(c.id) + '" style="padding-left:' + (14 + 18 * (c.depth || 0)) + 'px">' +
        (c.working ? '<span class="dot"></span>' : c.unread ? '<span class="dot unread"></span>' : '') +
        '<span class="name">' + esc(c.title) + (c.detail ? '<div class="sub">' + esc(c.detail) + '</div>' : '') + '</span>' +
        (c.approvals ? '<span class="badge">' + c.approvals + '</span>' : '') + '<span class="chev">›</span></a>').join('') + '</div>').join('');
  } catch (e) { $('list').innerHTML = '<div class="note">' + esc(String(e.message) === '401' ? S.noKey : (e.message || S.offline)) + '</div>'; lastList = ''; }
}

async function loadChat() {
  const id = current;
  try {
    const data = await api('/api/chat/' + encodeURIComponent(id) + (lastChat === '' && !opened ? '?open=1' : ''));
    opened = true;
    if (id !== current) return;
    const text = JSON.stringify(data);
    if (text === lastChat) return;
    lastChat = text;
    const box = $('chatScroll'), atEnd = box.scrollHeight - box.scrollTop - box.clientHeight < 80;
    $('chatTitle').textContent = data.title;
    document.querySelector('footer').classList.toggle('hidden', !!data.readOnly);
    $('turns').innerHTML = data.turns.map(t => '<div class="turn' + (t.mine ? ' mine' : '') + '">' +
      (t.mine ? '' : '<div class="who">' + esc(t.name) + '</div>') +
      '<div class="bubble' + (t.waiting ? ' wait' : '') + '">' + (t.images || []).map(u => '<img src="' + esc(withKey(u)) + '" loading="lazy">').join('') +
      (t.waiting && !t.text ? esc(S.working) + ' …' : markdown(t.text)) + '</div>' +
      (t.error ? '<div class="error">' + esc(t.error) + '</div>' : '') + '</div>').join('');
    $('approvals').innerHTML = data.approvals.map(a => '<div class="approval"><b>' + esc(a.title) + '</b>' +
      (a.detail ? '<details><summary>' + esc(S.details) + '</summary><pre>' + esc(a.detail) + '</pre></details>' : '') +
      '<div class="buttons"><button class="deny" data-id="' + esc(a.id) + '" data-allow="0">' + esc(S.deny) + '</button>' +
      '<button class="allow" data-id="' + esc(a.id) + '" data-allow="1">' + esc(S.allow) + '</button></div></div>').join('');
    if (atEnd) box.scrollTop = box.scrollHeight;
  } catch (e) { if (id === current) $('chatTitle').textContent = e.message || S.offline; lastChat = ''; }
}

$('approvals').addEventListener('click', async e => {
  const b = e.target.closest('button[data-id]'); if (!b) return;
  b.parentNode.querySelectorAll('button').forEach(x => x.disabled = true);
  try { await api('/api/approval/' + encodeURIComponent(b.dataset.id), { allow: b.dataset.allow === '1' }); } catch (err) { alert(err.message); }
  lastChat = ''; poll();
});

function grow() { const t = $('text'); t.style.height = 'auto'; t.style.height = Math.min(t.scrollHeight, 140) + 'px'; canSend(); }
function canSend() { $('send').disabled = sending || (!$('text').value.trim() && !photos.length); }
$('text').addEventListener('input', grow);
$('pick').addEventListener('click', () => $('file').click());
$('file').addEventListener('change', async e => {
  for (const f of e.target.files) { try { photos.push(await shrink(f)); } catch (_) {} }
  e.target.value = ''; renderThumbs();
});
// Photos go as JPEG of at most 2048 px, so a 12 MP picture is a few hundred KB, not 5 MB.
function shrink(file) {
  return new Promise((ok, fail) => {
    const img = new Image(), url = URL.createObjectURL(file);
    img.onload = () => {
      const scale = Math.min(1, 2048 / Math.max(img.naturalWidth, img.naturalHeight));
      const c = document.createElement('canvas');
      c.width = Math.round(img.naturalWidth * scale); c.height = Math.round(img.naturalHeight * scale);
      c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
      URL.revokeObjectURL(url); ok(c.toDataURL('image/jpeg', 0.85));
    };
    img.onerror = () => { URL.revokeObjectURL(url); fail(); };
    img.src = url;
  });
}
function renderThumbs() {
  $('thumbs').innerHTML = photos.map((p, i) => '<div class="thumb"><img src="' + p + '"><button data-i="' + i + '">✕</button></div>').join('');
  canSend();
}
$('thumbs').addEventListener('click', e => { const b = e.target.closest('button'); if (b) { photos.splice(+b.dataset.i, 1); renderThumbs(); } });
$('send').addEventListener('click', async () => {
  const id = current, text = $('text').value.trim();
  if (!id || sending || (!text && !photos.length)) return;
  sending = true; canSend();
  try {
    await api('/api/chat/' + encodeURIComponent(id) + '/send', { text, images: photos.map(p => p.split(',')[1]) });
    $('text').value = ''; drafts[id] = ''; photos = []; renderThumbs(); grow();
    lastChat = ''; setTimeout(() => { $('chatScroll').scrollTop = 1e9; }, 50);
  } catch (e) { alert(S.failed + ': ' + e.message); }
  sending = false; canSend(); poll();
});

$('back').addEventListener('click', () => { if (history.length > 1 && location.hash) history.back(); else location.hash = ''; });
$('backText').textContent = S.list;
$('text').placeholder = S.message;
// The home-screen app has no Safari back swipe: a swipe from the left edge goes back to the list.
let sx = null, sy = 0;
$('chatView').addEventListener('touchstart', e => { const t = e.touches[0]; sx = t.clientX < 28 ? t.clientX : null; sy = t.clientY; }, { passive: true });
$('chatView').addEventListener('touchend', e => {
  if (sx === null) return; const t = e.changedTouches[0];
  if (t.clientX - sx > 80 && Math.abs(t.clientY - sy) < 60) $('back').click(); sx = null;
}, { passive: true });
document.addEventListener('visibilitychange', () => { if (!document.hidden) { lastList = ''; lastChat = ''; } poll(); });
window.addEventListener('hashchange', route);
route();
</script>
</body>
</html>
"""#
}
