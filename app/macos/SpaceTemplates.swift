import Foundation

// The built-in Spaces: a checklist with progress, a comparison table (with source and checked-on columns) and a
// meeting's decision log. Plain pages on the same bridge an AI's Space uses (Space.swift), so they can be changed by
// talking like any other. Their words are written in the app's language when the Space is made.
enum SpaceTemplate: String, CaseIterable {
    case checklist, compare, decisions

    var name: String {
        switch self {
        case .checklist: return L("체크리스트", "Checklist")
        case .compare: return L("비교표", "Comparison")
        case .decisions: return L("회의 결정 로그", "Decision log")
        }
    }
    var icon: String {
        switch self {
        case .checklist: return "checklist"
        case .compare: return "tablecells"
        case .decisions: return "list.bullet.rectangle"
        }
    }
    var color: String {
        switch self {
        case .checklist: return "green"
        case .compare: return "orange"
        case .decisions: return "purple"
        }
    }

    func firstState() -> Data {
        let state: [String: Any]
        switch self {
        case .checklist: state = ["title": name, "goal": "", "items": [[String: Any]]()]
        case .compare: state = ["title": name, "columns": [L("항목", "Item"), L("가격", "Price"), L("메모", "Notes")], "rows": [[String: Any]]()]
        case .decisions: state = ["title": name, "goal": "", "decisions": [[String: Any]](), "next": [[String: Any]]()]
        }
        return (try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    // What every template shares: colors that follow light and dark mode, and small helpers on the bridge.
    private static var base: String {
        """
        <style>
        :root{--bg:#fff;--fg:#1d1d1f;--mut:#86868b;--line:rgba(0,0,0,.1);--card:rgba(0,0,0,.035);--acc:#0a84ff}
        @media(prefers-color-scheme:dark){:root{--bg:#1e1e1e;--fg:#f2f2f2;--mut:#98989d;--line:rgba(255,255,255,.12);--card:rgba(255,255,255,.055)}}
        body{margin:0;padding:22px 28px 40px;font:14px/1.45 system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--fg)}
        h1{font-size:22px;margin:0 0 2px;outline:none}.goal{color:var(--mut);margin:0 0 16px;outline:none;min-height:1.4em}
        .goal:empty:before{content:attr(data-hint);color:var(--mut);opacity:.6}
        input[type=text]{font:inherit;color:inherit;background:var(--card);border:1px solid var(--line);border-radius:8px;padding:6px 9px;width:100%;box-sizing:border-box}
        button{font:inherit;color:inherit;background:var(--card);border:1px solid var(--line);border-radius:7px;padding:3px 9px;cursor:pointer}
        button.on{background:var(--acc);color:#fff;border-color:transparent}.x{border:none;background:none;color:var(--mut);padding:0 6px}
        .row{display:flex;gap:8px;align-items:center;padding:6px 0;border-bottom:1px solid var(--line)}.row .t{flex:1;outline:none}
        .mut{color:var(--mut);font-size:12px}h2{font-size:13px;color:var(--mut);margin:20px 0 6px;font-weight:600}
        .card{background:var(--card);border-radius:10px;padding:10px 12px;margin:6px 0}
        </style>
        <script>
        const $=(t,p={},...c)=>{const e=document.createElement(t);for(const k in p){const v=p[k];if(k.startsWith('on'))e.addEventListener(k.slice(2),v);else if(k==='class')e.className=v;else if(k==='text')e.textContent=v;else if(k in e)e[k]=v;else e.setAttribute(k,v)}for(const x of c.flat())if(x!=null&&x!==false)e.append(x instanceof Node?x:String(x));return e};
        const S=space.state,uid=()=>Math.random().toString(36).slice(2,9),today=()=>new Date().toISOString().slice(0,10);
        if(space.theme&&space.theme.accent)document.documentElement.style.setProperty('--acc',space.theme.accent);
        const editable=(tag,cls,value,done,hint)=>{const e=$(tag,{class:cls,contentEditable:'true',text:value||''});if(hint)e.dataset.hint=hint;e.addEventListener('keydown',ev=>{if(ev.key==='Enter'&&!ev.shiftKey){ev.preventDefault();e.blur()}});e.addEventListener('blur',()=>{const t=e.textContent.trim();if(t!==(value||''))done(t)});return e};
        const head=root=>{root.append(editable('h1','',S.get('title'),t=>S.set('title',t)),editable('p','goal',S.get('goal'),t=>S.set('goal',t),'\(L("목표 (눌러서 적기)", "Goal (click to write)"))'))};
        </script>
        """
    }

    var html: String {
        switch self {
        case .checklist:
            return "<!doctype html><html><head>" + Self.base + """
                <style>.bar{height:8px;background:var(--card);border-radius:4px;overflow:hidden;margin:4px 0 14px}.bar i{display:block;height:100%;background:var(--acc);transition:width .2s}
                .done .t{text-decoration:line-through;color:var(--mut)}.lane{font-size:11px;color:var(--mut);border:1px solid var(--line);border-radius:5px;padding:0 5px}</style>
                </head><body><div id=app></div><script>
                const app=document.getElementById('app');
                function draw(){app.textContent='';head(app);const items=S.get('items')||[];const done=items.filter(i=>i.done).length;
                const pct=items.length?Math.round(done*100/items.length):0;
                app.append($('div',{class:'mut',text:`\(L("진행률", "Progress")) ${done}/${items.length} · ${pct}%`}),$('div',{class:'bar'},$('i',{style:`width:${pct}%`})));
                const put=next=>S.set('items',next).then(draw);
                for(const it of items){app.append($('div',{class:'row'+(it.done?' done':'')},
                  $('input',{type:'checkbox',checked:!!it.done,onchange:e=>put(items.map(x=>x.id===it.id?{...x,done:e.target.checked}:x))}),
                  editable('span','t',it.text,t=>put(items.map(x=>x.id===it.id?{...x,text:t}:x))),
                  it.lane?$('span',{class:'lane',text:it.lane}):null,
                  it.chat?$('button',{class:'x',text:'\(L("채팅", "Chat"))',onclick:()=>space.open({chat:it.chat})}):null,
                  it.todo?$('button',{class:'x',text:'TODO',onclick:()=>space.open({todo:it.todo})}):null,
                  $('button',{class:'x',text:'×',title:'\(L("삭제", "Delete"))',onclick:()=>put(items.filter(x=>x.id!==it.id))})))}
                const add=$('input',{type:'text',placeholder:'\(L("항목 추가 후 Return", "Add an item, then Return"))'});
                add.addEventListener('keydown',e=>{if(e.key==='Enter'&&add.value.trim()){put([...items,{id:uid(),text:add.value.trim(),done:false}])}});
                app.append($('div',{style:'margin-top:12px'},add));}
                draw();
                </script></body></html>
                """
        case .compare:
            return "<!doctype html><html><head>" + Self.base + """
                <style>table{border-collapse:collapse;width:100%}th,td{border-bottom:1px solid var(--line);padding:6px 8px;text-align:left;vertical-align:top}
                th{font-size:12px;color:var(--mut);font-weight:600}td div{outline:none;min-height:1.3em}.tools{display:flex;gap:8px;margin-top:12px}</style>
                </head><body><div id=app></div><script>
                const app=document.getElementById('app');
                function draw(){app.textContent='';head(app);const cols=S.get('columns')||[];const rows=S.get('rows')||[];
                const put=next=>S.set('rows',next).then(draw);
                const edit=(r,f)=>put(rows.map(x=>x.id===r.id?f({...x}):x));
                const t=$('table');t.append($('tr',{},cols.map((c,i)=>$('th',{},editable('div','',c,v=>{const n=[...cols];n[i]=v;S.set('columns',n).then(draw)}))),
                  $('th',{text:'\(L("출처", "Source"))'}),$('th',{text:'\(L("확인 날짜", "Checked on"))'}),$('th')));
                for(const r of rows){t.append($('tr',{},cols.map((c,i)=>$('td',{},editable('div','',(r.cells||[])[i],v=>edit(r,x=>{const c2=[...(x.cells||[])];while(c2.length<cols.length)c2.push('');c2[i]=v;x.cells=c2;return x})))),
                  $('td',{},editable('div','',r.source,v=>edit(r,x=>{x.source=v;return x}))),
                  $('td',{},$('span',{text:r.checked||'—'}),' ',$('button',{class:'x',text:'\(L("오늘", "Today"))',onclick:()=>edit(r,x=>{x.checked=today();return x})})),
                  $('td',{},$('button',{class:'x',text:'×',onclick:()=>put(rows.filter(x=>x.id!==r.id))}))))}
                app.append(t,$('div',{class:'tools'},$('button',{text:'\(L("+ 줄", "+ Row"))',onclick:()=>put([...rows,{id:uid(),cells:cols.map(()=>''),source:'',checked:''}])}),
                  $('button',{text:'\(L("+ 열", "+ Column"))',onclick:()=>S.set('columns',[...cols,'\(L("새 열", "New column"))']).then(draw)}),
                  cols.length>1?$('button',{text:'\(L("− 마지막 열", "− Last column"))',onclick:()=>S.set('columns',cols.slice(0,-1)).then(draw)}):null));}
                draw();
                </script></body></html>
                """
        case .decisions:
            return "<!doctype html><html><head>" + Self.base + """
                <style>.who{font-size:12px;color:var(--mut);margin-top:3px}.btns{display:flex;gap:6px;margin-top:6px;flex-wrap:wrap}.ok{color:#30a46c}
                .card .t{outline:none}.done .t{text-decoration:line-through;color:var(--mut)}</style>
                </head><body><div id=app></div><script>
                const app=document.getElementById('app');
                function draw(){app.textContent='';head(app);const list=S.get('decisions')||[];const next=S.get('next')||[];
                const put=n=>S.set('decisions',n).then(draw),putNext=n=>S.set('next',n).then(draw);
                const edit=(d,f)=>put(list.map(x=>x.id===d.id?f({...x}):x));
                const card=d=>$('div',{class:'card'},editable('div','t',d.text,v=>edit(d,x=>{x.text=v;return x})),
                  (d.pro&&d.pro.length)||(d.con&&d.con.length)?$('div',{class:'who',text:[d.pro&&d.pro.length?'\(L("찬성", "For")): '+d.pro.join(', '):'',d.con&&d.con.length?'\(L("반대", "Against")): '+d.con.join(', '):''].filter(Boolean).join(' · ')}):null,
                  d.source?$('div',{class:'who',text:d.source}):null,
                  $('div',{class:'btns'},$('button',{text:d.open?'\(L("미해결 → 결정", "Open → decided"))':'\(L("결정 → 미해결", "Decided → open"))',onclick:()=>edit(d,x=>{x.open=!x.open;return x})}),
                    $('button',{class:d.confirmed?'on':'',text:d.confirmed?'\(L("내가 확정함", "Confirmed by me"))':'\(L("AI 제안 · 확정하기", "AI proposal · confirm"))',onclick:()=>edit(d,x=>{x.confirmed=!x.confirmed;return x})}),
                    d.chat?$('button',{text:'\(L("회의 보기", "Show meeting"))',onclick:()=>space.open({chat:d.chat})}):null,
                    d.todo?$('button',{text:'TODO',onclick:()=>space.open({todo:d.todo})}):null,
                    $('button',{class:'x',text:'×',onclick:()=>put(list.filter(x=>x.id!==d.id))})));
                app.append($('h2',{text:'\(L("결정", "Decided"))'}),...list.filter(d=>!d.open).map(card),$('h2',{text:'\(L("미해결", "Open"))'}),...list.filter(d=>d.open).map(card));
                const add=$('input',{type:'text',placeholder:'\(L("결정 추가 후 Return (내가 쓴 건 확정)", "Add a decision, then Return (yours are confirmed)"))'});
                add.addEventListener('keydown',e=>{if(e.key==='Enter'&&add.value.trim())put([...list,{id:uid(),text:add.value.trim(),open:false,pro:[],con:[],source:'',confirmed:true}])});
                app.append($('div',{style:'margin-top:10px'},add),$('h2',{text:'\(L("다음 행동", "Next steps"))'}));
                for(const n of next)app.append($('div',{class:'row'+(n.done?' done':'')},$('input',{type:'checkbox',checked:!!n.done,onchange:e=>putNext(next.map(x=>x.id===n.id?{...x,done:e.target.checked}:x))}),
                  editable('span','t',n.text,v=>putNext(next.map(x=>x.id===n.id?{...x,text:v}:x))),$('button',{class:'x',text:'×',onclick:()=>putNext(next.filter(x=>x.id!==n.id))})));
                const addNext=$('input',{type:'text',placeholder:'\(L("다음 행동 추가 후 Return", "Add a next step, then Return"))'});
                addNext.addEventListener('keydown',e=>{if(e.key==='Enter'&&addNext.value.trim())putNext([...next,{id:uid(),text:addNext.value.trim(),done:false}])});
                app.append($('div',{style:'margin-top:10px'},addNext));}
                draw();
                </script></body></html>
                """
        }
    }
}
