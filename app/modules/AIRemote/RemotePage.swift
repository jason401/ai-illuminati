import Foundation
import AILocalization

// The one page the iPhone opens, drawn like the Mac's chat window: the list like its sidebar (search, new chat,
// projects that fold), and a chat that slides in from the right with the Mac's look (my message in a gray bubble on the
// right, answers full width under the AI's colored name, the rounded message box). A chat is `#c=<id>` and a new one
// `#new[=<project>]`, so Back and a swipe to the right (the page follows the finger) return to the list, which keeps
// its place. Only changed messages are redrawn. It polls the App's /api/ while visible.
public enum RemotePage {
    public static func html() -> Data {
        let strings: [String: String] = [
            "list": L("목록", "Chats"),
            "empty": L("채팅이 없어요.", "No chats."),
            "noKey": L("Mac의 'iPhone 연결' 창에서 QR을 다시 찍어 주세요.", "Scan the QR again in 'Connect iPhone' on the Mac."),
            "offline": L("Mac에 연결할 수 없어요.", "Cannot reach the Mac."),
            "working": L("답변 중", "Answering"),
            "answering": L("답변 중…", "Responding…"),
            "allow": L("허용", "Allow"),
            "deny": L("거절", "Deny"),
            "message": L("메시지를 입력하세요…", "Write a message…"),
            "askAnything": L("무엇이든 물어보세요", "How can I help you today?"),
            "failed": L("보내지 못했어요", "Could not send"),
            "details": L("자세히", "Details"),
            "inbox": L("알림함", "Inbox"),
            "newChat": L("새 대화", "New chat"),
            "newIn": L("이 프로젝트에 새 대화", "New chat in this project"),
            "showMore": L("더 보기 ({n})", "Show more ({n})"),
            "showLess": L("접기", "Show less"),
            "search": L("대화 검색", "Search chats"),
            "cancel": L("취소", "Cancel"),
            "results": L("검색 결과", "Results"),
            "noResults": L("찾은 대화가 없어요", "No chats found"),
            "copy": L("복사", "Copy"),
            "copied": L("복사됨", "Copied"),
            "readOnly": L("회의 기록 · 읽기 전용", "Meeting record · read only"),
            "queued": L("대기 중", "Waiting"),
            "justStarted": L("· 방금 시작", "· just started"),
            "minutes": L("· {n}분째", "· {n} min"),
            "toBottom": L("맨 아래로", "Scroll to bottom"),
            "photo": L("사진", "Photo"),
            "dropPhoto": L("놓으면 사진 추가", "Drop to add photos"),
            "dropAnywhere": L("어디에 놓아도 돼요 · 보내기 전에 볼 수 있어요", "Anywhere · you check them before sending"),
            "dropReadOnly": L("읽기 전용 대화라 사진을 넣을 수 없어요", "This chat is read only: no photos"),
            "send": L("보내기", "Send"),
            "pickOnce": L("이 메시지에만 적용돼요", "For this message only"),
            "notes": L("메모", "Notes"),
            "projectInfo": L("프로젝트 정보", "Project info"),
            "infoViewOnly": L("iPhone에서는 보기만 해요 · 바꾸려면 Mac의 프로젝트 정보에서", "View only here · change it in Project info on the Mac"),
            "infoSummary": L("대화 {chats}개 · 남은 할 일 {todos}개", "{chats} chats · {todos} TODOs left"),
            "infoGit": L("Git 저장소", "Git repository"),
            "infoDocs": L("문서 폴더 (Git 없음)", "Documents folder (no Git)"),
            "infoDocsHint": L("글·그림·슬라이드를 함께 다루는 문서 프로젝트예요. AI가 답할 때마다 이 폴더를 먼저 백업해서 되돌릴 수 있어요 (클라우드에만 있는 파일은 빼고).",
                              "A documents project for text, figures and slides together. The folder is backed up before each answer so it can be undone (not files only in the cloud)."),
            "infoWorktree": L("워크트리", "Worktree"),
            "infoRules": L("AI 작업 규칙", "Rules for the AIs"),
            "infoRulesNone": L("프로젝트 폴더에 AGENTS.md나 CLAUDE.md를 두면 AI가 답할 때마다 읽어요.", "Put an AGENTS.md or CLAUDE.md in the project folder and the AIs read it with every answer."),
            "infoRulesHint": L("AI가 이 프로젝트에서 답할 때마다 읽는 파일이에요.", "The AIs read these with every answer in this project."),
            "infoFolders": L("폴더·파일", "Folders and files"),
            "infoFoldersHint": L("이 프로젝트의 모든 대화와 TODO에서 AI가 읽는 폴더와 파일이에요.", "Every chat and TODO of this project reads these folders and files."),
            "infoFoldersWork": L("★ 작업 폴더에서 일하고, 나머지는 폴더마다 읽기·수정이 정해져 있어요.", "The project works in the ★ work folder; the others are read or edited as set per folder."),
            "infoWorkFolder": L("작업 폴더", "Work folder"),
            "infoMissing": L("없음", "Missing"),
            "infoReadEdit": L("읽기·수정", "Read · edit"),
            "infoReadOnly": L("읽기만", "Read only"),
            "infoOff": L("읽기 끔", "Not read"),
            "infoNone": L("아직 없어요", "None yet"),
            "infoLinks": L("링크", "Links"),
            "infoMemory": L("프로젝트 기억", "Project memory"),
            "infoMemoryHint": L("이 프로젝트의 AI들이 함께 읽고 쓰는 메모예요 (사용 중인 것만).", "Notes every AI of this project reads and writes (those in use)."),
            "memDecision": L("결정·사실", "Decisions and facts"),
            "memProgress": L("진행 중", "Open progress"),
            "memLog": L("작업 기록", "Work log"),
            "memMore": L("외 {n}개는 Mac에서 볼 수 있어요", "{n} more on the Mac"),
            "memArchived": L("보관함 {n}개", "Archive: {n}"),
            "memNone": L("아직 메모가 없어요", "No notes yet"),
            "memVerified": L("확인됨", "verified"),
            "memGuess": L("추측", "guess"),
            "infoChatOnly": L("대화에만 연결된 자료", "Linked to one chat only"),
            "infoChatOnlyHint": L("이 프로젝트의 어떤 대화에만 붙어 있는 폴더·파일이에요.", "These are linked to a chat of this project only."),
            "infoLock": L("잠금", "Lock"),
            "lockPersonal": L("개인 프로젝트예요. 개인 계정과 내 Mac 모델만 써요.", "A personal project: only personal accounts and models on this Mac."),
            "lockEnterprise": L("{name} Enterprise 프로젝트예요. {name} 계정과 내 Mac 모델만 써요.", "A {name} Enterprise project: only {name} accounts and models on this Mac."),
            "lockLeft": L("아직 안 잠긴 대화 {chats}개 · TODO 목록 {lists}개", "Not locked yet: {chats} chats · {lists} TODO lists"),
            "infoTodos": L("남은 할 일", "TODOs left"),
            "todosNone": L("남은 할 일이 없어요", "No TODOs left"),
            "todosYours": L("내 차례", "Your turn"),
            "notesDone": L("완료", "Done"),
            "notesEmpty": L("이 대화의 메모예요. 나만 고칠 수 있고, AI는 답할 때 읽기만 해요.", "Notes for this chat. Only you edit them; the AI reads them when it answers."),
            "notesHint": L("AI는 읽기만 해요 · Mac의 메모와 같아요", "The AI only reads these · the same as on the Mac"),
            "notesSaving": L("저장 중…", "Saving…"),
            "notesSaved": L("저장됨", "Saved"),
            "notesFailed": L("저장하지 못했어요", "Could not save"),
            "usage": L("AI 사용량", "AI Usage"),
            "usageClose": L("닫기", "Close"),
            "usageRefresh": L("새로고침", "Refresh"),
            "usageLoading": L("사용량 확인 중…", "Loading usage…"),
            "usageChecking": L("확인 중…", "Checking…"),
            "usageRefreshing": L("새 측정값을 기다리는 중…", "Waiting for new readings…"),
            "usageWaiting": L("아직 새 측정값이 없어요. 자동으로 다시 확인해요.", "No new readings yet. The panel will check again automatically."),
            "usageThrottled": L("최근에 새로고침을 요청했어요. 잠시 후 다시 눌러 주세요.", "Refresh was requested recently. Try again in a moment."),
            "usageEmpty": L("표시할 계정이 없어요.", "No accounts to show."),
            "usageNoReading": L("{device} 기준 · 측정 기록 없음", "{device} · No readings yet"),
            "usageAge": L("{device} 기준 · {n}분 전 측정", "{device} · Measured {n} min ago"),
            "usageRecent": L("{device} 기준 · 방금 측정", "{device} · Measured just now"),
            "usageFive": L("5시간", "5h"),
            "usageWeek": L("주간", "Week"),
            "usageAccountCol": L("계정", "Account"),
            "usageDetailLine": L("{label}: {n}% 남음 · {time}", "{label}: {n}% left · {time}"),
            "usageSoon": L("곧", "now"),
            "usageLogin": L("로그인 필요", "Sign-in required"),
            "usageUnused": L("아직 안 씀", "Not used yet"),
            "usageRefilled": L("충전됨", "Refilled"),
            "usageRefills": L("{time} 후 충전", "Refills in {time}"),
            "usageDays": L("{n}일", "{n}d"),
            "usageHours": L("{n}시간", "{n}h"),
            "usageMinutes": L("{n}분", "{n}m"),
            "update": L("업데이트", "Update"),
            "updCurrent": L("이 Mac의 버전", "This Mac's version"),
            "updAvailable": L("업데이트 있음 {a} → {b}", "Update available {a} → {b}"),
            "updInstall": L("지금 업데이트", "Update Now"),
            "updCheck": L("업데이트 확인", "Check for Updates"),
            "updConfirm": L("새 버전을 시험·빌드한 뒤 앱이 재시작돼요. 재시작하는 1~2분 동안 연결이 끊겨요. 실행 중인 작업 {n}개가 끝난 뒤 교체돼요. 업데이트할까요?",
                            "The new version is tested and built, then the app restarts; the page is cut off for 1–2 minutes meanwhile. It is replaced after the {n} running tasks finish. Update now?"),
            "updWaitWork": L("실행 중인 작업 {n}개가 끝나면 교체돼요", "Replaced once the {n} running tasks finish"),
            "updRestarting": L("재시작 중… 다시 연결하는 중", "Restarting… reconnecting"),
            "updLost": L("5분 동안 다시 연결되지 않았어요. 업데이트가 실패해 이전 버전으로 되돌아갔거나 Mac이 응답하지 않을 수 있어요. 계속 다시 연결해 볼게요.",
                         "Not back after 5 minutes. The update may have failed and gone back to the previous version, or the Mac is not answering. Still trying to reconnect."),
            "updConfirming": L("새 버전이 켜졌어요 · 설치 확정을 기다리는 중…", "The new version is up · waiting for the install to be confirmed…"),
            "updDone": L("업데이트 완료 · {r}", "Updated · {r}"),
            "updRolledBack": L("새 버전이 제대로 켜지지 않아 이전 버전으로 돌아왔어요.", "The new version did not start properly; the previous version is back."),
            "updFailed": L("업데이트 실패", "Update failed"),
            "updLast": L("마지막 설치", "Last install"),
            "res-installed": L("성공", "Succeeded"),
            "res-rolled-back": L("롤백됨", "Rolled back"),
            "res-failed": L("실패", "Failed"),
            "updRemote": L("원격", "remote"),
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
<meta name="apple-mobile-web-app-status-bar-style" content="default">
<meta name="apple-mobile-web-app-title" content="AI Illuminati">
<meta name="color-scheme" content="light dark">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<title>AI Illuminati</title>
<style>
/* The Mac window's colors: a white chat, a light gray sidebar, the secondary gray, primary washes for bubbles and rows. */
:root { --bg:#fff; --side:#f5f5f6; --text:#1d1d1f; --dim:#86868b; --line:rgba(0,0,0,.1); --fill:rgba(0,0,0,.065); --press:rgba(0,0,0,.08);
  --box:#fff; --accent:#007aff; --warn:#e8870e; --red:#e5483d; --shade:.14; --bar:rgba(255,255,255,.78); --sidebar:rgba(245,245,246,.8); }
@media (prefers-color-scheme: dark) { :root { --bg:#1e1e1e; --side:#232325; --text:#ececec; --dim:#98989d; --line:rgba(255,255,255,.12);
  --fill:rgba(255,255,255,.085); --press:rgba(255,255,255,.1); --box:#2a2a2c; --accent:#0a84ff; --warn:#ff9f0a; --red:#ff6b60; --shade:.35;
  --bar:rgba(30,30,30,.78); --sidebar:rgba(35,35,37,.8); } }
* { box-sizing:border-box; -webkit-tap-highlight-color:transparent; }
html, body { margin:0; height:100%; overflow:hidden; background:var(--side); color:var(--text); font:16px -apple-system, system-ui, sans-serif;
  -webkit-text-size-adjust:100%; }
button { font:inherit; color:inherit; }
svg { display:block; }
.hidden { display:none !important; }

/* Two screens side by side: the chat slides over the list, which moves a little left under a shade (like iOS). */
.view { position:fixed; inset:0; display:flex; flex-direction:column; will-change:transform;
  transition:transform .38s cubic-bezier(.32,.72,0,1); }
#listView { background:var(--side); }
#chatView { background:var(--bg); transform:translateX(calc(100% + 30px)); z-index:2; box-shadow:-6px 0 24px rgba(0,0,0,.14); }
#shade { position:fixed; inset:0; background:#000; opacity:0; pointer-events:none; z-index:1; transition:opacity .38s cubic-bezier(.32,.72,0,1); }
body.open #chatView { transform:none; }
body.open #listView { transform:translateX(-30%); }
body.open #shade { opacity:var(--shade); }
body.instant .view, body.instant #shade, body.dragging .view, body.dragging #shade { transition:none !important; }
@media (prefers-reduced-motion: reduce) { .view, #shade { transition-duration:.01s; } }

/* Bars float over their scroll view, blurred, with a hairline once the content runs under them. */
.bar { position:absolute; left:0; right:0; top:0; z-index:3; padding:env(safe-area-inset-top) 6px 0; height:calc(env(safe-area-inset-top) + 48px);
  display:flex; align-items:center; gap:4px; -webkit-backdrop-filter:saturate(1.8) blur(20px); backdrop-filter:saturate(1.8) blur(20px);
  border-bottom:0.5px solid transparent; transition:border-color .2s; }
#listView .bar { background:var(--sidebar); } #chatView .bar { background:var(--bar); }
.bar.under { border-bottom-color:var(--line); }
.bar .mid { position:absolute; left:84px; right:84px; text-align:center; pointer-events:none; overflow:hidden; }
.bar .mid b { display:block; font-size:16px; font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
.bar .mid small { display:block; font-size:12px; color:var(--dim); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
/* The list's bar: this Mac's nickname in the middle, between the tools; once the list runs under it, the title above it. */
#listTitle { left:106px; right:106px; } #listTitle b { display:none; } #listView .bar.under #listTitle b { display:block; }
#listTitle .mac { font-size:15px; font-weight:600; } #listView .bar.under #listTitle .mac { font-size:12px; font-weight:400; }
#listTitle .mac:not(:empty)::before { content:''; display:inline-block; width:16px; height:12px; margin-right:5px; vertical-align:-1px; background:currentColor;
  -webkit-mask:url("data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 18'%3E%3Crect x='3.5' y='1' width='17' height='12' rx='2' fill='none' stroke='black' stroke-width='2'/%3E%3Cpath d='M1 16.5h22' stroke='black' stroke-width='2' stroke-linecap='round'/%3E%3C/svg%3E") center/contain no-repeat; }
.tool { width:44px; height:44px; border:0; background:none; color:var(--accent); display:flex; align-items:center; justify-content:center; border-radius:22px; }
.tool:active { background:var(--press); }
.back { border:0; background:none; color:var(--accent); display:flex; align-items:center; gap:2px; height:44px; padding:0 8px 0 4px; font-size:17px; }
.spacer { flex:1; }
.scroll { flex:1; overflow-y:auto; -webkit-overflow-scrolling:touch; overscroll-behavior-y:contain;
  padding:calc(env(safe-area-inset-top) + 48px) 0 0; }

/* The list, like the Mac sidebar: a big title, the search field, small section names, flat rows with rounded presses. */
#list { padding:0 10px calc(env(safe-area-inset-bottom) + 24px); }
h1 { font-size:30px; font-weight:700; margin:4px 12px 10px; letter-spacing:-.3px; }
.searchbox { display:flex; align-items:center; gap:8px; margin:0 10px 6px; }
.field { flex:1; display:flex; align-items:center; gap:7px; height:38px; padding:0 10px; border-radius:10px; background:var(--fill); color:var(--dim); }
.field input { flex:1; min-width:0; border:0; outline:0; background:none; color:var(--text); font:16px -apple-system, system-ui; }
.field input::placeholder { color:var(--dim); }
.field .clear { border:0; background:none; color:var(--dim); padding:4px; }
.cancel { border:0; background:none; color:var(--accent); font-size:16px; padding:6px 2px; }
.section { color:var(--dim); font-size:13px; font-weight:600; margin:18px 12px 4px; }
.row { display:flex; align-items:center; gap:10px; min-height:44px; padding:8px 12px; border-radius:10px; color:inherit; text-decoration:none; }
.row:active, .row.pressed { background:var(--press); }
.row .mark { width:12px; flex:none; display:flex; justify-content:center; }
.row .name { flex:1; min-width:0; }
.row .name > div { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.row .sub { color:var(--dim); font-size:13px; margin-top:1px; }
.row.child { padding-left:34px; }
.folder { font-weight:600; font-size:15px; }
.folder .chev { color:var(--dim); transition:transform .2s; flex:none; }
.folder.folded .chev { transform:rotate(-90deg); }
.folder .ficon { color:var(--dim); flex:none; }
.folder .tool { width:36px; height:36px; margin:-6px -8px -6px 0; color:var(--dim); }
.children.folded, .sbody.folded { display:none; }
/* A section the Mac's sidebar folds: tap its title (the chevron after it, as on the Mac). */
.section.fold { display:flex; align-items:center; gap:5px; margin-top:10px; padding:8px 0 4px; cursor:pointer; -webkit-tap-highlight-color:transparent; }
.section.fold .chev { transition:transform .2s; }
.section.fold.folded .chev { transform:rotate(-90deg); }
.more { display:flex; gap:18px; padding:6px 12px 8px 34px; }
.children .more { padding-left:56px; }
.more button { border:0; background:none; color:var(--accent); font:14px -apple-system, system-ui; padding:4px 0; }
.dot { width:8px; height:8px; border-radius:50%; background:var(--accent); }
.ring { width:11px; height:11px; border-radius:50%; border:2px solid var(--c, var(--dim)); border-right-color:transparent; animation:spin 1s linear infinite; }
.ring, .aidot { --c:var(--cl, var(--dim)); }
@media (prefers-color-scheme: dark) { .ring, .aidot { --c:var(--cd, var(--dim)); } }
@media (prefers-reduced-motion: reduce) { .ring, .spin { animation:none; } }
@keyframes spin { to { transform:rotate(360deg); } }
/* The inbox atop the list (the Mac's panel): 🔴 blocked and 🟡 to check, the time left on the right. */
.dot.red { background:var(--red); } .dot.yellow { background:#f2c200; }
.row .left { color:var(--dim); font-size:12px; flex:none; max-width:40%; text-align:right; }
.approval.inboxcard { margin:0 12px 10px 34px; padding:10px 12px; border-radius:12px; box-shadow:none; }
.approval.inboxcard .buttons { margin-top:6px; }
.badge { background:var(--warn); color:#fff; font-size:12px; font-weight:600; border-radius:9px; padding:1px 7px; flex:none; }
.result .snippet { color:var(--dim); font-size:13px; white-space:normal !important; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; }
mark { background:rgba(255,214,10,.45); color:inherit; border-radius:3px; padding:0 1px; }
.note { color:var(--dim); text-align:center; margin:44px 24px; line-height:1.5; }

/* The chat: the Mac transcript at phone size. */
#chatScroll { padding-bottom:12px; }
#turns { padding:6px 16px 0; }
.turn { display:flex; flex-direction:column; align-items:flex-start; margin:0 0 26px; }
.turn.mine { align-items:flex-end; margin-bottom:22px; }
.turn.mine.queued { opacity:.6; }
.day { align-self:stretch; text-align:center; color:var(--dim); font-size:12px; font-weight:500; margin:4px 0 18px; }
.bubble { max-width:84%; padding:9px 14px; border-radius:18px; background:var(--fill); line-height:1.45; overflow-wrap:anywhere; font-size:16px; }
.who { display:flex; align-items:center; gap:6px; color:var(--dim); font-size:13px; font-weight:500; margin:0 0 6px; }
.who .model { font-weight:400; opacity:.8; }
.aidot { width:7px; height:7px; border-radius:50%; background:var(--c, var(--dim)); flex:none; }
.meta { display:flex; align-items:center; gap:4px; color:var(--dim); font-size:12px; margin-top:4px; min-height:26px; }
.meta button { border:0; background:none; color:var(--dim); display:flex; align-items:center; gap:3px; padding:4px 6px; border-radius:8px; font-size:12px; }
.meta button:active { background:var(--press); }
.pics { display:flex; gap:6px; flex-wrap:wrap; justify-content:flex-end; margin-bottom:6px; max-width:100%; }
.turn:not(.mine) .pics { justify-content:flex-start; margin:8px 0 0; }
.pics img { max-width:200px; max-height:200px; border-radius:12px; display:block; object-fit:cover; }
.turn:not(.mine) .pics img { max-width:100%; max-height:none; }
/* Pictures where the answer put them ([Picture N] lines); two or more share the line, as on the Mac. */
.md .pics.inline { margin:8px 0; justify-content:flex-start; align-items:flex-start; }
.md .pics.pair img { max-width:calc(50% - 3px); min-width:0; }
.md .pics.inline span { color:var(--dim); }
.status { display:flex; align-items:center; gap:8px; color:var(--dim); font-size:14px; margin-top:4px; }
.status.warn { color:var(--warn); }
.spin { width:13px; height:13px; border-radius:50%; border:2px solid currentColor; border-right-color:transparent; animation:spin .9s linear infinite; flex:none; opacity:.8; }
.error { color:var(--red); font-size:14px; margin-top:6px; }
.found { animation:found 2.4s ease-out; border-radius:12px; }
@keyframes found { 0%, 40% { background:rgba(255,214,10,.22); } 100% { background:transparent; } }

/* Answers' markdown, sized like the Mac's 15 pt text with its line spacing. */
.md { width:100%; font-size:16px; line-height:1.6; overflow-wrap:anywhere; }
.md p { margin:0 0 10px; } .md > :last-child { margin-bottom:0; }
.md h1, .md h2, .md h3, .md h4 { line-height:1.3; margin:16px 0 8px; }
.md h1 { font-size:21px; } .md h2 { font-size:19px; } .md h3 { font-size:17px; } .md h4 { font-size:16px; }
.md > :first-child { margin-top:0; }
.md a { color:var(--accent); text-decoration:none; }
.md code { font:14px ui-monospace, Menlo, monospace; background:var(--fill); padding:1px 5px; border-radius:5px; }
.md .code { position:relative; margin:0 0 10px; }
.md pre { margin:0; padding:12px; padding-top:30px; background:var(--fill); border-radius:10px; overflow-x:auto; line-height:1.45; }
.md pre code { background:none; padding:0; font-size:13px; white-space:pre; }
.md .ccopy { position:absolute; top:4px; right:6px; border:0; background:none; color:var(--dim); font-size:12px; padding:4px 6px; border-radius:6px; }
.md blockquote { margin:0 0 10px; padding:0 0 0 12px; border-left:3px solid var(--line); color:var(--dim); }
.md hr { border:0; border-top:1px solid var(--line); margin:14px 0; }
.md .list { margin:0 0 10px; }
.md .li { display:flex; gap:8px; padding-left:calc(var(--lvl) * 18px); margin:3px 0; }
.md .li .mk { flex:none; min-width:12px; color:var(--dim); text-align:right; }
.md .li > div { flex:1; min-width:0; }
.md .tablewrap { overflow-x:auto; margin:0 0 10px; }
.md table { border-collapse:collapse; font-size:14px; line-height:1.4; }
.md th, .md td { border:1px solid var(--line); padding:6px 9px; text-align:left; vertical-align:top; }
.md th { background:var(--fill); font-weight:600; }

/* Approval cards like the Mac's banner. */
#approvals { padding:0 16px; }
.approval { background:var(--box); border:1px solid var(--warn); border-radius:16px; padding:14px; margin:0 0 16px; box-shadow:0 2px 10px rgba(0,0,0,.06); }
.approval b { display:block; margin-bottom:4px; }
.approval details { color:var(--dim); font-size:13px; margin:6px 0; }
.approval details pre { white-space:pre-wrap; overflow-wrap:anywhere; max-height:40vh; overflow:auto; }
.approval .buttons { display:flex; gap:10px; margin-top:10px; }
.approval button { flex:1; font-size:16px; font-weight:500; padding:10px; border-radius:12px; border:0; }
.allow { background:var(--accent); color:#fff !important; } .deny { background:var(--fill); }
.approval button:disabled { opacity:.5; }
/* The update screen (#update) and the list's update row. */
.upd { padding:8px 0 24px; line-height:1.5; }
.upd .kv { display:flex; justify-content:space-between; gap:12px; padding:10px 0; border-bottom:1px solid var(--line); }
.upd .kv span { color:var(--dim); } .upd .kv b { font:600 15px ui-monospace, Menlo, monospace; }
.upd .state { display:flex; align-items:flex-start; gap:8px; margin:14px 0 4px; }
.upd .state .spin { margin-top:5px; }
.upd .small { color:var(--dim); font-size:13px; overflow-wrap:anywhere; }
.upd .ok { color:#2e9d4b; font-weight:500; margin:12px 0; } .upd .fail { color:var(--red); font-weight:500; margin:12px 0; }
.upd .avail { margin:16px 0 8px; font-weight:600; }
.upd .buttons { display:flex; gap:10px; margin:14px 0; }
.upd button { flex:1; font-size:16px; font-weight:500; padding:10px; border-radius:12px; border:0; }
.upd button:disabled { opacity:.5; }
.upd .last { margin-top:22px; padding-top:12px; border-top:1px solid var(--line); }
.updrow { margin:4px 10px 0; background:var(--fill); }
.updrow .name > div { white-space:normal !important; }

#usagePanel { width:min(560px, calc(100% - 24px)); max-height:calc(100% - env(safe-area-inset-top) - env(safe-area-inset-bottom) - 24px);
  border:1px solid var(--line); border-radius:20px; padding:0; background:var(--bg); color:var(--text); }
#usagePanel[open] { display:flex; flex-direction:column; }
#usagePanel::backdrop { background:rgba(0,0,0,.44); }
.usageHead, .usageFoot { display:flex; align-items:center; justify-content:space-between; gap:12px; padding:10px 14px; }
.usageHead { border-bottom:1px solid var(--line); }
.usageHead h2 { font-size:18px; margin:0; }
.usageFoot { border-top:1px solid var(--line); font-size:13px; color:var(--dim); }
.usageHead button, .usageFoot button { flex:none; min-height:44px; padding:6px 10px; border:0; border-radius:10px; background:var(--fill); color:var(--accent); }
.usageFoot button:disabled { opacity:.5; }
#usageAge, #usageAccounts { min-width:0; overflow-wrap:anywhere; }
#usageAccounts { min-height:0; overflow:auto; overscroll-behavior:contain; padding:0 14px 14px; }
#usageStatus { color:var(--dim); font-size:13px; padding:0 14px; margin:0; }
#usageStatus:not(:empty) { padding-bottom:8px; }
/* Like the menu bar: a header, then per AI one row per account (bar, % left, time to refill); tap a row for its details. */
.usageCols, .usageRow { display:grid; grid-template-columns:minmax(0, 1fr) 7.4rem 7.4rem; gap:6px; align-items:center; }
.usageCols { color:var(--dim); font-size:12px; font-weight:500; padding:10px 0 0; }
.usageGroup h3 { color:var(--cl, var(--text)); font-size:13px; margin:12px 0 2px; }
@media (prefers-color-scheme: dark) { .usageGroup h3 { color:var(--cd, var(--text)); } }
.usageRow { width:100%; min-height:36px; padding:4px 0; border:0; background:none; color:var(--text); font:inherit; text-align:start; }
.usageName { display:flex; align-items:baseline; gap:4px; min-width:0; font-size:15px; }
.usageName > span:first-child { flex:0 1 auto; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.usageMark { flex:none; color:var(--dim); font-size:13px; } .usageMark.usageWarn { color:var(--warn); }
.usageSmall, .usageTime { color:var(--dim); font-size:13px; }
.usagePlan { flex:0 100 auto; min-width:0; max-width:2.6em; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.usageSpan { grid-column:2 / -1; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.usageLogin { color:var(--warn); }
.usageCell { display:flex; align-items:center; gap:5px; min-width:0; white-space:nowrap; }
.usageLeft { width:2.5em; text-align:right; font-size:14px; font-weight:600; font-variant-numeric:tabular-nums; color:var(--remaining, var(--text)); }
.usageTime { font-variant-numeric:tabular-nums; overflow:hidden; text-overflow:ellipsis; }
.usageLow { --remaining:var(--warn); } .usageCritical { --remaining:var(--red); }
.usageBar { flex:none; width:22px; height:5px; border-radius:5px; background:var(--fill); }
.usageBar i { display:block; height:100%; border-radius:inherit; background:var(--remaining, var(--text)); opacity:.8; }
.usageDetail { margin:2px 0 6px; padding:8px 12px; border-radius:10px; background:var(--fill); }
.usageDetail p { margin:2px 0; overflow-wrap:anywhere; }
/* Narrow phones: the menu bar's compact style, numbers only. */
@media (max-width:359px) {
  .usageCols, .usageRow { grid-template-columns:minmax(0, 1fr) 5.6rem 5.6rem; }
  .usageBar { display:none; }
}

/* The message box: one rounded card, text on top, + on the left and send on the right (the Mac's composer). */
footer { position:relative; padding:6px 10px calc(env(safe-area-inset-bottom) + 8px); background:var(--bg); }
.box { border-radius:22px; border:1px solid var(--line); background:var(--box); box-shadow:0 3px 12px rgba(0,0,0,.07); padding:10px 10px 8px 14px; }
.box textarea { display:block; width:100%; resize:none; border:0; outline:0; background:none; color:var(--text); padding:2px 0 6px;
  font:16px/1.4 -apple-system, system-ui; max-height:160px; }
.box textarea::placeholder { color:var(--dim); }
.boxrow { display:flex; align-items:center; gap:8px; }
.boxrow .hint { color:var(--dim); font-size:13px; }
.round { width:32px; height:32px; border-radius:16px; flex:none; display:flex; align-items:center; justify-content:center; padding:0; }
#pick { border:1px solid var(--line); background:none; color:var(--dim); }
#send { border:0; background:var(--accent); color:#fff; }
#send:disabled { background:var(--fill); color:var(--dim); }
#thumbs { display:flex; gap:8px; overflow-x:auto; }
#thumbs:not(:empty) { margin:2px 0 8px; padding-top:6px; }
.thumb { position:relative; flex:none; }
.thumb img { width:58px; height:58px; object-fit:cover; border-radius:10px; display:block; }
.thumb button { position:absolute; top:-6px; right:-6px; width:22px; height:22px; border-radius:11px; border:0; background:rgba(0,0,0,.7); color:#fff;
  font-size:12px; line-height:22px; padding:0; }
.readonly { display:flex; align-items:center; justify-content:center; gap:8px; color:var(--dim); font-size:14px; border-radius:20px;
  border:1px solid var(--line); background:var(--fill); padding:12px; }
/* @ or a first "/" being typed: the Mac's lists above the message box (who answers, or how). */
.picker { margin:0 0 6px; padding:4px; border-radius:16px; border:1px solid var(--line); background:var(--box); box-shadow:0 3px 12px rgba(0,0,0,.1);
  max-height:38vh; overflow-y:auto; }
.pick { display:flex; align-items:center; gap:9px; width:100%; height:40px; padding:0 10px; border:0; border-radius:11px; background:none;
  color:var(--text); font:15px -apple-system, system-ui; text-align:left; }
.pick.on { background:rgba(0,122,255,.16); }
.pick .aidot { width:8px; height:8px; }
.pick .plabel { flex:1; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.pick .ptitle { flex:none; font-weight:600; }
.pick code { flex:1; min-width:0; font:13px ui-monospace, Menlo, monospace; color:var(--dim); }
.pick .pright { flex:none; max-width:55%; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:var(--dim); font-size:12px; }
.pickNote { color:var(--dim); font-size:11px; text-align:center; padding:2px 0 3px; }
#toBottom { position:absolute; left:50%; top:-44px; margin-left:-17px; width:34px; height:34px; border-radius:17px; border:1px solid var(--line);
  background:var(--box); color:var(--text); box-shadow:0 1px 5px rgba(0,0,0,.2); display:flex; align-items:center; justify-content:center; padding:0;
  transition:opacity .15s; }
#toBottom.gone { opacity:0; pointer-events:none; }

/* Photos dragged over the chat: the whole screen takes them (a tint and a dashed frame; events pass through to the chat). */
#dropZone { position:absolute; inset:0; z-index:5; pointer-events:none; display:flex; align-items:center; justify-content:center;
  background:rgba(0,122,255,.16); }
#dropZone::before { content:''; position:absolute; inset:calc(env(safe-area-inset-top) + 10px) 10px calc(env(safe-area-inset-bottom) + 10px);
  border:2px dashed var(--accent); border-radius:20px; }
#dropZone.no { background:rgba(128,128,128,.16); } #dropZone.no::before { border-color:var(--dim); }
.dropCard { display:flex; flex-direction:column; align-items:center; gap:6px; padding:0 32px; text-align:center; color:var(--text); }
.dropCard svg { color:var(--accent); } #dropZone.no .dropCard svg { color:var(--dim); }
.dropCard b { font-size:17px; } .dropCard small { color:var(--dim); font-size:13px; }

/* A project's info (the Mac's Project info tab), only to read: its sections one under another. */
.info { padding:4px 16px 28px; }
.isum { color:var(--dim); font-size:13px; margin:2px 0 4px; }
.isec { margin-top:22px; }
.isec h3 { display:flex; align-items:baseline; gap:8px; font-size:16px; font-weight:600; margin:0 0 6px; }
.isec h3 small { color:var(--dim); font-size:12px; font-weight:400; }
.ihint { color:var(--dim); font-size:12px; margin:0 0 6px; line-height:1.4; }
.irow { display:flex; align-items:center; gap:9px; padding:8px 10px; border-radius:10px; background:var(--fill); margin-top:6px; }
.irow.work { background:rgba(0,122,255,.1); box-shadow:inset 0 0 0 1px rgba(0,122,255,.45); }
.irow .ic { flex:none; width:18px; display:flex; justify-content:center; color:var(--dim); } .irow.work .ic { color:var(--accent); }
.irow .im { flex:1; min-width:0; } .irow.dim .im { opacity:.55; }
.irow .im > div { overflow:hidden; text-overflow:ellipsis; white-space:nowrap; font-size:14px; }
.irow .im .p { color:var(--dim); font-size:12px; margin-top:1px; -webkit-user-select:text; user-select:text; }
.irow .iright { flex:none; color:var(--dim); font-size:12px; text-align:right; }
.ibadge { font-size:10px; font-weight:500; color:var(--dim); background:var(--fill); padding:1px 6px; border-radius:8px; margin-left:5px; }
.iwork { color:var(--accent); font-size:11px; margin-left:5px; } .imiss { color:var(--red); font-size:11px; font-weight:500; margin-left:5px; }
.ipre { margin:6px 0 0; padding:10px; border-radius:10px; background:var(--fill); font:12px/1.45 ui-monospace, Menlo, monospace; white-space:pre-wrap;
  overflow-wrap:anywhere; max-height:300px; overflow:auto; -webkit-user-select:text; user-select:text; }
.ikind { font-size:13px; font-weight:600; color:var(--dim); margin:12px 0 0; }
.inote { padding:8px 10px; border-radius:10px; background:var(--fill); margin-top:6px; font-size:14px; line-height:1.4; white-space:pre-wrap; overflow-wrap:anywhere;
  -webkit-user-select:text; user-select:text; }
.inote small { display:block; color:var(--dim); font-size:11px; margin-top:4px; }
.imore { color:var(--dim); font-size:12px; margin-top:6px; }
.itodo .im > div { white-space:normal; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; }
.itodo .iright { font-weight:500; }
.st-needsYou { color:var(--warn) !important; } .st-review { color:#c9a400 !important; } .st-running { color:var(--accent) !important; } .st-ready { color:#34c759 !important; }
.ionly { color:var(--dim); font-size:12px; text-align:center; margin-top:26px; }

/* The chat's notes (the Mac's 메모 panel): a sheet that slides in from the right over the chat, under a shade. */
#notes { position:fixed; top:0; bottom:0; right:0; width:min(88vw, 400px); z-index:6; display:flex; flex-direction:column; background:var(--bg);
  padding:env(safe-area-inset-top) 0 env(safe-area-inset-bottom); box-shadow:-6px 0 24px rgba(0,0,0,.18);
  transform:translateX(calc(100% + 30px)); transition:transform .38s cubic-bezier(.32,.72,0,1); will-change:transform; }
#notesShade { position:fixed; inset:0; z-index:5; background:#000; opacity:0; pointer-events:none; transition:opacity .38s cubic-bezier(.32,.72,0,1); }
body.notes #notes { transform:none; }
body.notes #notesShade { opacity:var(--shade); pointer-events:auto; }
body.ndrag #notes, body.ndrag #notesShade, body.ninstant #notes, body.ninstant #notesShade { transition:none !important; }
.nbar { display:flex; align-items:center; gap:8px; height:48px; padding:0 6px 0 16px; flex:none; }
.nbar b { font-size:17px; font-weight:600; }
.nbar .nstate { color:var(--dim); font-size:12px; }
#notesDone { border:0; background:none; color:var(--accent); font:600 17px -apple-system, system-ui; padding:8px 10px; }
#notesText { flex:1; min-height:0; margin:0 12px; padding:12px; border:1px solid var(--line); border-radius:14px; background:var(--box); color:var(--text);
  font:16px/1.45 -apple-system, system-ui; resize:none; outline:0; }
#notesText::placeholder { color:var(--dim); }
.nhint { color:var(--dim); font-size:12px; padding:8px 16px 10px; flex:none; }
#notesTool { color:var(--accent); }

#viewer { position:fixed; inset:0; z-index:10; background:rgba(0,0,0,.92); display:flex; align-items:center; justify-content:center; }
#viewer img { max-width:100%; max-height:100%; object-fit:contain; }
</style>
</head>
<body>
<div id="listView" class="view">
  <div class="bar" id="listBar">
    <div class="mid" id="listTitle"><b>AI Illuminati</b><small class="mac"></small></div>
    <button class="tool" id="usageTool" aria-haspopup="dialog"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4.2 17a9 9 0 1 1 15.6 0H4.2ZM12 14l4-5"/><circle cx="12" cy="14" r="1"/></svg></button>
    <button class="tool" id="updTool" aria-label="update"><svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="M12 7.5v8M8.5 12.5 12 16l3.5-3.5"/></svg></button>
    <div class="spacer"></div>
    <button class="tool" id="compose" aria-label="new chat"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6"/><path d="M17.6 3.4a1.9 1.9 0 0 1 2.7 2.7L12 14.4l-3.6.9.9-3.6z"/></svg></button>
  </div>
  <div class="scroll" id="listScroll">
    <h1>AI Illuminati</h1>
    <div class="searchbox">
      <label class="field"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m20 20-4.8-4.8"/></svg>
        <input id="q" type="search" enterkeyhint="search" autocomplete="off" autocorrect="off"><button class="clear hidden" id="qClear" aria-label="clear">✕</button></label>
      <button class="cancel hidden" id="qCancel"></button>
    </div>
    <a class="row updrow hidden" id="updRow" href="#update"><span class="mark"><span class="dot"></span></span><span class="name"><div id="updRowText"></div></span></a>
    <div id="list"></div>
  </div>
</div>
<div id="shade"></div>
<div id="chatView" class="view">
  <div class="bar" id="chatBar">
    <button class="back" id="back"><svg width="13" height="21" viewBox="0 0 13 21" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M11 2 2.5 10.5 11 19"/></svg><span id="backText"></span></button>
    <div class="mid"><b id="chatTitle"></b><small id="chatSub"></small></div>
    <div class="spacer"></div>
    <button class="tool hidden" id="notesTool" aria-haspopup="dialog"><svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="4.5" y="3" width="15" height="18" rx="2.5"/><path d="M8.5 8h7M8.5 12h7M8.5 16h4"/></svg></button>
  </div>
  <div class="scroll" id="chatScroll"><div id="turns"></div><div id="approvals"></div></div>
  <footer id="footer">
    <button id="toBottom" class="gone" aria-label="bottom"><svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v16M5 13l7 7 7-7"/></svg></button>
    <div class="readonly hidden" id="readOnly"></div>
    <div class="picker hidden" id="picker" role="listbox"></div>
    <div class="box" id="box">
      <div id="thumbs"></div>
      <textarea id="text" rows="1"></textarea>
      <div class="boxrow">
        <button class="round" id="pick" aria-label="photo"><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg></button>
        <span class="hint" id="hint"></span>
        <div class="spacer"></div>
        <button class="round" id="send" aria-label="send" disabled><svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20V4M5 11l7-7 7 7"/></svg></button>
      </div>
    </div>
    <input type="file" id="file" accept="image/*" multiple class="hidden">
  </footer>
  <div id="dropZone" class="hidden"><div class="dropCard">
    <svg width="44" height="36" viewBox="0 0 44 36" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"><rect x="2" y="2" width="40" height="32" rx="6"/><circle cx="13" cy="12" r="3.5" fill="currentColor" stroke="none"/><path d="M4 31l12-12 9 8 6-5 10 9"/></svg>
    <b id="dropTitle"></b><small id="dropSub"></small>
  </div></div>
</div>
<div id="notesShade"></div>
<aside id="notes" aria-hidden="true">
  <div class="nbar"><b id="notesTitle"></b><span class="nstate" id="notesState"></span><div class="spacer"></div><button id="notesDone"></button></div>
  <textarea id="notesText" autocomplete="off"></textarea>
  <div class="nhint" id="notesHint"></div>
</aside>
<div id="viewer" class="hidden"><img alt=""></div>
<dialog id="usagePanel" aria-labelledby="usageTitle">
  <div class="usageHead"><h2 id="usageTitle"></h2><button id="usageClose" autofocus></button></div>
  <div id="usageAccounts"></div>
  <p id="usageStatus" role="status"></p>
  <div class="usageFoot"><span id="usageAge"></span><button id="usageRefresh"></button></div>
</dialog>
<script>
const S = __STRINGS__;
const params = new URLSearchParams(location.search);
if (params.get('k')) localStorage.setItem('k', params.get('k'));
const KEY = params.get('k') || localStorage.getItem('k') || '';
const $ = id => document.getElementById(id);
const standalone = navigator.standalone === true || matchMedia('(display-mode: standalone)').matches;
const ICON_COPY = '<svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linejoin="round"><rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/></svg>';
const ICON_FOLDER = '<svg width="17" height="15" viewBox="0 0 24 20" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><path d="M2 4.5A2.5 2.5 0 0 1 4.5 2h4.2l2.3 2.6h8.5A2.5 2.5 0 0 1 22 7.1v8.4a2.5 2.5 0 0 1-2.5 2.5h-15A2.5 2.5 0 0 1 2 15.5z"/></svg>';
const ICON_CHEV = '<svg class="chev" width="10" height="10" viewBox="0 0 10 10" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d="m2 3.5 3 3 3-3"/></svg>';
const ICON_INFO = '<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M12 11v5.5"/><circle cx="12" cy="7.6" r=".6" fill="currentColor"/></svg>';
const ICON_DOC = '<svg width="14" height="16" viewBox="0 0 20 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linejoin="round"><path d="M3 3.5A1.5 1.5 0 0 1 4.5 2H13l5 5v13.5a1.5 1.5 0 0 1-1.5 1.5h-12A1.5 1.5 0 0 1 3 20.5z"/><path d="M13 2v5h5"/></svg>';
const ICON_NEW = '<svg width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4H6a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-6"/><path d="M17.6 3.4a1.9 1.9 0 0 1 2.7 2.7L12 14.4l-3.6.9.9-3.6z"/></svg>';

// current: what the chat screen shows ('<id>' or 'new:<project>'), null on the list. chatId: the chat's id once it exists.
const drafts = {}, cache = {}, titles = {}, projects = {};
let current = null, chatId = null, newProject = null, opened = false, timer = null, lastList = '', lastChat = '', photos = [], sending = false;
let navAnimate = false, pushed = false, searching = false, searchTimer = null, jump = null;
// Folds are the Mac sidebar's (each section and folder carries "fold" and "folded"; POST /api/fold), so Safari, the
// Home Screen app and another Mac's panel agree. A tap shows at once and holds until the Mac has it.
const foldWant = {}, foldTurn = {};
function isFolded(key, server) { return key in foldWant ? foldWant[key] : !!server; }
localStorage.removeItem('folded');   // this browser's own folds from before
const limits = {};   // lists lengthened with "Show more", like the Mac sidebar: in memory only, a reload starts short
function listPath() {
  return '/api/chats' + Object.keys(limits).map((k, i) => (i ? '&' : '?') + 'n.' + encodeURIComponent(k) + '=' + limits[k]).join('');
}
// "Show more (n)" under a shortened list, and "Show less" once it was lengthened.
function moreRow(m) {
  if (!m) return '';
  const expanded = (limits[m.key] || m.page) > m.page;
  if (!m.hidden && !expanded) return '';
  return '<div class="more" data-key="' + esc(m.key) + '" data-page="' + m.page + '">' +
    (m.hidden ? '<button data-more="1">' + esc(S.showMore.replace('{n}', m.hidden)) + '</button>' : '') +
    (expanded ? '<button data-less="1">' + esc(S.showLess) + '</button>' : '') + '</div>';
}

function esc(s) { return String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); }
// The same content gives the same text whatever order its keys came in: what "did it change" is compared with.
function stable(v) {
  return JSON.stringify(v, (k, x) => x && typeof x === 'object' && !Array.isArray(x)
    ? Object.fromEntries(Object.keys(x).sort().map(n => [n, x[n]])) : x);
}
function withKey(url) { return url + (url.includes('?') ? '&' : '?') + 'k=' + encodeURIComponent(KEY); }
function colorStyle(c) { return c && c.length === 2 ? ' style="--cl:' + esc(c[0]) + ';--cd:' + esc(c[1]) + '"' : ''; }
// `timeout` (ms): a request left hanging (the Mac restarting) fails instead of stopping the polling.
async function api(path, body, timeout) {
  const options = body === undefined ? { headers: { 'X-Remote-Key': KEY }, cache: 'no-store' }
    : { method: 'POST', headers: { 'X-Remote-Key': KEY, 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
  const abort = timeout ? new AbortController() : null, timer = abort && setTimeout(() => abort.abort(), timeout);
  if (abort) options.signal = abort.signal;
  const r = await fetch(path, options).finally(() => clearTimeout(timer));
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || r.status);
  return data;
}

// Markdown as the Mac draws it: headings, lists, quotes, tables, code blocks (with Copy), links, bold, italic, code.
function inline(s) {
  const codes = [];
  let out = esc(s).replace(/`([^`\n]+)`/g, (_, c) => { codes.push(c); return '\u0000' + (codes.length - 1) + '\u0000'; });
  out = out.replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>')
    .replace(/(^|[\s(])(https?:\/\/[^\s<]*[^\s<.,;:!?)'"])/g, '$1<a href="$2" target="_blank" rel="noopener">$2</a>')
    .replace(/\*\*([^*\n]+)\*\*/g, '<b>$1</b>').replace(/__([^_\n]+)__/g, '<b>$1</b>')
    .replace(/(^|[^*\w])\*([^*\s][^*\n]*?)\*(?!\*)/g, '$1<i>$2</i>').replace(/~~([^~\n]+)~~/g, '<s>$1</s>');
  return out.replace(/\u0000(\d+)\u0000/g, (_, i) => '<code>' + codes[+i] + '</code>');
}
const FENCE = /^\s*```/, HEAD = /^(#{1,6})\s+(.*)$/, RULE = /^\s*([-*_])(\s*\1){2,}\s*$/, ITEM = /^(\s*)([-*+]|\d+[.)])\s+(.*)$/,
  QUOTE = /^\s*>/, TROW = /^\s*\|.*\|\s*$/, TSEP = /^\s*\|?\s*:?-{2,}/,
  PICS = /^[ \t]*(?:\[(?:그림|Picture) \d+\][ \t]*)+$/, PIC = /\[(?:그림|Picture) (\d+)\]/g;
function startsBlock(l, next) { return FENCE.test(l) || HEAD.test(l) || RULE.test(l) || ITEM.test(l) || QUOTE.test(l) || PICS.test(l) || (TROW.test(l) && TSEP.test(next || '')); }
// A line of only [Picture N] markers is where those pictures go (places: N → link), side by side as on the Mac;
// a marker whose picture is not here stays as written. A marker inside a sentence stays text.
function pictureLine(l, places) {
  const found = [...l.matchAll(PIC)].map(m => ({ link: places[m[1]], marker: m[0] }));
  if (!found.some(f => f.link)) return '<p>' + esc(l.trim()) + '</p>';
  return '<div class="pics inline' + (found.length > 1 ? ' pair' : '') + '">' + found.map(f => f.link
    ? '<img src="' + esc(withKey(f.link)) + '" loading="lazy" alt="' + esc(f.marker) + '">' : '<span>' + esc(f.marker) + '</span>').join('') + '</div>';
}
function markdown(text, places) {
  places = places || {};
  const lines = String(text).replace(/\r/g, '').split('\n');
  let html = '', i = 0, m;
  const cells = r => r.trim().replace(/^\||\|$/g, '').split('|').map(c => c.trim());
  while (i < lines.length) {
    const l = lines[i];
    if (!l.trim()) { i++; continue; }
    if (FENCE.test(l)) {
      const code = []; i++;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) code.push(lines[i++]);
      i++;
      html += '<div class="code"><button class="ccopy">' + esc(S.copy) + '</button><pre><code>' + esc(code.join('\n')) + '</code></pre></div>';
    } else if ((m = l.match(HEAD))) {
      const n = Math.min(4, m[1].length); html += '<h' + n + '>' + inline(m[2]) + '</h' + n + '>'; i++;
    } else if (RULE.test(l)) { html += '<hr>'; i++;
    } else if (PICS.test(l)) { html += pictureLine(l, places); i++;
    } else if (TROW.test(l) && TSEP.test(lines[i + 1] || '')) {
      const rows = []; while (i < lines.length && TROW.test(lines[i])) rows.push(lines[i++]);
      html += '<div class="tablewrap"><table><thead><tr>' + cells(rows[0]).map(c => '<th>' + inline(c) + '</th>').join('') + '</tr></thead><tbody>' +
        rows.slice(2).map(r => '<tr>' + cells(r).map(c => '<td>' + inline(c) + '</td>').join('') + '</tr>').join('') + '</tbody></table></div>';
    } else if (QUOTE.test(l)) {
      const q = []; while (i < lines.length && QUOTE.test(lines[i])) q.push(lines[i++].replace(/^\s*>\s?/, ''));
      html += '<blockquote>' + markdown(q.join('\n'), places) + '</blockquote>';
    } else if (ITEM.test(l)) {
      const items = [];
      while (i < lines.length) {
        const mm = lines[i].match(ITEM);
        if (mm) { items.push({ lvl: Math.min(3, Math.floor(mm[1].length / 2)), mark: /\d/.test(mm[2]) ? mm[2].replace(')', '.') : '•', text: mm[3] }); i++; }
        else if (items.length && /^\s{2,}\S/.test(lines[i])) { items[items.length - 1].text += '\n' + lines[i++].trim(); }
        else break;
      }
      html += '<div class="list">' + items.map(it => '<div class="li" style="--lvl:' + it.lvl + '"><span class="mk">' + esc(it.mark) + '</span><div>' +
        it.text.split('\n').map(inline).join('<br>') + '</div></div>').join('') + '</div>';
    } else {
      const p = [lines[i++]];
      while (i < lines.length && lines[i].trim() && !startsBlock(lines[i], lines[i + 1])) p.push(lines[i++]);
      html += '<p>' + p.map(inline).join('<br>') + '</p>';
    }
  }
  return html;
}

// Screens: the chat slides in from the right for our own taps and swipes. Safari's own back swipe has already moved
// the page, so a hash change we did not make switches at once instead of sliding a second time.
function setOpen(open, animate) {
  const b = document.body;
  if (!animate) b.classList.add('instant');
  b.classList.toggle('open', open);
  $('listView').setAttribute('aria-hidden', open ? 'true' : 'false');
  if (!animate) requestAnimationFrame(() => requestAnimationFrame(() => b.classList.remove('instant')));
}
function go(hash) { navAnimate = true; pushed = true; location.hash = hash; }
function back() {
  navAnimate = true;
  if (pushed) { pushed = false; history.back(); }
  else { history.replaceState(null, '', location.pathname + location.search); route(); }
}
function route() {
  const h = location.hash;
  let m, id = null, project = null, isNew = false;
  const isUpdate = h === '#update';
  let info = null;
  if ((m = h.match(/^#c=(.+)$/))) id = decodeURIComponent(m[1]);
  else if ((m = h.match(/^#info=(.+)$/))) info = decodeURIComponent(m[1]);
  else if ((m = h.match(/^#new(?:=(.*))?$/))) { isNew = true; project = m[1] ? decodeURIComponent(m[1]) : null; }
  const key = isUpdate ? 'update' : info !== null ? 'info:' + info : id || (isNew ? 'new:' + (project || '') : null);
  const animate = navAnimate; navAnimate = false;
  if (current !== null) { drafts[current] = $('text').value; draftPicked[current] = picked; }
  if (!key) pushed = false;
  if (key !== current) notesLeave();
  if (key && key !== current) {
    chatId = id; newProject = project; opened = false; lastChat = ''; photos = []; renderThumbs();
    $('text').value = drafts[key] || ''; picked = draftPicked[key] || []; menuClose(); setPicks(null);
    $('turns').innerHTML = ''; $('approvals').innerHTML = '';
    const known = id ? titles[id] : null;
    $('chatTitle').textContent = id ? (known ? known.title : '') : S.newChat;
    $('chatSub').textContent = chatSub(id ? (known && known.detail || '') : (project && projects[project] || ''));
    $('footer').classList.remove('hidden'); $('readOnly').classList.add('hidden'); $('box').classList.remove('hidden');
    grow();   // after the box shows again: measured while hidden (the update screen), it would shrink to nothing
    $('hint').textContent = '';
    if (id && cache[id]) renderChat(cache[id], true);
    else if (!id) $('turns').innerHTML = '<div class="note">' + esc(S.askAnything) + '</div>';
    if (isNew) api('/api/chat/new' + (project ? '?project=' + encodeURIComponent(project) : '')).then(p => { if (current === key) setPicks(p); }, () => {});
    $('chatScroll').scrollTop = 1e9;
    if (isNew) setTimeout(() => $('text').focus(), animate ? 380 : 0);
    if (isUpdate) { $('turns')._upd = ''; $('footer').classList.add('hidden'); $('chatTitle').textContent = S.update; $('chatSub').textContent = ''; renderUpdate(); }
    if (info !== null) {
      infoId = info; lastInfo = ''; $('footer').classList.add('hidden'); $('turns').innerHTML = '';
      $('chatTitle').textContent = projects[info] || ''; $('chatSub').textContent = chatSub(S.projectInfo); $('chatScroll').scrollTop = 0;
    }
  }
  current = key;
  if (!key) { chatId = null; document.activeElement && document.activeElement.blur && document.activeElement.blur(); }
  setOpen(!!key, animate);
  poll();
}
function poll() {
  clearTimeout(timer);
  if (document.hidden) return;
  const onInfo = !!current && current.startsWith('info:');
  const work = current === 'update' ? loadUpdate() : onInfo ? loadInfo() : chatId && current ? loadChat() : !current ? loadList() : Promise.resolve();
  work.finally(() => { timer = setTimeout(poll, current === 'update' ? 2000 : onInfo ? 5000 : current ? 1500 : 4000); });
}

// The list, in the Mac sidebar's sections; a project's chats fold under its row (remembered on this phone).
function chatRow(c, child) {
  titles[c.id] = { title: c.title, detail: c.detail || '' };
  const mark = c.working ? '<span class="ring"' + colorStyle(c.color) + '></span>' : c.unread ? '<span class="dot"></span>' : '';
  return '<a class="row' + (child ? ' child' : '') + '" href="#c=' + encodeURIComponent(c.id) + '" data-id="' + esc(c.id) + '"><span class="mark">' + mark + '</span>' +
    '<span class="name"><div>' + esc(c.title) + '</div>' + (c.detail ? '<div class="sub">' + esc(c.detail) + '</div>' : '') + '</span>' +
    (c.approvals ? '<span class="badge">' + c.approvals + '</span>' : '') + '</a>';
}
// The inbox's 🔴/🟡 (GET /api/chats "inbox"): a row opens its chat (a TODO is answered there, through the message box);
// a chat's approval has Deny / Allow under it, like its card. Open details stay open while the list redraws.
const inboxOpen = new Set();
function inboxRows(items) {
  if (!items || !items.length) return '';
  return '<div class="section">' + esc(S.inbox) + '</div>' + items.map(i => {
    const inner = '<span class="mark"><span class="dot ' + (i.level === 'red' ? 'red' : 'yellow') + '"></span></span>' +
      '<span class="name"><div>' + esc(i.name) + '</div><div class="sub">' + esc(i.line) + '</div></span>' +
      (i.time ? '<span class="left">' + esc(i.time) + '</span>' : '');
    if (i.room) titles[i.room] = titles[i.room] || { title: i.name, detail: '' };
    const row = i.room ? '<a class="row" href="#c=' + encodeURIComponent(i.room) + '" data-id="' + esc(i.room) + '">' + inner + '</a>'
      : '<div class="row">' + inner + '</div>';
    if (!i.approval) return row;
    return row + '<div class="approval inboxcard">' +
      (i.detail ? '<details data-open="' + esc(i.approval) + '"' + (inboxOpen.has(i.approval) ? ' open' : '') + '><summary>' + esc(S.details) + '</summary><pre>' + esc(i.detail) + '</pre></details>' : '') +
      '<div class="buttons"><button class="deny" data-approve="' + esc(i.approval) + '" data-allow="0">' + esc(S.deny) + '</button>' +
      '<button class="allow" data-approve="' + esc(i.approval) + '" data-allow="1">' + esc(S.allow) + '</button></div></div>';
  }).join('');
}
$('list').addEventListener('toggle', e => {
  const d = e.target; if (!d.dataset || !d.dataset.open) return;
  d.open ? inboxOpen.add(d.dataset.open) : inboxOpen.delete(d.dataset.open);
}, true);
// This Mac's nickname from each answer (kept for the next start), so two Macs' pages are told apart: in the middle of the
// list's bar, first in the chat's small line.
let macName = localStorage.getItem('mac') || '';
function showMac(name) {
  if (typeof name !== 'string' || !name || name === macName && document.querySelector('.mac').textContent) return;
  macName = name; localStorage.setItem('mac', name);
  document.querySelectorAll('.mac').forEach(e => { e.textContent = name; });
  document.querySelectorAll('#chatSub').forEach(e => { e.textContent = chatSub(e._detail || ''); });
}
function chatSub(detail) { $('chatSub')._detail = detail; return [macName, detail].filter(Boolean).join(' · '); }
showMac(macName);
function renderList(data) {
  showMac(data.device);
  const top = inboxRows(data.inbox);
  if (!data.sections.length && !top) { $('list').innerHTML = '<div class="note">' + esc(S.empty) + '</div>'; return; }
  $('list').innerHTML = top + data.sections.map(s => {
    const sf = s.fold && isFolded(s.fold, s.folded) ? ' folded' : '';
    let out = s.fold ? '<div class="section fold' + sf + '" data-fold="' + esc(s.fold) + '" role="button">' + esc(s.title) + ICON_CHEV + '</div><div class="sbody' + sf + '">'
      : '<div class="section">' + esc(s.title) + '</div>', open = false, folderMore = null;
    const close = () => { out += moreRow(folderMore) + '</div>'; open = false; folderMore = null; };
    for (const c of s.chats) {
      if (c.folder) {
        if (open) close();
        projects[c.project] = c.folder;
        const f = isFolded(c.fold, c.folded) ? ' folded' : '';
        out += '<div class="row folder' + f + '" data-fold="' + esc(c.fold) + '"><span class="mark">' + ICON_CHEV + '</span><span class="ficon">' + ICON_FOLDER + '</span>' +
          '<span class="name"><div>' + esc(c.folder) + '</div></span>' + (c.approvals ? '<span class="badge">' + c.approvals + '</span>' : '') +
          '<button class="tool" data-info="' + esc(c.project) + '" aria-label="' + esc(S.projectInfo) + '">' + ICON_INFO + '</button>' +
          '<button class="tool" data-new="' + esc(c.project) + '" aria-label="' + esc(S.newIn) + '">' + ICON_NEW + '</button></div><div class="children' + f + '">';
        open = true; folderMore = c.more || null;
      } else {
        if (open && !c.depth) close();
        out += chatRow(c, open);
      }
    }
    if (open) close();
    return out + moreRow(s.more) + (s.fold ? '</div>' : '');
  }).join('');
}
async function loadList() {
  if (searching) return;
  if (!KEY) { $('list').innerHTML = '<div class="note">' + esc(S.noKey) + '</div>'; return; }
  loadUpdate();
  try {
    const data = await api(listPath());
    if (searching) return;
    const text = stable(data);
    if (text === lastList) return;
    lastList = text;
    renderList(data);
  } catch (e) { $('list').innerHTML = '<div class="note">' + esc(String(e.message) === '401' ? S.noKey : (e.message || S.offline)) + '</div>'; lastList = ''; }
}
$('list').addEventListener('click', async e => {
  const decide = e.target.closest('button[data-approve]');
  if (decide) {
    e.preventDefault();
    decide.parentNode.querySelectorAll('button').forEach(x => x.disabled = true);
    try { await api('/api/approval/' + encodeURIComponent(decide.dataset.approve), { allow: decide.dataset.allow === '1' }); } catch (err) { alert(err.message); }
    lastList = ''; loadList();
    return;
  }
  const more = e.target.closest('.more button');
  if (more) {
    e.preventDefault();
    const box = more.parentElement, key = box.dataset.key, page = Number(box.dataset.page);
    if (more.dataset.more) limits[key] = (limits[key] || page) + page; else delete limits[key];
    lastList = ''; loadList();
    return;
  }
  const about = e.target.closest('[data-info]');
  if (about) { e.preventDefault(); go('#info=' + encodeURIComponent(about.dataset.info)); return; }
  const add = e.target.closest('[data-new]');
  if (add) { e.preventDefault(); go('#new=' + encodeURIComponent(add.dataset.new)); return; }
  const fold = e.target.closest('[data-fold]');
  if (fold) {
    const key = fold.dataset.fold, now = !fold.classList.contains('folded'), turn = (foldTurn[key] || 0) + 1;
    foldWant[key] = now; foldTurn[key] = turn;
    fold.classList.toggle('folded', now); fold.nextElementSibling.classList.toggle('folded', now);
    api('/api/fold', { key, folded: now }).catch(() => {}).finally(() => { if (foldTurn[key] === turn) delete foldWant[key]; lastList = ''; loadList(); });
    return;
  }
  const row = e.target.closest('a.row'); if (!row) return;
  e.preventDefault();
  row.classList.add('pressed'); setTimeout(() => row.classList.remove('pressed'), 400);
  jump = row.dataset.turn ? { turn: row.dataset.turn, words: row.dataset.words || '' } : null;
  go('#c=' + encodeURIComponent(row.dataset.id));
});
$('compose').addEventListener('click', () => go('#new'));
const usagePanel = $('usagePanel'), usageRefresh = $('usageRefresh'), usageStatus = $('usageStatus');
let usageTimer = null, usagePending = false, usageSnapshot = null, usageBurst = null;

function usageReadingTimes(data) {
  // The footer shows the oldest reading, which can stay the same when one account is still cached.
  return stable(data.groups.map(group => group.accounts.map(account => account.checkedAt)));
}

function usageRefill(resetsAt, now) {
  if (resetsAt === null) return S.usageUnused;
  if (resetsAt <= now) return S.usageRefilled;
  const minutes = Math.floor((resetsAt - now) / 60000);
  let time;
  if (minutes < 60) {
    time = S.usageMinutes.replace('{n}', Math.max(minutes, 1));
  } else if (minutes < 1440) {
    time = S.usageHours.replace('{n}', Math.floor(minutes / 60));
    if (minutes % 60) time += ' ' + S.usageMinutes.replace('{n}', minutes % 60);
  } else {
    time = S.usageDays.replace('{n}', Math.floor(minutes / 1440));
    const hours = Math.floor((minutes % 1440) / 60);
    if (hours) time += ' ' + S.usageHours.replace('{n}', hours);
  }
  return S.usageRefills.replace('{time}', time);
}

// The menu bar's short time to refill: "2h 36m", "2d 19h".
function usageShort(resetsAt, now) {
  if (resetsAt === null) return '—';
  const minutes = Math.max(0, Math.ceil((resetsAt - now) / 60000));
  if (minutes === 0) return S.usageSoon;
  if (minutes < 60) return S.usageMinutes.replace('{n}', minutes);
  const [big, small, size, rest] = minutes < 1440
    ? [S.usageHours, S.usageMinutes, 60, minutes % 60]
    : [S.usageDays, S.usageHours, 1440, Math.floor((minutes % 1440) / 60)];
  const head = big.replace('{n}', Math.floor(minutes / size));
  return rest ? head + ' ' + small.replace('{n}', rest) : head;
}

function usageRemaining(limit, now) { return limit.resetsAt !== null && limit.resetsAt <= now ? 100 : limit.left; }
function usageLevel(remaining) { return remaining < 10 ? ' usageCritical' : remaining < 30 ? ' usageLow' : ''; }

function usageCell(limit, now) {
  if (!limit) return '<span class="usageCell usageSmall">—</span>';
  const remaining = usageRemaining(limit, now);
  return '<span class="usageCell' + usageLevel(remaining) + '">' +
    '<span class="usageBar" aria-hidden="true"><i style="width:' + remaining + '%"></i></span>' +
    '<span class="usageLeft">' + Math.round(remaining) + '%</span>' +
    '<span class="usageTime">' + esc(usageShort(limit.resetsAt, now)) + '</span></span>';
}

// "Claude (개인)" under the Claude title reads "개인", as in the menu bar.
function usageShortName(name, group) {
  if (!name.startsWith(group)) return name;
  const rest = name.slice(group.length).trim();
  return /^\(.*\)$/.test(rest) ? rest.slice(1, -1) : rest || name;
}

const usageOpen = new Set();   // rows the user opened stay open across the 45-second refreshes

function usageRow(g, a, now) {
  const key = g.provider + '\n' + a.name;
  const login = a.needsLogin && g.provider !== 'ollama';
  const more = Boolean(a.note || a.extras.length || login);
  const mark = login ? '<span class="usageMark usageWarn" aria-hidden="true">!</span>'
    : more ? '<span class="usageMark" aria-hidden="true">ⓘ</span>' : '';
  let cells;
  if (a.checkedAt === null && !a.fiveHour && !a.weekly && !a.note && !a.extras.length) {
    cells = '<span class="usageSpan usageSmall">' + esc(S.usageChecking) + '</span>';
  } else if (!a.fiveHour && !a.weekly && (login || a.extras.length)) {
    cells = login ? '<span class="usageSpan usageSmall usageLogin">' + esc(S.usageLogin) + '</span>'
      : '<span class="usageSpan usageSmall">' + esc(a.extras[0]) + '</span>';
  } else {
    cells = usageCell(a.fiveHour, now) + usageCell(a.weekly, now);
  }
  const open = usageOpen.has(key);
  const line = (label, limit) => limit ? '<p>' + esc(S.usageDetailLine.replace('{label}', label)
    .replace('{n}', Math.round(usageRemaining(limit, now))).replace('{time}', () => usageRefill(limit.resetsAt, now))) + '</p>' : '';
  const detail = !open ? '' : '<div class="usageDetail usageSmall">' +
    (a.plan ? '<p>' + esc(a.plan) + '</p>' : '') + line(S.usageFive, a.fiveHour) + line(S.usageWeek, a.weekly) +
    a.extras.map(extra => '<p>' + esc(extra) + '</p>').join('') +
    (a.note ? '<p>' + esc(a.note) + '</p>' : '') +
    (login ? '<p class="usageLogin">' + esc(S.usageLogin) + '</p>' : '') + '</div>';
  return '<button class="usageRow" type="button" aria-expanded="' + open + '" data-key="' + esc(key) + '">' +
    '<span class="usageName"><span>' + esc(usageShortName(a.name, g.name)) + '</span>' +
    (a.plan ? '<span class="usageSmall usagePlan">' + esc(a.plan) + '</span>' : '') + mark + '</span>' +
    cells + '</button>' + detail;
}

function renderUsage(data) {
  const now = Date.now();
  const minutes = Math.max(0, Math.floor((now - data.checkedAt) / 60000));
  const age = data.checkedAt === null ? S.usageNoReading : minutes > 0 ? S.usageAge : S.usageRecent;
  $('usageAge').textContent = age.replace('{n}', minutes).replace('{device}', () => data.device);
  const groups = data.groups.filter(g => g.accounts.length);
  $('usageAccounts').innerHTML = !groups.length ? '<p class="note">' + esc(S.usageEmpty) + '</p>' :
    '<div class="usageCols" aria-hidden="true"><span>' + esc(S.usageAccountCol) + '</span><span>' + esc(S.usageFive) +
    '</span><span>' + esc(S.usageWeek) + '</span></div>' +
    groups.map(g => '<section class="usageGroup"' + colorStyle(g.color) + '><h3>' + esc(g.name) + '</h3>' +
      g.accounts.map(a => usageRow(g, a, now)).join('') + '</section>').join('');
}

$('usageAccounts').addEventListener('click', e => {
  const row = e.target.closest('.usageRow');
  if (!row || !usageSnapshot) return;
  const key = row.dataset.key;
  usageOpen.has(key) ? usageOpen.delete(key) : usageOpen.add(key);
  renderUsage(usageSnapshot);
});

async function loadUsage(refresh = false) {
  clearTimeout(usageTimer);
  if (!usagePanel.open || document.hidden || usagePending) return;
  if (!KEY) { usageStatus.textContent = S.noKey; return; }
  usagePending = true;
  usageRefresh.disabled = true;
  if (!usageSnapshot) usageStatus.textContent = S.usageLoading;
  try {
    usageSnapshot = await api(refresh ? '/api/usage/refresh' : '/api/usage', refresh ? {} : undefined, 8000);
    if (!usagePanel.open) return;
    renderUsage(usageSnapshot);
    if (refresh && usageSnapshot.refreshStarted) {
      usageBurst = { times: usageReadingTimes(usageSnapshot), deadline: performance.now() + 20000 };
      usageStatus.textContent = S.usageRefreshing;
    } else if (refresh) {
      usageStatus.textContent = S.usageThrottled;
    } else if (!usageBurst || usageReadingTimes(usageSnapshot) !== usageBurst.times) {
      usageBurst = null;
      usageStatus.textContent = '';
    } else if (performance.now() >= usageBurst.deadline) {
      usageBurst = null;
      usageStatus.textContent = S.usageWaiting;
    } else {
      usageStatus.textContent = S.usageRefreshing;
    }
  } catch {
    if (usageBurst && performance.now() >= usageBurst.deadline) usageBurst = null;
    if (usagePanel.open) usageStatus.textContent = S.offline;
  } finally {
    usagePending = false;
    usageRefresh.disabled = Boolean(usageBurst);
    if (usagePanel.open && !document.hidden) {
      const delay = usageBurst ? Math.min(3000, Math.max(0, usageBurst.deadline - performance.now())) : 45000;
      usageTimer = setTimeout(loadUsage, delay);
    }
  }
}

$('usageTool').setAttribute('aria-label', S.usage);
$('usageTitle').textContent = S.usage;
$('usageClose').textContent = S.usageClose;
usageRefresh.textContent = S.usageRefresh;
$('usageTool').addEventListener('click', () => {
  usagePanel.showModal();
  if (usageSnapshot) renderUsage(usageSnapshot);
  loadUsage();
});
$('usageClose').addEventListener('click', () => usagePanel.close());
usagePanel.addEventListener('close', () => {
  if (usagePanel.open) return;
  clearTimeout(usageTimer);
  usageBurst = null;
  usageRefresh.disabled = usagePending;
  usageStatus.textContent = '';
});
usageRefresh.addEventListener('click', () => loadUsage(true));
document.addEventListener('visibilitychange', () => loadUsage());
$('updTool').addEventListener('click', () => go('#update'));
$('updRow').addEventListener('click', e => { e.preventDefault(); go('#update'); });

// Updating this Mac from the phone: Update Now restarts the app, so the page loses it for a while. `track` (kept on this
// phone) says which version it left from; a new version answering means done, the old one answering again after the
// break (or reporting a failure) means it failed or went back, and 5 minutes without an answer says it may have.
let upd = null, updNote = null, track = JSON.parse(localStorage.getItem('updTrack') || 'null');
const LOST_AFTER = 5 * 60 * 1000;
function short(r) { return String(r || '').slice(0, 7); }
function saveTrack() { track ? localStorage.setItem('updTrack', JSON.stringify(track)) : localStorage.removeItem('updTrack'); }
async function loadUpdate() {
  try {
    const s = await api('/api/update', undefined, 8000);
    upd = s;
    if (track) {
      // The new app answers before it has acknowledged; only the installer's "installed" for this version is final.
      if (s.current && s.current !== track.from) {
        track.lostAt = null;
        if (s.last && s.last.result === 'installed' && s.last.revision === s.current) { updNote = { ok: true, text: S.updDone.replace('{r}', short(s.current)) }; track = null; }
        else track.confirming = true;
      }
      else if (s.busy || s.waiting) track.lostAt = null;   // a short break while it was still testing or building
      else { updNote = { ok: false, text: track.lostAt ? S.updRolledBack : S.updFailed }; track = null; }
      saveTrack();
    }
  } catch (e) {
    if (String(e.message) === '401') upd = { error: S.noKey };
    else if (track) { if (!track.lostAt) { track.lostAt = Date.now(); saveTrack(); } }
    else upd = Object.assign({}, upd, { error: e.message || S.offline });
  }
  renderUpdate();
}
function renderUpdate() {
  const s = upd || {}, offline = track && track.lostAt, confirming = track && !offline && track.confirming && s.current !== track.from;
  const shown = s.available || s.busy || s.waiting || track;
  $('updRow').classList.toggle('hidden', !shown || !!s.error && !track);
  $('updRowText').textContent = offline ? S.updRestarting : confirming ? S.updConfirming : s.progress ? s.progress.summary
    : s.waiting ? S.updWaitWork.replace('{n}', s.work || 0) : s.available ? S.updAvailable.replace('{a}', short(s.current)).replace('{b}', short(s.available)) : '';
  if (current !== 'update') return;
  let h = '<div class="upd">';
  if (s.error && !track) h += '<div class="fail">' + esc(s.error) + '</div>';
  if (s.current !== undefined) h += '<div class="kv"><span>' + esc(S.updCurrent) + '</span><b>' + esc(short(s.current) || '?') + '</b></div>' +
    '<div class="kv"><span>' + esc(S.update) + '</span><span>' + esc(s.channelLabel || '') + '</span></div>';
  if (offline) {
    const lost = Date.now() - track.lostAt > LOST_AFTER;
    h += '<div class="state">' + (lost ? '' : '<span class="spin"></span>') + '<div' + (lost ? ' class="fail"' : '') + '>' + esc(lost ? S.updLost : S.updRestarting) + '</div></div>';
  } else if (confirming) {
    h += '<div class="state"><span class="spin"></span><div>' + esc(S.updConfirming) + '</div></div>';
  } else if (s.progress) {
    h += '<div class="state">' + (s.progress.failed ? '' : '<span class="spin"></span>') + '<div>' + esc(s.progress.summary) +
      (s.progress.line ? '<div class="small">' + esc(s.progress.line) + '</div>' : '') + '</div></div>';
  } else if (s.text) h += '<div class="state"><div>' + esc(s.text) + '</div></div>';
  if (s.waiting) h += '<div class="small">' + esc(S.updWaitWork.replace('{n}', s.work || 0)) + '</div>';
  if (updNote) h += '<div class="' + (updNote.ok ? 'ok' : 'fail') + '">' + esc(updNote.text) + '</div>';
  const free = s.current !== undefined && !s.busy && !s.waiting && !track;
  if (s.available && free) h += '<div class="avail">' + esc(S.updAvailable.replace('{a}', short(s.current)).replace('{b}', short(s.available))) + '</div>';
  if (s.current !== undefined) h += '<div class="buttons"><button class="deny" data-upd="check"' + (free ? '' : ' disabled') + '>' + esc(S.updCheck) + '</button>' +
    (s.available ? '<button class="allow" data-upd="install"' + (free ? '' : ' disabled') + '>' + esc(S.updInstall) + '</button>' : '') + '</div>';
  if (s.last) {
    const at = s.last.at ? new Date(s.last.at) : null;
    h += '<div class="last"><div><b>' + esc(S.updLast) + '</b> · ' + esc(S['res-' + s.last.result] || s.last.result) + (s.last.remote ? ' · ' + esc(S.updRemote) : '') +
      (s.last.revision ? ' · ' + esc(short(s.last.revision)) : '') + (at && !isNaN(at) ? ' · ' + esc(at.toLocaleString()) : '') + '</div>' +
      (s.last.detail ? '<div class="small">' + esc(s.last.detail) + '</div>' : '') + (s.last.log ? '<div class="small">' + esc(s.last.log) + '</div>' : '') + '</div>';
  }
  h += '</div>';
  if ($('turns')._upd !== h) { $('turns')._upd = h; $('turns').innerHTML = h; }
}
$('turns').addEventListener('click', async e => {
  const b = e.target.closest('button[data-upd]'); if (!b || current !== 'update') return;
  const install = b.dataset.upd === 'install';
  if (install && !confirm(S.updConfirm.replace('{n}', (upd && upd.work) || 0))) return;
  b.disabled = true;
  updNote = null;
  try {
    const s = await api('/api/update/' + b.dataset.upd, {});
    upd = s;
    if (install) { track = { from: s.current, to: s.available || '', at: Date.now() }; saveTrack(); }
  } catch (err) { alert(err.message); }
  renderUpdate();
});

// Search like the Mac sidebar: titles, messages and answers; a result opens its chat at the turn it was found in.
function highlight(text, words) {
  const html = esc(text); if (!words) return html;
  const w = esc(words).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return html.replace(new RegExp(w, 'gi'), x => '<mark>' + x + '</mark>');
}
async function runSearch() {
  const q = $('q').value.trim();
  if (!q) return;
  try {
    const data = await api('/api/search?q=' + encodeURIComponent(q));
    if (!searching || $('q').value.trim() !== q) return;
    $('list').innerHTML = '<div class="section">' + esc(S.results) + '</div>' + (data.results.length ? data.results.map(r => {
      titles[r.id] = titles[r.id] || { title: r.title, detail: '' };
      return '<a class="row result" href="#c=' + encodeURIComponent(r.id) + '" data-id="' + esc(r.id) + '"' + (r.turn ? ' data-turn="' + esc(r.turn) + '"' : '') +
        ' data-words="' + esc(r.words || '') + '"><span class="name"><div>' + highlight(r.title, r.words) + '</div>' +
        (r.snippet ? '<div class="snippet">' + highlight(r.snippet, r.words) + '</div>' : '') + '<div class="sub">' + esc(r.date || '') + '</div></span></a>';
    }).join('') : '<div class="note">' + esc(S.noResults) + '</div>');
  } catch (e) { $('list').innerHTML = '<div class="note">' + esc(e.message || S.offline) + '</div>'; }
}
function endSearch() {
  $('q').value = ''; $('q').blur(); searching = false; lastList = '';
  $('qClear').classList.add('hidden'); $('qCancel').classList.add('hidden'); poll();
}
$('q').addEventListener('focus', () => $('qCancel').classList.remove('hidden'));
$('q').addEventListener('input', () => {
  const q = $('q').value.trim();
  $('qClear').classList.toggle('hidden', !$('q').value);
  clearTimeout(searchTimer);
  if (!q) { if (searching) { searching = false; lastList = ''; poll(); } return; }
  searching = true; searchTimer = setTimeout(runSearch, 250);
});
$('q').addEventListener('keydown', e => { if (e.key === 'Enter') { clearTimeout(searchTimer); runSearch(); $('q').blur(); } });
$('q').addEventListener('blur', () => { if (!$('q').value) $('qCancel').classList.add('hidden'); });
$('qClear').addEventListener('click', e => { e.preventDefault(); $('q').value = ''; $('q').dispatchEvent(new Event('input')); $('q').focus(); });
$('qCancel').addEventListener('click', endSearch);

// The chat: each message is drawn once and redrawn only when it changes (answers being written, a new status),
// so pictures do not reload and the page does not flicker while an answer comes in.
function renderTurn(t) {
  const el = document.createElement('div');
  el.className = 'turn' + (t.mine ? ' mine' : '') + (t.mine && t.waiting ? ' queued' : '');
  el.dataset.key = t.key || '';
  el._text = t.text || '';
  const pics = (t.images || []).map(u => '<img src="' + esc(withKey(u)) + '" loading="lazy" alt="">').join('');
  const copy = '<button class="copy">' + ICON_COPY + '<span>' + esc(S.copy) + '</span></button>';
  let h = t.day ? '<div class="day">' + esc(t.day) + '</div>' : '';
  if (t.mine) {
    if (pics) h += '<div class="pics">' + pics + '</div>';
    if (t.text) h += '<div class="bubble">' + esc(t.text).replace(/\n/g, '<br>') + '</div>';
    h += '<div class="meta">' + (t.waiting ? '<span>' + esc(S.queued) + '</span>' : '') + (t.time ? '<span>' + esc(t.time) + '</span>' : '') + (t.text ? copy : '') + '</div>';
  } else {
    h += '<div class="who"><span class="aidot"' + colorStyle(t.color) + '></span>' + esc(t.name || 'AI') + (t.model ? ' <span class="model">' + esc(t.model) + '</span>' : '') + '</div>';
    if (t.text) h += '<div class="md">' + markdown(t.text, t.places) + '</div>';
    if (pics) h += '<div class="pics">' + pics + '</div>';
    if (t.status || (t.waiting && !t.text)) h += '<div class="status' + (t.approval ? ' warn' : '') + '"><span class="spin"></span><span>' + esc(t.status || S.working) +
      (t.since ? ' <span class="elapsed" data-since="' + t.since + '"></span>' : '') + '</span></div>';
    if (t.error) h += '<div class="error">' + esc(t.error) + '</div>';
    if (t.text && !t.waiting) h += '<div class="meta">' + copy + (t.time ? '<span>' + esc(t.time) + '</span>' : '') + '</div>';
  }
  el.innerHTML = h;
  return el;
}
function tick() {
  const now = Date.now() / 1000;
  document.querySelectorAll('.elapsed').forEach(e => {
    const m = Math.floor((now - +e.dataset.since) / 60);
    e.textContent = m < 1 ? S.justStarted : S.minutes.replace('{n}', m);
  });
}
setInterval(tick, 15000);
function renderChat(data, first) {
  const box = $('chatScroll'), atEnd = first || box.scrollHeight - box.scrollTop - box.clientHeight < 90, height = box.scrollHeight;
  showMac(data.device);
  setPicks(data);
  notesFrom(data);
  $('chatTitle').textContent = data.title;
  $('chatSub').textContent = chatSub(data.project || '');
  $('box').classList.toggle('hidden', !!data.readOnly);
  $('readOnly').classList.toggle('hidden', !data.readOnly);
  $('readOnly').textContent = S.readOnly;
  $('hint').textContent = data.working ? S.answering : '';
  const list = $('turns');
  if (!data.turns.length) { list.innerHTML = '<div class="note">' + esc(S.askAnything) + '</div>'; }
  else {
    const old = new Map([...list.children].filter(e => e.dataset.key).map(e => [e.dataset.key, e]));
    [...list.children].forEach(e => { if (!e.dataset.key) e.remove(); });
    let prev = null;
    for (const t of data.turns) {
      const sig = stable(t);
      let el = old.get(t.key);
      if (!el || el._sig !== sig) { const fresh = renderTurn(t); fresh._sig = sig; if (el) { keepPictures(el, fresh); el.replaceWith(fresh); } el = fresh; }
      old.delete(t.key);
      const want = prev ? prev.nextSibling : list.firstChild;
      if (el !== want) list.insertBefore(el, want);
      prev = el;
    }
    old.forEach(e => e.remove());
  }
  const cards = stable(data.approvals);
  if ($('approvals')._sig !== cards) {
    $('approvals')._sig = cards;
    $('approvals').innerHTML = data.approvals.map(a => '<div class="approval"><b>' + esc(a.title) + '</b>' +
      (a.detail ? '<details><summary>' + esc(S.details) + '</summary><pre>' + esc(a.detail) + '</pre></details>' : '') +
      '<div class="buttons"><button class="deny" data-id="' + esc(a.id) + '" data-allow="0">' + esc(S.deny) + '</button>' +
      '<button class="allow" data-id="' + esc(a.id) + '" data-allow="1">' + esc(S.allow) + '</button></div></div>').join('');
  }
  tick();
  if (jump && showFound()) return;
  // Only when the height changed: a redraw of the same height leaves the place alone.
  if (atEnd && (first || box.scrollHeight !== height)) box.scrollTop = box.scrollHeight;
  bottomButton();
}
// A redrawn message takes over the old one's loaded pictures, so they do not load again from zero height; while any
// new picture is still loading, the message keeps its old height (released when they are in, or after a few seconds).
function keepPictures(el, fresh) {
  const height = el.offsetHeight;   // before its pictures move over
  const loaded = new Map([...el.querySelectorAll('.pics img')].filter(i => i.complete && i.naturalHeight).map(i => [i.getAttribute('src'), i]));
  const waiting = [];
  fresh.querySelectorAll('.pics img').forEach(i => {
    const o = loaded.get(i.getAttribute('src'));
    if (o) { loaded.delete(i.getAttribute('src')); i.replaceWith(o); } else waiting.push(i);
  });
  if (!waiting.length) return;
  fresh.style.minHeight = height + 'px';
  let left = waiting.length;
  const release = () => { fresh.style.minHeight = ''; holdEnd(); };
  waiting.forEach(i => { const done = () => { if (--left === 0) release(); }; i.addEventListener('load', done, { once: true }); i.addEventListener('error', done, { once: true }); });
  setTimeout(release, 4000);
}
// A search result's turn: scrolled into view with its words marked.
function showFound() {
  const el = [...$('turns').children].find(e => (e.dataset.key || '').startsWith(jump.turn));
  if (!el) return false;
  const words = jump.words; jump = null;
  if (words) {
    const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT), hits = [], low = words.toLowerCase();
    while (walker.nextNode()) if (walker.currentNode.nodeValue.toLowerCase().includes(low)) hits.push(walker.currentNode);
    for (const node of hits) {
      const span = document.createElement('span');
      span.innerHTML = highlight(node.nodeValue, words);
      node.replaceWith(span);
    }
  }
  el.classList.add('found');
  const box = $('chatScroll');
  box.scrollTop = el.offsetTop - 70;
  bottomButton();
  return true;
}
async function loadChat() {
  const id = chatId;
  try {
    const data = await api('/api/chat/' + encodeURIComponent(id) + (!opened ? '?open=1' : ''));
    if (id !== chatId) return;
    const first = !opened && !cache[id];
    opened = true;
    cache[id] = data;
    const text = stable(data);
    if (text === lastChat) return;
    lastChat = text;
    renderChat(data, first);
  } catch (e) { if (id === chatId && !cache[id]) $('chatTitle').textContent = e.message || S.offline; lastChat = ''; }
}

// A project's info (GET /api/project?id=), only to read: nothing on it changes the project. It is read again every few
// seconds while open, like the Mac's tab, and redrawn only when something changed.
let infoId = null, lastInfo = '';
async function loadInfo() {
  const id = infoId, key = current;
  try {
    const data = await api('/api/project?id=' + encodeURIComponent(id));
    if (current !== key) return;
    const text = stable(data);
    if (text === lastInfo) return;
    lastInfo = text;
    renderInfo(data);
  } catch (e) { if (current === key && !lastInfo) $('turns').innerHTML = '<div class="note">' + esc(e.message || S.offline) + '</div>'; }
}
function infoSection(title, body, count) {
  return '<div class="isec"><h3>' + esc(title) + (count ? '<small>' + esc(count) + '</small>' : '') + '</h3>' + body + '</div>';
}
function infoRow(icon, name, path, extra, right, cls) {
  return '<div class="irow' + (cls ? ' ' + cls : '') + '"><span class="ic">' + icon + '</span><div class="im"><div>' + esc(name) + (extra || '') + '</div>' +
    (path ? '<div class="p">' + esc(path) + '</div>' : '') + '</div>' + (right ? '<span class="iright">' + right + '</span>' : '') + '</div>';
}
function renderInfo(d) {
  showMac(d.device);
  projects[d.id] = d.name;
  $('chatTitle').textContent = d.name; $('chatSub').textContent = chatSub(S.projectInfo);
  const hint = t => '<p class="ihint">' + esc(t) + '</p>';
  let h = '<div class="info"><div class="isum">' + esc(S.infoSummary.replace('{chats}', d.chats).replace('{todos}', (d.todos || []).length)) + '</div>';
  if (d.repository) {
    let body = d.kind === 'documents' ? hint(S.infoDocsHint) : '';
    for (const r of d.repository) {
      if (r.worktree) body += infoRow(ICON_FOLDER, r.path.split('/').pop(), r.path, '<span class="ibadge">' + esc(S.infoWorktree) + '</span>');
      if (r.remote) body += infoRow('🌐', r.remote, '', '', '');
    }
    if (body) h += infoSection(d.kind === 'documents' ? S.infoDocs : S.infoGit, body);
  }
  if (d.rules) {
    let body = hint(d.rules.length ? S.infoRulesHint : S.infoRulesNone);
    for (const r of d.rules) body += infoRow(ICON_DOC, r.name, r.path, r.note ? '<span class="ibadge">' + esc(r.note) + '</span>' : '') + '<pre class="ipre">' + esc(r.text) + '</pre>';
    h += infoSection(S.infoRules, body);
  }
  const folders = d.folders || [];
  let fbody = hint(folders.some(f => f.kind === 'work') ? S.infoFoldersWork : S.infoFoldersHint);
  for (const f of folders) {
    const work = f.kind === 'work', off = f.kind === 'off';
    const extra = '<span class="ibadge">' + esc(f.badge) + '</span>' + (work ? '<span class="iwork">' + esc(S.infoWorkFolder) + '</span>' : '') +
      (f.exists ? '' : '<span class="imiss">' + esc(S.infoMissing) + '</span>');
    const right = esc(off ? S.infoOff : f.writable ? S.infoReadEdit : S.infoReadOnly);
    fbody += infoRow(work ? '★' : f.directory ? ICON_FOLDER : ICON_DOC, f.name, f.path, extra, right,
                     (work ? 'work' : '') + (off || !f.exists ? ' dim' : ''));
  }
  if (!folders.length) fbody += '<p class="ihint">' + esc(S.infoNone) + '</p>';
  h += infoSection(S.infoFolders, fbody);
  if ((d.links || []).length) h += infoSection(S.infoLinks, d.links.map(l => infoRow('🔗', l.title, l.url)).join(''));
  const kinds = { decision: S.memDecision, progress: S.memProgress, log: S.memLog };
  const memory = (d.memory || []).filter(k => k.total), used = memory.reduce((n, k) => n + k.total, 0);
  let mbody = hint(S.infoMemoryHint);
  for (const k of memory) {
    mbody += '<div class="ikind">' + esc(kinds[k.kind] || k.kind) + ' · ' + k.total + '</div>' + k.notes.map(n =>
      '<div class="inote">' + esc(n.text) + '<small>' + esc([n.by, n.date, n.verified ? S.memVerified : S.memGuess].filter(Boolean).join(' · ')) + '</small></div>').join('');
    if (k.total > k.notes.length) mbody += '<div class="imore">' + esc(S.memMore.replace('{n}', k.total - k.notes.length)) + '</div>';
  }
  if (!used) mbody += '<p class="ihint">' + esc(S.memNone) + '</p>';
  h += infoSection(S.infoMemory, mbody, d.archived ? S.memArchived.replace('{n}', d.archived) : '');
  if ((d.chatOnly || []).length) {
    h += infoSection(S.infoChatOnly, hint(S.infoChatOnlyHint) + d.chatOnly.map(c =>
      infoRow(ICON_FOLDER, c.name, c.path, (c.chats ? '<span class="ibadge">' + esc(c.chats) + '</span>' : '') + (c.exists ? '' : '<span class="imiss">' + esc(S.infoMissing) + '</span>'), '', c.exists ? '' : 'dim')).join(''));
  }
  if (d.lock) {
    const line = d.lock.personal ? S.lockPersonal : S.lockEnterprise.split('{name}').join(d.lock.name);
    const left = d.lock.chatsLeft + d.lock.listsLeft > 0 ? '<p class="ihint" style="color:var(--warn)">' + esc(S.lockLeft.replace('{chats}', d.lock.chatsLeft).replace('{lists}', d.lock.listsLeft)) + '</p>' : '';
    h += infoSection(S.infoLock, '<p class="ihint">🔒 ' + esc(line) + '</p>' + left);
  }
  const todos = d.todos || [];
  let tbody = todos.length ? '' : '<p class="ihint">' + esc(S.todosNone) + '</p>', yours = todos.filter(t => t.yours).length;
  todos.forEach((t, i) => {
    if (i === 0 && yours) tbody += '<div class="ikind">' + esc(S.todosYours) + ' · ' + yours + '</div>';
    if (i === yours && yours) tbody += '<div class="ikind">' + esc(S.infoTodos) + ' · ' + (todos.length - yours) + '</div>';
    tbody += '<div class="irow itodo"><div class="im"><div>' + esc(t.title) + '</div></div><span class="iright st-' + esc(t.state) + '">' + esc(t.label) + '</span></div>';
  });
  h += infoSection(S.infoTodos, tbody, todos.length ? String(todos.length) : '');
  h += '<p class="ionly">' + esc(S.infoViewOnly) + '</p></div>';
  $('turns').innerHTML = h;
}

$('approvals').addEventListener('click', async e => {
  const b = e.target.closest('button[data-id]'); if (!b) return;
  b.parentNode.querySelectorAll('button').forEach(x => x.disabled = true);
  try { await api('/api/approval/' + encodeURIComponent(b.dataset.id), { allow: b.dataset.allow === '1' }); } catch (err) { alert(err.message); }
  lastChat = ''; poll();
});
function copyText(text, button) {
  const done = () => { const s = button.querySelector('span') || button; const was = s.textContent; s.textContent = S.copied; setTimeout(() => { s.textContent = was; }, 1200); };
  if (navigator.clipboard && window.isSecureContext) navigator.clipboard.writeText(text).then(done, () => {});
  else { const t = document.createElement('textarea'); t.value = text; document.body.appendChild(t); t.select(); document.execCommand('copy'); t.remove(); done(); }
}
$('turns').addEventListener('click', e => {
  const code = e.target.closest('.ccopy');
  if (code) { copyText(code.nextElementSibling.innerText, code); return; }
  const copy = e.target.closest('.copy');
  if (copy) { copyText(copy.closest('.turn')._text, copy); return; }
  const img = e.target.closest('.pics img');
  if (img) { $('viewer').querySelector('img').src = img.src; $('viewer').classList.remove('hidden'); }
});
$('viewer').addEventListener('click', () => $('viewer').classList.add('hidden'));

function bottomButton() {
  const box = $('chatScroll');
  $('toBottom').classList.toggle('gone', box.scrollHeight - box.scrollTop - box.clientHeight < 200);
}
function barLine(scroll, bar) { $(bar).classList.toggle('under', $(scroll).scrollTop > 6); }
// Whether the user is at the end, kept from their last scroll: a picture that loads later (or a released height)
// changes the height without a scroll, and the view then stays at the end instead of being left above it.
let pinned = true;
function holdEnd() { const box = $('chatScroll'); if (pinned) box.scrollTop = box.scrollHeight; }
$('turns').addEventListener('load', e => { if (e.target.tagName === 'IMG') holdEnd(); }, true);
$('chatScroll').addEventListener('scroll', () => {
  const box = $('chatScroll'); pinned = box.scrollHeight - box.scrollTop - box.clientHeight < 90;
  bottomButton(); barLine('chatScroll', 'chatBar');
}, { passive: true });
$('listScroll').addEventListener('scroll', () => barLine('listScroll', 'listBar'), { passive: true });
$('toBottom').addEventListener('click', () => $('chatScroll').scrollTo({ top: 1e9, behavior: 'smooth' }));

function grow() { const t = $('text'); t.style.height = 'auto'; t.style.height = Math.min(t.scrollHeight, 160) + 'px'; canSend(); }
function canSend() { $('send').disabled = sending || (!$('text').value.trim() && !photos.length); }
$('text').addEventListener('input', () => { grow(); menuUpdate(); });

// The Mac message box's @ and "/" lists (RemoteChats.picks). @ (at the start or after a space, at most 24 letters back,
// on this line) lists the accounts this chat may call, narrowed as the Mac narrows (mentionMatches); a first "/" lists
// the chat's ways, like Route.slashMenu. A tap puts "@name " or "/work " in; a picked account goes with the message
// (mentions), so alike names cannot be mixed up. Unlike the Mac, a space typed after a name no account starts with
// closes the @ list, so it does not cover the chat while the message goes on. Esc, or leaving the box, closes it.
let picks = { mentions: [], routes: [] }, picked = [], menu = null, menuIndex = 0, menuShut = null;
const draftPicked = {};
function setPicks(p) {
  picks = { mentions: (p && p.mentions) || [], routes: (p && p.routes) || [] };
  if (menu || document.activeElement === $('text')) menuUpdate();
}
function mentionMatches(m, q) { return !q || m.keys.some(k => k.includes(q)) || m.names.some(n => n.startsWith(q) || q.startsWith(n)); }
function menuFind() {
  const t = $('text'), text = t.value, cursor = t.selectionStart;
  if (t.selectionEnd !== cursor) return null;
  let at = -1;
  for (let i = cursor - 1; i >= 0 && cursor - i <= 24; i--) { if (text[i] === '@') { at = i; break; } if (text[i] === '\n') break; }
  if (at >= 0 && (at === 0 || /\s/.test(text[at - 1]))) {
    const tail = text.slice(at);
    const after = picked.some(id => { const m = picks.mentions.find(x => x.id === id); return m && tail.startsWith('@' + m.label); });
    const q = text.slice(at + 1, cursor).toLowerCase();
    const list = after ? [] : picks.mentions.filter(m => mentionMatches(m, q)).slice(0, 9);
    if (list.length && (!/\s/.test(q) || list.some(m => m.keys[0].startsWith(q)))) return { kind: '@', at, end: cursor, list };
  }
  let start = 0;
  while (text[start] === ' ') start++;
  if (text[start] !== '/' || cursor <= start) return null;
  const q = text.slice(start + 1, cursor);
  if (/\s/.test(q) || (cursor < text.length && !/\s/.test(text[cursor]))) return null;
  const key = q.toLowerCase(), list = picks.routes.filter(r => r.words.some(w => w.startsWith(key)));
  return list.length ? { kind: '/', at: start, end: cursor, list } : null;
}
function menuUpdate() {
  const found = menuFind(), sig = found ? found.kind + found.at + ':' + $('text').value.slice(found.at, found.end) : null;
  if (!found || !menu || menu.sig !== sig) menuIndex = 0;
  if (sig !== menuShut) menuShut = null;   // closed by hand: shut until the word changes or goes
  menu = found && sig !== menuShut ? Object.assign(found, { sig }) : null;
  renderMenu();
}
function menuClose() { menuShut = menu ? menu.sig : null; menu = null; renderMenu(); }
function renderMenu() {
  const el = $('picker');
  el.classList.toggle('hidden', !menu);
  if (!menu) { el.innerHTML = ''; return; }
  el.innerHTML = menu.list.map((item, i) => '<button type="button" class="pick' + (i === menuIndex ? ' on' : '') + '" data-i="' + i + '" role="option">' +
    (menu.kind === '@'
      ? '<span class="aidot"' + colorStyle(item.color) + '></span><span class="plabel">' + esc(item.label) + '</span><span class="pright">' + esc(item.usage || '') + '</span>'
      : '<span class="ptitle">' + esc(item.title) + '</span><code>/' + esc(item.word) + '</code><span class="pright">' + esc(item.hint) + '</span>') +
    '</button>').join('') + '<div class="pickNote">' + esc(S.pickOnce) + '</div>';
  const on = el.querySelector('.pick.on'); if (on && on.scrollIntoView) on.scrollIntoView({ block: 'nearest' });
}
function menuPick(i) {
  const t = $('text'), text = t.value, item = menu && menu.list[i];
  if (!item) return;
  const token = menu.kind === '@' ? '@' + item.label : '/' + item.word;
  if (menu.kind === '@' && !picked.includes(item.id)) picked.push(item.id);
  // Keep a space already there after the word instead of doubling it.
  const after = menu.end < text.length && /\s/.test(text[menu.end]), put = token + (after ? '' : ' ');
  t.value = text.slice(0, menu.at) + put + text.slice(menu.end);
  const caret = menu.at + put.length + (after ? 1 : 0);
  t.focus(); t.setSelectionRange(caret, caret);
  menu = null; menuShut = null; renderMenu(); grow();
}
// Pressing a row keeps the keyboard up (the box keeps focus); leaving the box closes the list.
$('picker').addEventListener('mousedown', e => e.preventDefault());
$('picker').addEventListener('click', e => { const b = e.target.closest('.pick'); if (b) menuPick(+b.dataset.i); });
$('text').addEventListener('blur', () => setTimeout(() => { if (document.activeElement !== $('text') && menu) menuClose(); }, 200));
$('text').addEventListener('click', menuUpdate);
$('text').addEventListener('keyup', e => { if (e.key.startsWith('Arrow') && !menu) menuUpdate(); });
// A Mac's keyboard: ↑↓ move, Return or Tab picks (Shift+Return still makes a line), Esc closes the list, not the chat.
$('text').addEventListener('keydown', e => {
  if (!menu || e.isComposing || e.metaKey || e.ctrlKey || e.altKey) return;
  const n = menu.list.length;
  if (e.key === 'ArrowDown') menuIndex = Math.min(menuIndex + 1, n - 1);
  else if (e.key === 'ArrowUp') menuIndex = Math.max(menuIndex - 1, 0);
  else if ((e.key === 'Enter' || e.key === 'Tab') && !e.shiftKey) { e.preventDefault(); menuPick(Math.min(menuIndex, n - 1)); return; }
  else if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); menuClose(); return; }
  else return;
  e.preventDefault(); renderMenu();
});
$('pick').addEventListener('click', () => $('file').click());
$('file').addEventListener('change', e => { const files = [...e.target.files]; e.target.value = ''; addPhotos(files); });
// Picked, dropped anywhere on the chat screen or pasted: the same way in, as thumbnails that go only with Send. Images
// only; a read-only chat takes none, and photos still shrinking when the chat changes are dropped.
function canAttach() { return !!current && document.body.classList.contains('open') && !$('box').classList.contains('hidden') && !$('footer').classList.contains('hidden'); }
async function addPhotos(files) {
  const key = current;
  for (const f of files) {
    if (!f || !/^image\//.test(f.type)) continue;
    try { const p = await shrink(f); if (current === key) photos.push(p); } catch (_) {}
  }
  if (current === key) renderThumbs();
}
function hasFiles(e) { return !!e.dataTransfer && [...e.dataTransfer.types].includes('Files'); }
let dropDepth = 0;
function dropShown(on) {
  const zone = $('dropZone'), ok = canAttach();
  zone.classList.toggle('hidden', !on); zone.classList.toggle('no', !ok);
  $('dropTitle').textContent = ok ? S.dropPhoto : S.dropReadOnly; $('dropSub').textContent = ok ? S.dropAnywhere : '';
}
// enter/leave come for every child the drag crosses: counted, so the tint does not flicker.
$('chatView').addEventListener('dragenter', e => { if (!hasFiles(e)) return; e.preventDefault(); if (dropDepth++ === 0) dropShown(true); });
$('chatView').addEventListener('dragover', e => { if (!hasFiles(e)) return; e.preventDefault(); e.dataTransfer.dropEffect = canAttach() ? 'copy' : 'none'; });
$('chatView').addEventListener('dragleave', e => { if (!hasFiles(e)) return; if (--dropDepth <= 0) { dropDepth = 0; dropShown(false); } });
$('chatView').addEventListener('drop', e => {
  if (!hasFiles(e)) return;
  e.preventDefault(); dropDepth = 0; dropShown(false);
  if (canAttach()) addPhotos([...e.dataTransfer.files]);
});
// A file dropped anywhere else (the list) must not open it in place of the page.
for (const type of ['dragover', 'drop']) document.addEventListener(type, e => { if (hasFiles(e)) e.preventDefault(); });
// A copied photo pasted while the chat is open (the message box on the iPhone, anywhere on a Mac). Text pastes as usual.
document.addEventListener('paste', e => {
  if (!canAttach() || (e.target.closest && e.target.closest('input'))) return;
  const items = [...((e.clipboardData && e.clipboardData.items) || [])];
  const files = items.filter(i => i.kind === 'file' && /^image\//.test(i.type)).map(i => i.getAsFile()).filter(Boolean);
  if (!files.length) return;
  if (!items.some(i => i.kind === 'string' && i.type === 'text/plain')) e.preventDefault();
  addPhotos(files);
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
// A new chat is made on the Mac only when its first message goes; the page then stays on it as `#c=<id>`.
$('send').addEventListener('click', async () => {
  const key = current, text = $('text').value.trim();
  if (!key || sending || (!text && !photos.length)) return;
  sending = true; canSend();
  const images = photos.map(p => p.split(',')[1]);
  const mentions = picked.filter(id => { const m = picks.mentions.find(x => x.id === id); return m && text.includes('@' + m.label); });
  try {
    if (chatId) await api('/api/chat/' + encodeURIComponent(chatId) + '/send', { text, images, mentions });
    else {
      const made = await api('/api/chat/new', { text, images, project: newProject || undefined, mentions });
      if (current === key) {
        drafts[key] = '';
        chatId = made.id; current = made.id; opened = false;
        history.replaceState(null, '', location.pathname + location.search + '#c=' + encodeURIComponent(made.id));
      }
    }
    if (current === key || current === chatId) {
      $('text').value = ''; drafts[current] = ''; photos = []; picked = []; draftPicked[current] = []; menuClose(); renderThumbs(); grow();
      lastChat = ''; setTimeout(() => { $('chatScroll').scrollTop = 1e9; }, 60);
    }
  } catch (e) { alert(S.failed + ': ' + e.message); }
  sending = false; canSend(); poll();
});

$('back').addEventListener('click', back);
$('backText').textContent = S.list;
$('text').placeholder = S.message;
$('q').placeholder = S.search;
$('qCancel').textContent = S.cancel;
$('pick').setAttribute('aria-label', S.photo);
$('send').setAttribute('aria-label', S.send);
$('toBottom').setAttribute('aria-label', S.toBottom);
$('compose').setAttribute('aria-label', S.newChat);
$('notesTool').setAttribute('aria-label', S.notes);
$('notesTitle').textContent = S.notes; $('notesDone').textContent = S.notesDone;
$('notesText').placeholder = S.notesEmpty; $('notesHint').textContent = S.notesHint;

// Back by swiping right anywhere on the chat: the chat follows the finger, the list comes along under it, and letting
// go past a third of the screen (or with a flick) goes back; less springs back. Swiping left brings the notes in the
// same way. Not from rows that scroll sideways (code, tables, photos), and in Safari not from the edges, which are
// Safari's own back and forward swipes.
let drag = null;
const shadeMax = () => parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--shade')) || .14;
$('chatView').addEventListener('touchstart', e => {
  drag = null;
  if (!current || e.touches.length !== 1 || !$('viewer').classList.contains('hidden')) return;
  const t = e.touches[0];
  if (!standalone && t.clientX < 24) return;
  if (e.target.closest('.code, .tablewrap, #thumbs, textarea')) return;
  drag = { x: t.clientX, y: t.clientY, on: false, dx: 0, lastX: t.clientX, lastT: e.timeStamp, v: 0, notes: false,
           edge: !standalone && t.clientX > innerWidth - 24 };
}, { passive: true });
$('chatView').addEventListener('touchmove', e => {
  if (!drag) return;
  const t = e.touches[0], dx = t.clientX - drag.x, dy = t.clientY - drag.y;
  if (!drag.on) {
    if (Math.abs(dx) < 10 && Math.abs(dy) < 10) return;
    if (dx > 0 && Math.abs(dx) > Math.abs(dy) * 1.4) {
      drag.on = true; document.body.classList.add('dragging');
      if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
    } else if (dx < 0 && -dx > Math.abs(dy) * 1.4 && chatId && !drag.edge) {
      drag.on = true; drag.notes = true; document.body.classList.add('ndrag');
      if (document.activeElement && document.activeElement.blur) document.activeElement.blur();
    } else { drag = null; return; }
  }
  e.preventDefault();
  if (drag.notes) { notesFollow(drag, t, e.timeStamp, Math.max(-notesWidth(), Math.min(0, dx)) + notesWidth()); return; }
  const w = innerWidth, x = Math.max(0, dx);
  drag.v = (t.clientX - drag.lastX) / Math.max(1, e.timeStamp - drag.lastT); drag.lastX = t.clientX; drag.lastT = e.timeStamp; drag.dx = x;
  $('chatView').style.transform = 'translateX(' + x + 'px)';
  $('listView').style.transform = 'translateX(' + (-30 + 30 * x / w) + '%)';
  $('shade').style.opacity = shadeMax() * (1 - x / w);
}, { passive: false });
function endDrag() {
  const d = drag; drag = null;
  if (!d || !d.on) return;
  if (d.notes) { notesLetGo(d, d.x0 < notesWidth() * 0.67 || (d.v < -0.45 && d.x0 < notesWidth() - 30)); return; }
  document.body.classList.remove('dragging');
  $('chatView').style.transform = ''; $('listView').style.transform = ''; $('shade').style.opacity = '';
  if (d.dx > innerWidth * 0.33 || (d.v > 0.45 && d.dx > 30)) { setOpen(false, true); back(); }
}
$('chatView').addEventListener('touchend', endDrag, { passive: true });
$('chatView').addEventListener('touchcancel', endDrag, { passive: true });

// The notes: the bar's button or a swipe to the left brings them in; Done, a tap on the shade, Esc or a swipe to the
// right takes them away. They are the Mac's 메모 for this chat ("notes" with the chat): typing is saved on the Mac half
// a second after the last key (POST /api/chat/<id>/notes) and right away when they close or the chat changes. A poll
// does not replace them while they are being typed or saved.
let notesOpen = false, notesChat = null, notesDirty = false, notesBusy = 0, notesTimer = null, notesAt = 0;
const notesWidth = () => $('notes').offsetWidth || Math.min(innerWidth * 0.88, 400);
function notesShow(on) {
  notesOpen = on;
  document.body.classList.toggle('notes', on);
  $('notes').setAttribute('aria-hidden', on ? 'false' : 'true');
  if (!on) { if (document.activeElement === $('notesText')) $('notesText').blur(); notesSave(); }
}
function notesFrom(data) {
  $('notesTool').classList.toggle('hidden', !data.id);
  if (data.id !== notesChat) { notesChat = data.id; notesDirty = false; $('notesState').textContent = ''; }
  else if (notesDirty || notesBusy || document.activeElement === $('notesText') || Date.now() - notesAt < 3000) return;
  if ($('notesText').value !== (data.notes || '')) $('notesText').value = data.notes || '';
}
async function notesSave() {
  clearTimeout(notesTimer);
  if (!notesDirty || !notesChat) return;
  const id = notesChat, text = $('notesText').value;
  notesDirty = false; notesBusy++; $('notesState').textContent = S.notesSaving;
  try { await api('/api/chat/' + encodeURIComponent(id) + '/notes', { text }); if (id === notesChat) $('notesState').textContent = S.notesSaved; }
  catch (_) { if (id === notesChat) { notesDirty = true; $('notesState').textContent = S.notesFailed; } }
  notesBusy--; notesAt = Date.now();
}
// Leaving the chat (another chat, the list or a new chat): what was typed is saved and the notes go, without sliding.
function notesLeave() {
  notesSave();
  if (notesOpen) {
    document.body.classList.add('ninstant'); notesShow(false);
    requestAnimationFrame(() => requestAnimationFrame(() => document.body.classList.remove('ninstant')));
  }
  notesChat = null; $('notesText').value = ''; $('notesState').textContent = ''; $('notesTool').classList.add('hidden');
}
// While a finger drags the notes: x is how far they are from open (0 open … width closed).
function notesFollow(d, t, time, x) {
  d.v = (t.clientX - d.lastX) / Math.max(1, time - d.lastT); d.lastX = t.clientX; d.lastT = time; d.x0 = x;
  $('notes').style.transform = 'translateX(' + x + 'px)';
  $('notesShade').style.opacity = shadeMax() * (1 - x / notesWidth());
}
function notesLetGo(d, open) {
  document.body.classList.remove('ndrag');
  $('notes').style.transform = ''; $('notesShade').style.opacity = '';
  notesShow(open);
}
$('notesTool').addEventListener('click', () => notesShow(!notesOpen));
$('notesDone').addEventListener('click', () => notesShow(false));
$('notesShade').addEventListener('click', () => notesShow(false));
$('notesText').addEventListener('input', () => {
  notesDirty = true; $('notesState').textContent = '';
  clearTimeout(notesTimer); notesTimer = setTimeout(notesSave, 500);
});
// A swipe to the right on the open notes (not while typing in them) takes them away the same way.
let ndrag = null;
for (const el of ['notes', 'notesShade']) {
  $(el).addEventListener('touchstart', e => {
    ndrag = null;
    if (!notesOpen || e.touches.length !== 1 || document.activeElement === $('notesText')) return;
    const t = e.touches[0];
    ndrag = { x: t.clientX, y: t.clientY, on: false, lastX: t.clientX, lastT: e.timeStamp, v: 0, x0: 0 };
  }, { passive: true });
  $(el).addEventListener('touchmove', e => {
    if (!ndrag) return;
    const t = e.touches[0], dx = t.clientX - ndrag.x, dy = t.clientY - ndrag.y;
    if (!ndrag.on) {
      if (Math.abs(dx) < 10 && Math.abs(dy) < 10) return;
      if (dx > 0 && dx > Math.abs(dy) * 1.4) { ndrag.on = true; document.body.classList.add('ndrag'); } else { ndrag = null; return; }
    }
    e.preventDefault();
    notesFollow(ndrag, t, e.timeStamp, Math.max(0, Math.min(notesWidth(), dx)));
  }, { passive: false });
  const end = () => {
    const d = ndrag; ndrag = null;
    if (d && d.on) notesLetGo(d, !(d.x0 > notesWidth() * 0.33 || (d.v > 0.45 && d.x0 > 30)));
  };
  $(el).addEventListener('touchend', end, { passive: true });
  $(el).addEventListener('touchcancel', end, { passive: true });
}

// On a Mac (another Mac opens this page, or a desktop browser): Esc closes the photo or the notes, or goes back; a
// two-finger swipe to the right on the trackpad goes back too and one to the left opens the notes, except over rows
// that scroll sideways.
document.addEventListener('keydown', e => {
  if (e.key !== 'Escape' || e.isComposing || usagePanel.open) return;
  if (!$('viewer').classList.contains('hidden')) { $('viewer').classList.add('hidden'); return; }
  if (notesOpen) { notesShow(false); return; }
  if (current) { if (document.activeElement && document.activeElement.blur) document.activeElement.blur(); setOpen(false, true); back(); }
});
let wheel = 0, wheelTimer = null;
$('chatView').addEventListener('wheel', e => {
  if (!current || Math.abs(e.deltaX) <= Math.abs(e.deltaY) || e.target.closest('.code, .tablewrap, #thumbs, textarea')) return;
  wheel += e.deltaX;
  clearTimeout(wheelTimer);
  wheelTimer = setTimeout(() => { wheel = 0; }, 250);
  if (wheel < -140) { wheel = 0; setOpen(false, true); back(); }
  else if (wheel > 140) { wheel = 0; if (chatId && !notesOpen) notesShow(true); }
}, { passive: true });

document.addEventListener('visibilitychange', () => { if (!document.hidden) { lastList = ''; lastChat = ''; } poll(); });
window.addEventListener('hashchange', route);
route();
</script>
</body>
</html>
"""#
}
