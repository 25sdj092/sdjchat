(function () {
'use strict';

var CFG = window.APP_CONFIG || {};
var MAXLEN = 2000;               // 메시지 최대 길이
var PAGE = 30;                   // 한 번에 불러오는 메시지 수
var DOM_CAP = 300;               // 화면에 유지하는 최대 말풍선 수
var MAX_IMG = 10 * 1024 * 1024;  // 사진 최대 크기
var BUCKET = 'chat-images';
var EXT = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' };
var COLS = 'id,seq,conversation_id,sender_id,content,message_type,storage_path,mime_type,file_size,created_at';
var UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

var $ = function (id) { return document.getElementById(id); };
var noop = function () {};

/* ---------- LocalStorage (내 프로필 캐시만) ---------- */
function lget(k, d) { try { var v = localStorage.getItem(k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } }
function lset(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }

/* ---------- 상태 ---------- */
var sb = null, me = null, chan = null, presenceChan = null, netOk = false, loggingOut = false;
var onlineUsers = new Set();
var convs = new Map();           // 내가 참여 중인 대화방
var openRooms = [];             // 전체 공개 오픈채팅 목록
var reqs = [];                   // 받은 친구 요청 [{id,name,code}]
var active = null;               // 열려 있는 대화방 id
var shown = new Map();           // 화면에 있는 메시지 id -> entry
var outbox = new Map();          // 전송 중/실패 메시지 (메모리)
var urls = new Map();            // storage 경로 -> {u, exp} (Signed URL 캐시)
var loadTok = 0, firstLoading = false, queued = [], hasMore = false, loadingOld = false, stick = true;
var pendingOpen = null, panelOpen = false;
var msEl, inp;

function el(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;
  return e;
}
function uuid() {
  if (window.crypto && crypto.randomUUID) return crypto.randomUUID();
  var b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 15) | 64; b[8] = (b[8] & 63) | 128;
  var h = Array.prototype.map.call(b, function (x) { return ('0' + x.toString(16)).slice(-2); }).join('');
  return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
}
function fmt(ts) {
  var d = new Date(ts), n = new Date();
  var hm = ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
  return d.toDateString() === n.toDateString() ? hm : (d.getMonth() + 1) + '/' + d.getDate() + ' ' + hm;
}
function isMobile() { return window.matchMedia('(max-width:700px)').matches; }
function viewing(id) { return active === id && !document.hidden && document.hasFocus(); }
function msgOf(e) { return String((e && e.message) || e || ''); }

/* ---------- 대화방 헬퍼 ---------- */
function otherOf(c) {
  var o = null;
  c.members.forEach(function (m) { if (!o && m.id !== me.id) o = m; });
  return o;
}
function activeMembers(c) {
  var a = [];
  c.members.forEach(function (m) { if (!m.left) a.push(m); });
  return a;
}
function convName(c) {
  if (c.type === 'open' || c.type === 'group') return c.name;
  var o = otherOf(c);
  return o ? o.name : '알 수 없음';
}
function nameOf(c, uid) {
  var m = c && c.members.get(uid);
  return m ? m.name : '알 수 없음';
}
function ts(x) { return x ? new Date(x).getTime() || 0 : 0; }

/* ---------- 화면: 목록 ---------- */
var fre = {};                    // 대화방 id -> {li, bd}
var rendT = null;
function scheduleRender() { if (!rendT) rendT = setTimeout(function () { rendT = null; renderLists(); }, 60); }
function sortedConvs(type) {
  return Array.from(convs.values()).filter(function (c) { return c.type === type; }).sort(function (a, b) {
    return (ts(b.lastAt) - ts(a.lastAt)) || convName(a).localeCompare(convName(b));
  });
}
function convItem(c) {
  var li = el('li', 'fr' + (active === c.id ? ' sel' : ''));
  var info = el('div', 'info');
  var o = otherOf(c);
  info.appendChild(el('div', 'nm', convName(c)));
  var online = !!(o && onlineUsers.has(o.id));
  info.appendChild(el('div', 'presence-status ' + (online ? 'online' : 'offline'), online ? '온라인' : '오프라인'));
  info.appendChild(el('div', 'c', o ? o.code : ''));
  var bd = el('span', 'bd');
  li.appendChild(info);
  li.appendChild(bd);
  var x = el('button', 'x', '×'); x.type = 'button'; x.title = '친구 삭제';
  x.addEventListener('click', function (e) { e.stopPropagation(); removeFriend(c); });
  li.appendChild(x);
  li.addEventListener('click', function () { openChat(c.id); });
  fre[c.id] = { li: li, bd: bd };
  setBadge(c);
  return li;
}
function codeRoomItem(c) {
  var li = el('li', 'fr' + (active === c.id ? ' sel' : ''));
  var info = el('div', 'info');
  info.appendChild(el('div', 'nm', c.name));
  info.appendChild(el('div', 'c', '코드 ' + c.room_code + ' · ' + activeMembers(c).length + '명' + (c.owner === me.id ? ' · 방장' : '')));
  var bd = el('span', 'bd');
  li.appendChild(info);
  li.appendChild(bd);
  li.addEventListener('click', function () { openChat(c.id); });
  fre[c.id] = { li: li, bd: bd };
  setBadge(c);
  return li;
}
function openRoomItem(room, index) {
  var c = convs.get(room.id), joined = !!c;
  var hot = index === 0 && Number(room.recent_messages) > 0;
  var li = el('li', 'fr open-room' + (active === room.id ? ' sel' : '') + (hot ? ' hot' : ''));
  var info = el('div', 'info');
  info.appendChild(el('div', 'nm', room.name));
  var detail = Number(room.member_count || 0) + '명 · 최근 24시간 메시지 ' + Number(room.recent_messages || 0) + '개';
  info.appendChild(el('div', 'c', detail));
  var bd = el('span', 'bd');
  bd.hidden = !joined || !c.unread;
  if (joined && c.unread) bd.textContent = c.unread > 99 ? '99+' : c.unread;
  li.appendChild(info);
  li.appendChild(bd);
  li.appendChild(el('span', 'join-state', joined ? '참여 중' : '참가'));
  li.addEventListener('click', function () {
    if (joined) openChat(room.id);
    else joinOpenRoom(room.id);
  });
  fre[room.id] = { li: li, bd: bd };
  return li;
}
function renderOpenRooms() {
  var frag = document.createDocumentFragment();
  openRooms.forEach(function (room, index) { frag.appendChild(openRoomItem(room, index)); });
  $('rl').replaceChildren(frag);
  $('rh').hidden = !openRooms.length;
}
function renderLists() {
  fre = {};
  var f = document.createDocumentFragment(), g = document.createDocumentFragment();
  sortedConvs('direct').forEach(function (c) { f.appendChild(convItem(c)); });
  sortedConvs('group').forEach(function (c) { g.appendChild(codeRoomItem(c)); });
  $('fl').replaceChildren(f);
  $('cl').replaceChildren(g);
  $('ch').hidden = !g.childNodes.length;
  renderOpenRooms();
  updateTitle();
}
function setBadge(c) {
  var e = fre[c.id];
  if (e) { e.bd.textContent = c.unread > 99 ? '99+' : c.unread; e.bd.hidden = !c.unread; }
  updateTitle();
}
function updateTitle() {
  var n = 0;
  convs.forEach(function (c) { n += c.unread || 0; });
  document.title = (n ? '(' + (n > 99 ? '99+' : n) + ') ' : '') + '서고챗';
}
function renderReqs() {
  $('rq').hidden = !reqs.length;
  var frag = document.createDocumentFragment();
  reqs.forEach(function (r) {
    var li = document.createElement('li');
    var ok = el('button', 'pri', '수락'), no = el('button', null, '거절');
    ok.type = 'button'; no.type = 'button';
    ok.addEventListener('click', function () { answerReq(r, true); });
    no.addEventListener('click', function () { answerReq(r, false); });
    li.appendChild(el('div', 'nm', r.name + ' (' + r.code + ')'));
    li.appendChild(ok); li.appendChild(no);
    frag.appendChild(li);
  });
  $('rql').replaceChildren(frag);
}
function setNet(ok, text) {
  netOk = ok;
  $('nd').className = 'dot' + (ok ? ' on' : '');
  $('nt').textContent = text || (ok ? '서버 연결됨' : '서버 연결 끊김');
}

/* ---------- 데이터 로딩 ---------- */
var loadP = null, again = false, rlT = null, failN = 0, pendingRead = null;
function scheduleReload() { clearTimeout(rlT); rlT = setTimeout(reload, 300); }
function reload() {
  if (loadP) { again = true; return loadP; }
  loadP = (async function () {
    do {
      again = false;
      try { await loadAll(); failN = 0; }
      catch (e) {
        failN++;
        setNet(false, '데이터를 불러오지 못했습니다');
        clearTimeout(rlT); rlT = setTimeout(reload, Math.min(30000, 2000 * failN));
        break;
      }
    } while (again);
    loadP = null;
  })();
  return loadP;
}
async function loadAll() {
  var r1 = await sb.from('conversation_members')
    .select('conversation_id,conversations(id,type,name,owner_id,room_code)')
    .eq('user_id', me.id).is('left_at', null);
  if (r1.error) throw r1.error;
  var mine = r1.data.filter(function (x) { return x.conversations; });
  var ids = mine.map(function (x) { return x.conversation_id; });
  var res = await Promise.all([
    ids.length
      ? sb.from('conversation_members').select('conversation_id,user_id,last_read_seq,left_at,profiles(username,user_code)').in('conversation_id', ids)
      : Promise.resolve({ data: [] }),
    sb.from('friendships').select('id,requester:profiles!friendships_requester_id_fkey(username,user_code)')
      .eq('receiver_id', me.id).eq('status', 'pending').order('created_at'),
    sb.rpc('conversation_summary'),
    sb.rpc('list_open_rooms')
  ]);
  for (var i = 0; i < res.length; i++) if (res[i].error) throw res[i].error;

  var next = new Map();
  mine.forEach(function (row) {
    var c = row.conversations;
    next.set(c.id, { id: c.id, type: c.type, name: c.name, owner: c.owner_id, room_code: c.room_code, members: new Map(), unread: 0, lastAt: null });
  });
  res[0].data.forEach(function (m) {
    var c = next.get(m.conversation_id);
    if (!c) return;
    var p = m.profiles || {};
    c.members.set(m.user_id, { id: m.user_id, name: p.username || '알 수 없음', code: p.user_code || '', seq: Number(m.last_read_seq) || 0, left: !!m.left_at });
  });
  (res[2].data || []).forEach(function (s) {
    var c = next.get(s.conversation_id);
    if (c) { c.unread = Number(s.unread) || 0; c.lastAt = s.last_message_at; }
  });
  convs = next;
  openRooms = res[3].data || [];
  reqs = (res[1].data || []).map(function (r) {
    return { id: r.id, name: r.requester ? r.requester.username : '알 수 없음', code: r.requester ? r.requester.user_code : '' };
  });

  setNet(true);
  if (active && !convs.has(active)) showList();
  renderLists(); renderReqs();
  if (active) { updateHeader(); refreshNames(); refreshNums(); if (panelOpen) renderPanel(); scheduleRead(); }
  if (pendingOpen && convs.has(pendingOpen)) { var id = pendingOpen; pendingOpen = null; if (active !== id) openChat(id); }
}

/* ---------- 화면: 채팅 ---------- */
function hint(t) {
  var h = $('hint'); h.textContent = t || '';
  clearTimeout(hint._t);
  if (t) hint._t = setTimeout(function () { h.textContent = ''; }, 3500);
}
function updateHeader() {
  var c = convs.get(active);
  if (!c) return;
  $('cn').textContent = convName(c);
  if (c.type === 'open' || c.type === 'group') {
    var o = c.members.get(c.owner);
    var kind = c.type === 'open' ? '오픈채팅' : '6자리 코드방';
    $('cs').textContent = kind + ' · 참여 ' + activeMembers(c).length + '명' +
      (c.type === 'group' ? ' · 코드 ' + c.room_code : '') + (o ? ' · 방장 ' + o.name : '');
  } else {
    var p = otherOf(c);
    $('cs').textContent = p ? '개인 DM · 코드 ' + p.code : '개인 DM';
  }
}
function renderPanel() {
  var c = convs.get(active), box = $('pl');
  if (!c || c.type === 'direct') { box.hidden = true; return; }
  var members = activeMembers(c);
  var head = el('div', 'pc', '참여자 ' + members.length + '명');
  if (c.type === 'group' && c.room_code) {
    head.appendChild(document.createTextNode(' · 방 코드 '));
    head.appendChild(el('b', null, c.room_code));
    var copy = el('button', null, '복사'); copy.type = 'button';
    copy.addEventListener('click', function () { copyText(c.room_code, copy); });
    head.appendChild(copy);
  }
  var ul = document.createElement('ul');
  members.forEach(function (m) {
    var li = el('li', null, m.name + (m.id === me.id ? ' (나)' : ''));
    if (m.id === c.owner) li.appendChild(el('span', 'own', '방장'));
    ul.appendChild(li);
  });
  box.replaceChildren(head, ul);
}
function showList() {
  active = null; loadTok++; firstLoading = false; queued = [];
  $('app').dataset.v = 'list';
  $('chat').hidden = true;
  $('empty').hidden = false;
  document.querySelectorAll('.fr.sel').forEach(function (e) { e.classList.remove('sel'); });
}
function openChat(id) {
  var c = convs.get(id);
  if (!c) return;
  var prev = active;
  active = id; panelOpen = false;
  if (prev && fre[prev]) fre[prev].li.classList.remove('sel');
  if (fre[id]) fre[id].li.classList.add('sel');
  if (isMobile() && !(history.state && history.state.chat)) history.pushState({ chat: 1 }, '');
  $('app').dataset.v = 'chat';
  $('empty').hidden = true;
  $('chat').hidden = false;
  $('pl').hidden = true;
  var isRoom = c.type === 'open' || c.type === 'group';
  $('pb').hidden = !isRoom;
  $('lv').hidden = !isRoom;
  $('rnm').hidden = !isRoom || c.owner !== me.id;
  $('lv').textContent = c.owner === me.id ? '방 삭제' : '나가기';
  updateHeader();
  hint('');
  shown = new Map(); queued = [];
  msEl.replaceChildren();
  hasMore = false; stick = true; firstLoading = true;
  loadLatest(id, ++loadTok);
  if (!isMobile()) inp.focus();
}
async function loadLatest(id, tok) {
  var r = await sb.from('messages').select(COLS).eq('conversation_id', id).order('seq', { ascending: false }).limit(PAGE);
  if (tok !== loadTok) return;
  if (r.error) {
    hint('메시지를 불러오지 못했습니다. 다시 시도합니다.');
    setTimeout(function () { if (tok === loadTok) loadLatest(id, tok); }, 3000);
    return;
  }
  var full = r.data.length === PAGE;
  var arr = r.data.reverse();
  await signMany(arr);
  if (tok !== loadTok) return;
  var frag = document.createDocumentFragment();
  arr.forEach(function (m) { if (!shown.has(m.id)) frag.appendChild(addEntry(m)); });
  msEl.replaceChildren(frag);
  hasMore = full;
  firstLoading = false;
  var q = queued; queued = [];
  q.forEach(appendMsg);
  outbox.forEach(function (m) { if (m.conversation_id === id) appendMsg(m); });   // 아직 못 보낸 메시지도 다시 표시
  msEl.scrollTop = msEl.scrollHeight; stick = true;
  scheduleRead();
  if (hasMore && msEl.scrollHeight <= msEl.clientHeight) loadOlder();
}
async function loadOlder() {
  if (loadingOld || !hasMore || firstLoading || !active) return;
  var first = msEl.firstElementChild, fs = first && Number(first.dataset.seq);
  if (!fs) return;
  loadingOld = true;
  var id = active, tok = loadTok;
  var r = await sb.from('messages').select(COLS).eq('conversation_id', id).lt('seq', fs).order('seq', { ascending: false }).limit(PAGE);
  if (!r.error) await signMany(r.data);
  loadingOld = false;
  if (tok !== loadTok) return;
  if (r.error) { hint('이전 메시지를 불러오지 못했습니다.'); return; }
  hasMore = r.data.length === PAGE;
  var arr = r.data.reverse();
  var h = msEl.scrollHeight, t = msEl.scrollTop;
  var frag = document.createDocumentFragment();
  arr.forEach(function (m) { if (!shown.has(m.id)) frag.appendChild(addEntry(m)); });
  msEl.insertBefore(frag, msEl.firstChild);
  msEl.scrollTop = t + (msEl.scrollHeight - h);        // 보던 위치 유지
  if (hasMore && msEl.scrollHeight <= msEl.clientHeight) loadOlder();
}

/* 말풍선 */
function unreadOf(m) {            // 이 메시지를 아직 읽지 않은 참여자 수 (발신자·나간 사람 제외)
  if (m.seq == null) return 0;
  var c = convs.get(m.conversation_id), n = 0;
  if (!c) return 0;
  c.members.forEach(function (mm) { if (!mm.left && mm.id !== m.sender_id && mm.seq < m.seq) n++; });
  return n;
}
function addEntry(m) {
  var c = convs.get(m.conversation_id);
  var mine = m.sender_id === me.id;
  var d = el('div', 'm' + (mine ? ' me' : ''));
  d.dataset.id = m.id;
  var col = el('div', 'col'), sn = null, pg = null;
  if (!mine && c && (c.type === 'open' || c.type === 'group')) { sn = el('div', 'sn', nameOf(c, m.sender_id)); col.appendChild(sn); }
  var b = el('div', 'b');
  if (m.message_type === 'image') {
    b.className = 'b img';
    var im = new Image();
    im.alt = '사진'; im.loading = 'lazy'; im.decoding = 'async'; im.draggable = false;
    im.addEventListener('load', function () { if (stick) msEl.scrollTop = msEl.scrollHeight; });
    im.addEventListener('click', function () { openLb(im.currentSrc || im.src); });
    im.addEventListener('error', function () {
      if (im._retried || m._blob) return;
      im._retried = true; urls.delete(m.storage_path); setSrc(im, m);     // 만료된 Signed URL 이면 새로 발급
    });
    setSrc(im, m);
    b.appendChild(im);
    if (m._st === 'sending') { pg = el('div', 'pg'); b.appendChild(pg); }
  } else b.textContent = m.content;
  col.appendChild(b);
  var meta = el('div', 'meta'), u = el('span', 'u'), rt = el('button', 'rt', '재시도'), t = el('span', 't');
  rt.type = 'button'; rt.hidden = true;
  meta.appendChild(u); meta.appendChild(rt); meta.appendChild(t);
  d.appendChild(col); d.appendChild(meta);
  var en = { m: m, el: d, sn: sn, u: u, rt: rt, t: t, pg: pg };
  rt.addEventListener('click', function () { retry(en.m); });
  shown.set(m.id, en);
  paint(en);
  return d;
}
function paint(en) {
  var m = en.m, st = m._st || 'sent';
  en.t.textContent = fmt(m.created_at);
  en.rt.hidden = st !== 'failed';
  if (m.seq != null) en.el.dataset.seq = m.seq;
  if (st === 'sending') { en.u.className = 'u s'; en.u.textContent = '전송 중…'; }
  else if (st === 'failed') { en.u.className = 'u f'; en.u.textContent = '전송 실패'; }
  else { en.u.className = 'u'; paintNum(en); }
  if (en.pg) {
    if (st === 'sending' && m._p != null && m._p < 100) en.pg.textContent = '업로드 ' + m._p + '%';
    else { en.pg.remove(); en.pg = null; }
  }
}
function paintNum(en) {           // 읽음 숫자: 안 읽은 사람이 없으면 비운다
  var n = unreadOf(en.m), s = n > 0 ? String(n) : '';
  if (en.u.textContent !== s) en.u.textContent = s;
}
function refreshNums() {
  shown.forEach(function (en) { if (!en.m._st || en.m._st === 'sent') paintNum(en); });
}
function refreshNames() {
  shown.forEach(function (en) {
    if (en.sn) en.sn.textContent = nameOf(convs.get(en.m.conversation_id), en.m.sender_id);
  });
}
function appendMsg(m) {
  if (m.conversation_id !== active) return;
  if (firstLoading) { queued.push(m); return; }
  if (shown.has(m.id)) return;
  var go = stick || m.sender_id === me.id;
  msEl.appendChild(addEntry(m));
  while (msEl.childElementCount > DOM_CAP) {
    var f = msEl.firstElementChild;
    shown.delete(f.dataset.id); msEl.removeChild(f); hasMore = true;
  }
  if (go) { msEl.scrollTop = msEl.scrollHeight; stick = true; }
}

/* ---------- Signed URL / 사진 보기 ---------- */
function urlOf(p) { var e = urls.get(p); return e && e.exp > Date.now() + 60000 ? e.u : null; }
async function signMany(arr) {
  var need = [];
  arr.forEach(function (m) {
    if (m.message_type === 'image' && m.storage_path && !m._blob && !urlOf(m.storage_path) && need.indexOf(m.storage_path) < 0) need.push(m.storage_path);
  });
  if (!need.length) return;
  var r = await sb.storage.from(BUCKET).createSignedUrls(need, 3600);
  if (r.error || !r.data) return;
  r.data.forEach(function (x) { if (x.signedUrl && x.path) urls.set(x.path, { u: x.signedUrl, exp: Date.now() + 3600000 }); });
}
function setSrc(im, m) {
  if (m._blob) { im.src = m._blob; return; }
  var u = urlOf(m.storage_path);
  if (u) { im.src = u; return; }
  signMany([m]).then(function () {
    var u2 = urlOf(m.storage_path);
    if (u2) im.src = u2; else im.alt = '사진을 불러오지 못했습니다';
  });
}
function openLb(src) {
  if (!src) return;
  $('lb').firstElementChild.src = src;
  $('lb').hidden = false;
}
function closeLb() { $('lb').hidden = true; $('lb').firstElementChild.removeAttribute('src'); }

/* ---------- 메시지 전송 ---------- */
function fitInput() {
  inp.style.height = 'auto';
  inp.style.height = Math.min(inp.scrollHeight, 120) + 'px';
}
function newMsg(type) {
  return { id: uuid(), seq: null, conversation_id: active, sender_id: me.id, content: '', message_type: type,
           storage_path: null, mime_type: null, file_size: null, created_at: new Date().toISOString(), _st: 'sending' };
}
function sendText() {
  if (!active) return;
  var text = inp.value.trim();
  if (!text) return;
  var m = newMsg('text');
  m.content = text.slice(0, MAXLEN);
  inp.value = ''; fitInput(); hint('');
  appendMsg(m);
  post(m);
}
function retry(m) { if (m.message_type === 'image' && !m._up) upload(m); else post(m); }
async function post(m) {         // 서버(DB) 저장이 끝난 뒤에만 '전송 완료'로 표시한다
  outbox.set(m.id, m);
  m._st = 'sending';
  var en = shown.get(m.id); if (en) paint(en);
  var row = { id: m.id, conversation_id: m.conversation_id, content: m.content, message_type: m.message_type };
  if (m.message_type === 'image') { row.storage_path = m.storage_path; row.mime_type = m.mime_type; row.file_size = m.file_size; }
  var r = await sb.from('messages').insert(row).select('seq,created_at').single();
  if (r.error && r.error.code === '23505') r = await sb.from('messages').select('seq,created_at').eq('id', m.id).single();   // 이미 저장된 메시지(재시도)
  if (r.error) {
    m._st = 'failed';
    en = shown.get(m.id); if (en) paint(en);
    return;
  }
  m.seq = r.data.seq; m.created_at = r.data.created_at; m._st = 'sent'; m._file = null;
  outbox.delete(m.id);
  kickPush(m.id);
  en = shown.get(m.id); if (en) paint(en);
  var c = convs.get(m.conversation_id);
  if (c) { c.lastAt = m.created_at; scheduleRender(); }
  scheduleRead();
}
function retryFailed() {
  outbox.forEach(function (m) { if (m._st === 'failed') retry(m); });
}

/* 사진 */
function sendImage(f) {
  if (!active) return;
  if (!EXT[f.type]) return hint('JPEG, PNG, WebP 사진만 보낼 수 있습니다.');
  if (f.size > MAX_IMG) return hint('사진은 10MB 이하만 보낼 수 있습니다. (' + (f.size / 1048576).toFixed(1) + 'MB)');
  if (f.size < 1) return hint('빈 파일입니다.');
  var m = newMsg('image');
  m.storage_path = active + '/' + uuid() + '.' + EXT[f.type];
  m.mime_type = f.type; m.file_size = f.size; m._file = f; m._blob = URL.createObjectURL(f); m._p = 0;
  hint('');
  appendMsg(m);
  upload(m);
}
async function upload(m) {
  outbox.set(m.id, m);
  m._st = 'sending'; m._p = 0;
  var en = shown.get(m.id); if (en) paint(en);
  try { await putObject(m); m._up = true; }
  catch (e) {
    m._st = 'failed';
    en = shown.get(m.id); if (en) paint(en);
    hint('사진 업로드에 실패했습니다. 재시도를 눌러 주세요.');
    return;
  }
  post(m);
}
async function putObject(m) {     // XHR 로 올려서 진행률을 얻는다. 파일은 Storage 에만 저장된다.
  var s = (await sb.auth.getSession()).data.session;
  if (!s) throw new Error('no session');
  return new Promise(function (res, rej) {
    var x = new XMLHttpRequest();
    x.open('POST', CFG.supabaseUrl.replace(/\/+$/, '') + '/storage/v1/object/' + BUCKET + '/' + m.storage_path);
    x.setRequestHeader('Authorization', 'Bearer ' + s.access_token);
    x.setRequestHeader('apikey', CFG.supabaseAnonKey);
    x.setRequestHeader('Content-Type', m.mime_type);
    x.setRequestHeader('x-upsert', 'false');
    x.timeout = 180000;
    x.upload.onprogress = function (e) {
      if (!e.lengthComputable) return;
      m._p = Math.min(99, Math.round(e.loaded * 100 / e.total));
      var en = shown.get(m.id);
      if (en && en.pg) en.pg.textContent = '업로드 ' + m._p + '%';
    };
    x.onload = function () {
      var dup = x.status === 409 || (x.status === 400 && /already exists|duplicate/i.test(x.responseText));
      if ((x.status >= 200 && x.status < 300) || dup) res(); else rej(new Error(x.responseText || ('HTTP ' + x.status)));
    };
    x.onerror = function () { rej(new Error('network')); };
    x.ontimeout = function () { rej(new Error('timeout')); };
    x.send(m._file);
  });
}

/* ---------- 읽음 처리 ---------- */
function lastSeqEntry() {
  for (var e = msEl.lastElementChild; e; e = e.previousElementSibling) if (e.dataset.seq) return e;
  return null;
}
function scheduleRead() {         // 여러 번 호출돼도 0.5초 안에 한 번만 서버로 보낸다
  if (!pendingRead) pendingRead = setTimeout(function () { pendingRead = null; doRead(); }, 500);
}
function doRead() {
  if (!active || firstLoading || !viewing(active)) return;   // 채팅방을 실제로 보고 있을 때만
  var c = convs.get(active), mm = c && c.members.get(me.id), e = lastSeqEntry();
  if (!mm || !e) return;
  var seq = Number(e.dataset.seq);
  if (seq <= mm.seq) { if (c.unread) { c.unread = 0; setBadge(c); } return; }
  var prev = mm.seq;
  mm.seq = seq; c.unread = 0; setBadge(c);
  sb.rpc('mark_read', { p_conv: active, p_message: e.dataset.id }).then(function (r) {
    if (r.error) { mm.seq = prev; setTimeout(scheduleRead, 3000); }
  });
}

/* ---------- Realtime (연결 1개로 모든 변경 수신) ---------- */
var openReloadT = null;
function scheduleOpenRoomsReload() {
  clearTimeout(openReloadT);
  openReloadT = setTimeout(async function () {
    if (!sb || !me) return;
    var r = await sb.rpc('list_open_rooms');
    if (!r.error) { openRooms = r.data || []; renderOpenRooms(); }
  }, 500);
}
function scheduleRoomReload() {
  scheduleReload();
  scheduleOpenRoomsReload();
}
function startRealtime() {
  if (chan) return;
  var seen = false;
  chan = sb.channel('app-' + me.id)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages' }, function (p) { onMsg(p.new); })
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'conversation_members' }, function (p) { onMember(p.new); })
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'conversation_members' }, scheduleReload)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'friendships' }, scheduleReload)
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'friendships' }, scheduleReload)
    .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'conversations' }, scheduleRoomReload)
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'conversations' }, scheduleRoomReload)
    .on('postgres_changes', { event: 'DELETE', schema: 'public', table: 'conversations' }, scheduleRoomReload)
    .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'profiles' }, scheduleReload)
    .subscribe(function (status) {
      if (status === 'SUBSCRIBED') { setNet(true); if (seen) sync(); seen = true; }
      else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') setNet(false, '서버 연결 끊김 · 재연결 중');
    });
}
function refreshOnlineUsers() {
  if (!presenceChan) return;
  var state = presenceChan.presenceState(), next = new Set();
  Object.keys(state).forEach(function (key) {
    (state[key] || []).forEach(function (p) {
      if (p && p.user_id) next.add(p.user_id);
    });
  });
  onlineUsers = next;
  scheduleRender();
}
function startPresence() {
  if (presenceChan || !sb || !me) return;
  var pc = sb.channel('seogochat-presence', { config: { presence: { key: uuid() } } });
  presenceChan = pc;
  pc.on('presence', { event: 'sync' }, refreshOnlineUsers)
    .on('presence', { event: 'join' }, refreshOnlineUsers)
    .on('presence', { event: 'leave' }, refreshOnlineUsers)
    .subscribe(async function (status) {
      if (status === 'SUBSCRIBED') {
        try { await pc.track({ user_id: me.id }); refreshOnlineUsers(); }
        catch (e) { onlineUsers.delete(me.id); scheduleRender(); }
      } else if (status === 'CHANNEL_ERROR' || status === 'TIMED_OUT') {
        onlineUsers.delete(me.id); scheduleRender();
      }
    });
}
function onMsg(m) {
  if (!m || !m.id) return;
  var c = convs.get(m.conversation_id);
  if (!c) { scheduleReload(); return; }
  var mine = m.sender_id === me.id;
  if (!mine || !c.lastAt || ts(m.created_at) > ts(c.lastAt)) { c.lastAt = m.created_at; scheduleRender(); }
  if (c.type === 'open') scheduleOpenRoomsReload();
  if (active === m.conversation_id) {
    var en = shown.get(m.id);
    if (en) {                                          // 내가 보낸 메시지가 돌아온 경우
      if (en.m._st !== 'sent') { en.m.seq = m.seq; en.m.created_at = m.created_at; en.m._st = 'sent'; outbox.delete(m.id); paint(en); }
    } else {
      if (!c.members.has(m.sender_id)) scheduleReload();   // 처음 보는 발신자
      signMany([m]).then(function () { appendMsg(m); });
    }
  }
  if (mine) return;
  if (viewing(m.conversation_id)) scheduleRead();          // 지금 보고 있는 방: 알림 없이 읽음 처리
  else { c.unread++; setBadge(c); notifyIncoming(c, m); }
}
function onMember(r) {
  if (!r) return;
  var c = convs.get(r.conversation_id), mm = c && c.members.get(r.user_id);
  if (!c || !mm) { scheduleReload(); return; }
  var left = !!r.left_at, seq = Number(r.last_read_seq) || 0;
  if (left !== mm.left) scheduleReload();                // 나가기/다시 참가
  var other = r.user_id === me.id && seq > mm.seq;       // 다른 기기에서 내가 읽음 처리한 경우
  mm.left = left; mm.seq = Math.max(mm.seq, seq);
  if (other) scheduleReload();
  if (active === r.conversation_id) refreshNums();       // 상대가 읽으면 숫자가 실시간으로 줄어든다
}
async function fillGap() {        // 연결이 끊겼던 동안 놓친 메시지 보충
  if (!active || firstLoading) return;
  var id = active, tok = loadTok;
  var e = lastSeqEntry();
  if (!e) { firstLoading = true; loadLatest(id, ++loadTok); return; }
  for (var i = 0; i < 5; i++) {
    e = lastSeqEntry();
    var r = await sb.from('messages').select(COLS).eq('conversation_id', id).gt('seq', Number(e.dataset.seq)).order('seq', { ascending: true }).limit(100);
    if (tok !== loadTok || r.error) return;
    await signMany(r.data);
    if (tok !== loadTok) return;
    r.data.forEach(appendMsg);
    if (r.data.length < 100) break;
  }
  scheduleRead();
}
function sync() {
  if (!sb || !me) return;
  scheduleReload(); fillGap(); retryFailed();
}

/* ---------- 친구 ---------- */
function say(t) { $('ast').textContent = t || ''; }
function errText(e) {
  var s = msgOf(e);
  if (s.indexOf('user_not_found') >= 0) return '존재하지 않는 코드입니다.';
  if (s.indexOf('lookup_rate_limited') >= 0) return '코드 검색을 너무 많이 시도했습니다. 10분 후 다시 시도하세요.';
  if (s.indexOf('self') >= 0) return '자신의 코드는 추가할 수 없습니다.';
  if (s.indexOf('invalid_code') >= 0) return '올바른 코드를 입력하세요.';
  if (s.indexOf('name_required') >= 0) return '이름을 입력하세요.';
  if (s.indexOf('invalid_name') >= 0) return '이름은 한글과 숫자만 사용해 12자 이내로 입력하세요.';
  if (s.indexOf('room_not_found') >= 0) return '존재하지 않는 방 코드입니다.';
  if (s.indexOf('room_owner_only') >= 0) return '방장만 할 수 있는 작업입니다.';
  return '처리하지 못했습니다. 네트워크를 확인하고 다시 시도하세요.';
}
async function doAdd() {
  var code = $('ac').value.trim();
  if (!/^\d{4}$/.test(code)) return say('4자리 숫자를 입력하세요.');
  if (code === me.code) return say('자신의 코드는 추가할 수 없습니다.');
  say('요청 중…'); $('ago').disabled = true;
  var r = await sb.rpc('send_friend_request', { p_code: code });
  $('ago').disabled = false;
  if (r.error) return say(errText(r.error));
  $('ac').value = '';
  if (r.data === 'sent') say('요청을 보냈습니다. 상대가 수락하면 목록에 추가됩니다.');
  else if (r.data === 'already_sent') say('이미 요청을 보냈습니다. 상대의 수락을 기다리는 중입니다.');
  else if (r.data === 'already_friends') say('이미 등록된 친구입니다.');
  else { say('친구가 추가되었습니다.'); reload(); }
}
async function answerReq(r, ok) {
  var res = await sb.rpc('respond_friend_request', { p_id: r.id, p_accept: ok });
  if (res.error) { say(errText(res.error)); }
  reqs = reqs.filter(function (x) { return x.id !== r.id; });
  renderReqs();
  reload();
}
async function removeFriend(c) {
  var o = otherOf(c);
  if (!o) return;
  if (!confirm(o.name + '님을 삭제할까요?\n서로의 목록에서 삭제되고 대화를 볼 수 없게 됩니다. 다시 친구가 되면 이전 대화가 복원됩니다.')) return;
  var r = await sb.rpc('remove_friend', { p_user: o.id });
  if (r.error) { alert('삭제하지 못했습니다. 네트워크를 확인하세요.'); return; }
  if (active === c.id) showList();
  reload();
}

/* ---------- 방 관리 ---------- */
function rsay(t) { $('rst').textContent = t || ''; }
async function doCreateOpenRoom() {
  var name = $('rn').value.trim();
  if (!name) return rsay('오픈채팅방 이름을 입력하세요.');
  $('rmkb').disabled = true; rsay('오픈채팅방 만드는 중…');
  var r = await sb.rpc('create_open_room', { p_name: name });
  $('rmkb').disabled = false;
  if (r.error) {
    var message = msgOf(r.error).indexOf('open_room_limit') >= 0
      ? '오픈채팅방은 한 사람당 하나만 만들 수 있습니다.'
      : errText(r.error);
    return rsay(message);
  }
  var room = Array.isArray(r.data) ? r.data[0] : r.data;
  $('rn').value = '';
  $('roomp').hidden = true;
  await reload();
  openChat(room.id);
  hint('오픈채팅방을 만들었습니다.');
}
async function doCreateCodeRoom() {
  var name = $('grn').value.trim();
  if (!name) return rsay('코드방 이름을 입력하세요.');
  $('grmb').disabled = true; rsay('6자리 코드방 만드는 중…');
  var r = await sb.rpc('create_code_room', { p_name: name });
  $('grmb').disabled = false;
  if (r.error) return rsay(errText(r.error));
  var room = Array.isArray(r.data) ? r.data[0] : r.data;
  $('grn').value = '';
  $('roomp').hidden = true;
  await reload();
  openChat(room.id);
  hint('방 코드 ' + room.room_code + '가 발급됐습니다. 참여자에게 공유하세요.');
}
async function joinCodeRoom() {
  var code = $('rc').value.trim();
  if (!/^\d{6}$/.test(code)) return rsay('방 코드 6자리를 입력하세요.');
  $('rcb').disabled = true; rsay('코드 확인 중…');
  var r = await sb.rpc('join_code_room', { p_code: code });
  $('rcb').disabled = false;
  if (r.error) {
    var m = msgOf(r.error);
    if (m.indexOf('room_lookup_rate_limited') >= 0) return rsay('코드 입력을 너무 많이 시도했습니다. 10분 후 다시 시도하세요.');
    if (m.indexOf('room_not_found') >= 0) return rsay('존재하지 않는 방 코드입니다.');
    if (m.indexOf('invalid_room_code') >= 0) return rsay('방 코드는 숫자 6자리입니다.');
    return rsay(errText(r.error));
  }
  if (!r.data || !r.data.ok) return rsay('방에 참가하지 못했습니다.');
  $('rc').value = ''; $('roomp').hidden = true;
  await reload();
  openChat(r.data.id);
}
async function joinOpenRoom(id) {
  var r = await sb.rpc('join_open_room', { p_conv: id });
  if (r.error) { hint('오픈채팅에 참가하지 못했습니다. 다시 시도하세요.'); return; }
  if (!r.data || !r.data.ok) { hint('이 오픈채팅방은 더 이상 참가할 수 없습니다.'); scheduleOpenRoomsReload(); return; }
  await reload();
  openChat(id);
}
async function editMyName() {
  var next = prompt('새 이름을 입력하세요. 한글과 숫자만, 최대 12자입니다.', me.name);
  if (next === null) return;
  next = next.trim();
  if (!/^[가-힣0-9]{1,12}$/.test(next)) {
    hint('이름은 한글과 숫자만 사용해 12자 이내로 입력하세요.');
    return;
  }
  var r = await sb.rpc('update_my_name', { p_name: next });
  if (r.error) { hint('이름을 수정하지 못했습니다.'); return; }
  me.name = next;
  lset('pm_me', me);
  $('myn').textContent = next;
  convs.forEach(function (c) {
    var mine = c.members.get(me.id);
    if (mine) mine.name = next;
  });
  refreshNames(); updateHeader(); renderPanel(); renderLists();
  await reload();
  hint('이름을 수정했습니다.');
}
async function renameRoom() {
  var c = convs.get(active);
  if (!c || c.type === 'direct' || c.owner !== me.id) return;
  var next = prompt('새 방 이름을 입력하세요. (최대 30자)', c.name);
  if (next === null) return;
  next = next.trim();
  if (!next || next.length > 30) { hint('방 이름은 1~30자로 입력하세요.'); return; }
  var r = await sb.rpc('rename_room', { p_conv: c.id, p_name: next });
  if (r.error) { hint('방 이름을 수정하지 못했습니다.'); return; }
  c.name = next; updateHeader(); renderLists(); renderOpenRooms();
  await reload();
  hint('방 이름을 수정했습니다.');
}
async function roomAction() {
  var c = convs.get(active);
  if (!c || c.type === 'direct') return;
  if (c.owner !== me.id) {
    if (!confirm('"' + c.name + '" 방에서 나갈까요?')) return;
    var leave = await sb.rpc('leave_room', { p_conv: c.id });
    if (leave.error) { hint('방에서 나가지 못했습니다.'); return; }
    showList(); await reload(); return;
  }

  if (!confirm('"' + c.name + '" 방과 모든 메시지를 삭제합니다. 계속할까요?')) return;
  var phrase = prompt('방을 삭제하려면 아래 문구를 그대로 입력하세요.\n\n삭제하겠습니다');
  if (phrase === null) return;
  if (phrase !== '삭제하겠습니다') { hint('확인 문구가 일치하지 않아 삭제하지 않았습니다.'); return; }

  // 방 이미지도 먼저 Storage API로 삭제한다. 실패하면 대화방 삭제를 진행하지 않는다.
  var listing = await sb.storage.from(BUCKET).list(c.id, { limit: 1000 });
  if (listing.error) { hint('방 사진 목록을 확인하지 못해 삭제하지 않았습니다.'); return; }
  var paths = (listing.data || []).filter(function (x) { return x.name; })
    .map(function (x) { return c.id + '/' + x.name; });
  if (paths.length) {
    var removed = await sb.storage.from(BUCKET).remove(paths);
    if (removed.error) { hint('방 사진 삭제에 실패해 방을 삭제하지 않았습니다.'); return; }
  }

  var r = await sb.rpc('delete_room', { p_conv: c.id, p_confirmation: phrase });
  if (r.error) { hint('방을 삭제하지 못했습니다.'); return; }
  showList();
  await reload();
  hint('방과 메시지를 삭제했습니다.');
}

/* ---------- 푸시 알림 (권한 → Service Worker → Push 구독 → 서버 저장) ---------- */
var vapidKey = '', pushBusy = false, nbState = '', lastErr = '', notified = new Set(), toastT = null;

function pushOk() { return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window; }
function pushOff() { return lget('pm_pushoff', false); }          // 사용자가 직접 끈 기기
function setNst(text, cls) {
  // 성공 상태 문구는 표시하지 않는다. 실패만 짧은 토스트로 알린다.
  if (text && cls === 'bad' && me) toast('알림 설정', text, null);
}
function errMsg(e) {
  var st = e && e.context && e.context.status;
  return st ? 'HTTP ' + st : msgOf(e).slice(0, 80);
}
function stepErr(step, e) { return new Error(step + ' (' + errMsg(e) + ')'); }
function b64u(s) {
  var r = atob((s + '='.repeat((4 - s.length % 4) % 4)).replace(/-/g, '+').replace(/_/g, '/'));
  var o = new Uint8Array(r.length);
  for (var i = 0; i < r.length; i++) o[i] = r.charCodeAt(i);
  return o;
}
function toB64u(buf) {
  var b = new Uint8Array(buf), s = '';
  for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
async function currentSub() {
  var reg = await navigator.serviceWorker.getRegistration('/');
  return reg ? reg.pushManager.getSubscription() : null;
}
function askPermission() {
  // 권한 요청은 사용자의 클릭 처리 안에서 즉시 호출해야 한다.
  // 구형 callback 인자는 사용하지 않고 표준 Promise 반환값을 사용한다.
  try { return Notification.requestPermission(); }
  catch (e) { return Promise.reject(e); }
}

async function getReg() {
  var reg;
  try { reg = await navigator.serviceWorker.register('/sw.js'); }
  catch (e) { throw stepErr('서비스 워커 등록 실패', e); }
  if (reg.active) return reg;
  try {
    return await Promise.race([navigator.serviceWorker.ready, new Promise(function (_, rej) { setTimeout(function () { rej(new Error('시간 초과')); }, 10000); })]);
  } catch (e) { throw stepErr('서비스 워커 시작 실패', e); }
}
async function getVapidKey() {    // 서버(Vault)의 키가 기준. 서버 호출이 실패할 때만 config.js 값을 쓴다.
  if (vapidKey) return vapidKey;
  var r = await sb.functions.invoke('send-push', { body: { action: 'public-key' } });
  if (!r.error && r.data && r.data.publicKey) { vapidKey = r.data.publicKey; return vapidKey; }
  if (CFG.vapidPublicKey) { vapidKey = CFG.vapidPublicKey; return vapidKey; }
  throw stepErr('VAPID 키 조회 실패', r.error || new Error('응답 없음'));
}
async function ensureSub(reg, key) {
  var sub = await reg.pushManager.getSubscription();
  var opt = { userVisibleOnly: true, applicationServerKey: b64u(key) };
  if (sub && sub.options && sub.options.applicationServerKey && toB64u(sub.options.applicationServerKey) !== key) {
    await sub.unsubscribe(); sub = null;                           // 서버 키와 다른 낡은 구독은 푸시 서비스가 거부한다
  }
  if (sub) return sub;
  try { return await reg.pushManager.subscribe(opt); }
  catch (e) {
    if (e && e.name === 'InvalidStateError') {
      try { var old = await reg.pushManager.getSubscription(); if (old) await old.unsubscribe(); return await reg.pushManager.subscribe(opt); } catch (e2) { e = e2; }
    }
    throw stepErr('Push 구독 생성 실패', e);
  }
}
async function saveSub(sub) {
  var r = await sb.rpc('save_push_subscription', { p_subscription: sub.toJSON() });
  if (r.error) throw stepErr('서버 저장 실패', r.error);
  var c = await sb.from('push_subscriptions').select('id').eq('endpoint', sub.endpoint).maybeSingle();
  if (c.error || !c.data) throw stepErr('서버 저장 확인 실패', c.error || new Error('저장된 구독이 없습니다'));
}

async function enablePush() {     // 권한이 이미 granted 일 때 구독을 만들고 서버에 저장한다
  if (pushBusy) return;
  pushBusy = true; lastErr = '';
  setNst('푸시 구독 중…', 'warn'); $('nb').disabled = true;
  try {
    var reg = await getReg();
    var key = await getVapidKey();
    var sub = await ensureSub(reg, key);
    await saveSub(sub);
    lset('pm_pushoff', false);
  } catch (e) { lastErr = 'Push 구독 실패 — ' + msgOf(e); }
  pushBusy = false;
  refreshNb();
}
async function disablePush() {
  pushBusy = true; lastErr = ''; $('nb').disabled = true;
  try {
    var sub = await currentSub();
    if (sub) { await sb.from('push_subscriptions').delete().eq('endpoint', sub.endpoint); await sub.unsubscribe(); }
    lset('pm_pushoff', true);
  } catch (e) { lastErr = '알림을 끄지 못했습니다 — ' + errMsg(e); }
  pushBusy = false;
  refreshNb();
}
function onNbClick() {
  if (!pushOk() || pushBusy) return;
  var perm = Notification.permission;
  if (perm === 'denied') {
    toast('알림이 차단되어 있습니다',
      'Chrome 사이트 설정에서 이 사이트의 알림을 허용해야 합니다. 학교 기기 정책으로 차단된 경우에는 관리자의 설정이 필요합니다.', null);
    return;
  }
  if (perm === 'default') {
    pushBusy = true; lastErr = ''; $('nb').disabled = true;
    // await나 다른 비동기 작업을 거치지 않고 클릭 이벤트 안에서 요청한다.
    askPermission().then(function (result) {
      pushBusy = false;
      if (result === 'granted') {
        enablePush();
      } else if (result === 'denied') {
        nbState = 'denied';
        $('nb').textContent = '알림 차단됨';
        $('nb').disabled = true;
        toast('알림 권한이 거부되었습니다',
          'Chrome 주소창 왼쪽의 사이트 설정에서 알림 권한을 변경할 수 있습니다. 학교 기기 정책으로 잠겨 있으면 관리자에게 문의해야 합니다.', null);
      } else {
        refreshNb();
        toast('알림 권한을 확인하지 못했습니다',
          'Chrome 주소창의 사이트 설정에서 알림 권한을 확인한 뒤 다시 시도하세요.', null);
      }
    }).catch(function (e) {
      pushBusy = false;
      $('nb').disabled = false;
      lastErr = '알림 권한 요청 실패 — ' + msgOf(e);
      refreshNb();
      toast('알림 설정 오류', lastErr, null);
    });
    return;
  }
  if (nbState === 'on') disablePush(); else enablePush();
}
async function refreshNb() {      // 권한 상태 / 구독 상태 / 서버 등록 상태를 구분해서 표시
  var b = $('nb');
  if (!pushOk()) {
    nbState = 'unsupported'; b.hidden = true;
    setNst(window.isSecureContext === false ? '알림은 HTTPS 주소에서만 사용할 수 있습니다.' : '이 브라우저는 푸시 알림을 지원하지 않습니다. (iPhone/iPad는 홈 화면에 추가한 앱에서만 가능)', 'warn');
    return;
  }
  b.hidden = false;
  var perm = Notification.permission;
  if (perm === 'denied') {
    nbState = 'denied'; b.textContent = '알림 차단됨'; b.disabled = true;
    setNst('브라우저 권한 거부됨 — 주소창 왼쪽 자물쇠(사이트 설정) → 알림 → "허용"으로 바꾼 뒤 새로고침하세요.', 'bad');
    return;
  }
  b.disabled = pushBusy;
  if (perm === 'default') {
    nbState = 'default'; b.textContent = '알림 켜기';
    setNst(lastErr || '권한 요청 필요 — "알림 켜기"를 누르세요.', lastErr ? 'bad' : 'warn');
    return;
  }
  var sub = null, saved = false;
  try {
    sub = await currentSub();
    if (sub) { var c = await sb.from('push_subscriptions').select('id').eq('endpoint', sub.endpoint).maybeSingle(); saved = !!c.data; }
  } catch (e) {}
  if (perm !== Notification.permission) return refreshNb();        // 확인하는 사이 권한이 바뀐 경우
  if (sub && saved) {
    nbState = 'on'; b.textContent = '알림 끄기';
    if (lastErr) setNst(lastErr, 'bad');
  } else if (sub) {
    nbState = 'unsaved'; b.textContent = '알림 켜기';
    setNst(lastErr || 'Push 구독 실패 — 서버에 등록되지 않았습니다. "알림 켜기"로 다시 시도하세요.', 'bad');
  } else if (pushOff()) {
    nbState = 'off'; b.textContent = '알림 켜기';
    setNst(lastErr || '알림이 꺼져 있습니다.', lastErr ? 'bad' : '');
  } else {
    nbState = 'nosub'; b.textContent = '알림 켜기';
    setNst(lastErr || '권한은 허용됨 — Push 구독이 필요합니다.', lastErr ? 'bad' : 'warn');
  }
}
async function initPush() {       // 로그인 직후: 권한 팝업은 띄우지 않는다. 이미 허용된 경우에만 조용히 구독을 맞춘다.
  if (!pushOk()) { refreshNb(); return; }
  if (!initPush.bound) {
    initPush.bound = true;
    navigator.serviceWorker.addEventListener('message', function (e) {
      var d = e.data || {};
      if (d.type === 'open') openById(d.c);                        // 알림 클릭 → 해당 방으로
      else if (d.type === 'viewing?' && e.ports && e.ports[0]) e.ports[0].postMessage({ viewing: viewing(d.c) });
    });
    try { navigator.permissions.query({ name: 'notifications' }).then(function (st) { st.onchange = function () { if (me) refreshNb(); }; }); } catch (e) {}
  }
  if (Notification.permission === 'granted' && !pushOff()) enablePush();
  else { try { await getReg(); } catch (e) {} refreshNb(); }       // Service Worker 는 항상 등록해 둔다
}
/* 앱이 열려 있을 때의 알림 (Realtime 으로 받은 새 메시지). 같은 tag 를 써서 서버 푸시와 합쳐진다. */
function kickPush(id) {           // 보낸 사람 앱이 서버에 알림 발송을 요청 (DB 트리거가 막혀도 알림이 가도록). 서버가 중복을 걸러낸다.
  try { sb.functions.invoke('send-push', { body: { message_id: id } }).then(noop, noop); } catch (e) {}
}
function toast(title, body, cid) {
  var t = $('toast');
  t.replaceChildren(el('b', null, title), document.createTextNode(body));
  t.hidden = false;
  t.onclick = function () { t.hidden = true; openById(cid); };
  clearTimeout(toastT);
  toastT = setTimeout(function () { t.hidden = true; }, 5000);
}
async function notifyIncoming(c, m) {
  if (notified.has(m.id) || pushOff()) return;
  notified.add(m.id);
  if (notified.size > 300) notified.delete(notified.values().next().value);
  var sender = nameOf(c, m.sender_id);
  var title = (c.type === 'open' || c.type === 'group') ? sender + ' · ' + c.name : sender;
  var body = m.message_type === 'image' ? '사진을 보냈습니다.' : String(m.content).replace(/\s+/g, ' ').trim().slice(0, 80);
  var done = false;
  if (pushOk() && Notification.permission === 'granted') {
    try {
      var reg = await navigator.serviceWorker.getRegistration('/');
      if (reg) {
        var ex = await reg.getNotifications({ tag: m.id });          // 서버 푸시가 먼저 표시했다면 다시 띄우지 않는다
        if (!ex.length) await reg.showNotification(title, { body: body, tag: m.id, data: { c: c.id } });
        done = true;
      }
    } catch (e) {}
  }
  if (!done && !document.hidden) toast(title, body, c.id);          // 권한이 없을 때의 앱 안 알림
}

/* ---------- 기타 ---------- */
function openById(id) {
  if (!id || !UUID_RE.test(id)) return;
  if (active === id) { scheduleRead(); return; }
  if (convs.has(id)) openChat(id); else { pendingOpen = id; scheduleReload(); }
}
function copyText(text, b) {
  var old = b.textContent;
  var ok = function () { b.textContent = '복사됨'; setTimeout(function () { b.textContent = old; }, 1200); };
  var fb = function () {
    var t = document.createElement('textarea'); t.value = text; document.body.appendChild(t); t.select();
    try { document.execCommand('copy'); ok(); } catch (e) {}
    document.body.removeChild(t);
  };
  if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(ok, fb);
  else fb();
}
function resetState() {
  if (chan) { try { sb.removeChannel(chan); } catch (e) {} chan = null; }
  if (presenceChan) { try { sb.removeChannel(presenceChan); } catch (e) {} presenceChan = null; }
  onlineUsers = new Set();
  clearTimeout(rlT); clearTimeout(pendingRead); pendingRead = null;
  convs = new Map(); openRooms = []; reqs = []; shown = new Map(); outbox = new Map(); urls = new Map(); queued = [];
  active = null; me = null; loadTok++; firstLoading = false; pendingOpen = null; panelOpen = false;
  msEl.replaceChildren();
  $('fl').replaceChildren(); $('rl').replaceChildren(); $('cl').replaceChildren(); $('rql').replaceChildren();
  vapidKey = ''; lastErr = ''; nbState = ''; notified = new Set(); $('toast').hidden = true;
  document.title = '서고챗';
}
async function logout() {
  if (!confirm('로그아웃할까요?\n\n이 계정은 익명 계정이라 로그아웃하면 다시 로그인할 수 없습니다. 친구·방·대화 기록에 더 이상 접근할 수 없게 됩니다.')) return;
  loggingOut = true;
  try {                           // 이 기기의 푸시 구독 정리
    var sub = await currentSub();
    if (sub) { await sb.from('push_subscriptions').delete().eq('endpoint', sub.endpoint); await sub.unsubscribe(); }
  } catch (e) {}
  try { await sb.auth.signOut({ scope: 'local' }); } catch (e) {}   // 이 기기 세션만 종료
  try { localStorage.removeItem('pm_me'); } catch (e) {}
  lset('pm_had', false);
  resetState();
  loggingOut = false;
  showReg('');
}

/* ---------- 시작 ---------- */
function showReg(msg) {
  $('app').hidden = true;
  $('reg').hidden = false;
  $('go').disabled = false;
  $('rs').textContent = msg || '';
  $('nm').focus();
}
function regError(e) {
  var s = msgOf(e).toLowerCase();
  if (s.indexOf('anonymous') >= 0 && s.indexOf('disabled') >= 0) return '익명 로그인이 꺼져 있습니다. Supabase에서 Anonymous Sign-ins 를 켜 주세요.';
  if (s.indexOf('rate') >= 0 || s.indexOf('429') >= 0) return '요청이 너무 많습니다. 잠시 후 다시 시도하세요.';
  if (s.indexOf('fetch') >= 0 || s.indexOf('network') >= 0) return '서버에 연결하지 못했습니다. 네트워크를 확인하세요.';
  if (s.indexOf('codes_exhausted') >= 0) return '사용 가능한 코드가 없습니다.';
  return '가입하지 못했습니다. 다시 시도하세요.';
}
async function register(name) {
  var rs = $('rs'), go = $('go');
  go.disabled = true; rs.textContent = '연결 중…';
  try {
    var s = (await sb.auth.getSession()).data.session;
    if (!s) { var a = await sb.auth.signInAnonymously(); if (a.error) throw a.error; }
    var r = await sb.rpc('create_profile', { p_name: name });   // 서버가 4자리 코드를 원자적으로 발급
    if (r.error) throw r.error;
    var p = Array.isArray(r.data) ? r.data[0] : r.data;
    me = { id: p.id, name: p.username, code: p.user_code };
    lset('pm_me', me); lset('pm_had', true);
    enter();
  } catch (e) {
    rs.textContent = regError(e);
    go.disabled = false;
  }
}
function enter() {
  $('reg').hidden = true;
  $('app').hidden = false;
  $('myn').textContent = me.name;
  $('myc').textContent = me.code;
  renderLists(); renderReqs();
  setNet(false, '서버 연결 중…');
  var c = new URLSearchParams(location.search).get('c');        // 알림을 눌러 새로 열린 경우
  if (c && UUID_RE.test(c)) pendingOpen = c;
  if (c) history.replaceState(null, '', location.pathname);
  startRealtime();
  startPresence();
  reload();
  initPush();
}
async function start() {
  if (!CFG.supabaseUrl || !CFG.supabaseAnonKey || !window.supabase) {
    showReg('Supabase 설정이 없습니다. 환경변수(또는 public/config.js)를 확인하세요. README 8단계 참고');
    $('go').disabled = true;
    return;
  }
  sb = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
  });
  sb.auth.onAuthStateChange(function (ev) {                     // 콜백 안에서는 supabase 호출 금지
    if (ev === 'SIGNED_OUT' && me && !loggingOut) {
      resetState();
      showReg('로그인 정보가 사라졌습니다. 이름을 입력하면 새 계정이 만들어집니다. (익명 계정은 복구할 수 없습니다)');
    }
  });
  try { if (navigator.storage && navigator.storage.persist) navigator.storage.persist(); } catch (e) {}   // 브라우저가 로그인 정보를 임의로 지우지 않도록 요청

  var s = (await sb.auth.getSession()).data.session;
  if (!s) {
    showReg(lget('pm_had', false) ? '이전 계정의 로그인 정보가 없습니다. 이름을 입력하면 새 계정이 만들어집니다. (브라우저 데이터를 지웠거나 기기를 바꾸면 익명 계정은 복구할 수 없습니다)' : '');
    return;
  }
  var r = await sb.from('profiles').select('id,username,user_code').eq('id', s.user.id).maybeSingle();
  if (r.error) { showReg('서버에 연결하지 못했습니다. 네트워크를 확인하고 새로고침하세요.'); return; }
  if (!r.data) {
    await sb.auth.signOut({ scope: 'local' });
    try { localStorage.removeItem('pm_me'); } catch (e) {}
    lset('pm_had', false);
    showReg('');
    return;
  }
  me = { id: r.data.id, name: r.data.username, code: r.data.user_code };
  lset('pm_me', me);
  enter();
}

function init() {
  msEl = $('ms'); inp = $('inp');

  var nameInput = $('nm');
  // 영문 키보드 상태에서도 입력은 그대로 두고, 시작 버튼을 눌렀을 때 한글 규칙을 검사한다.
  $('rf').addEventListener('submit', function (e) {
    e.preventDefault();
    var name = nameInput.value.trim();
    if (!/^[가-힣0-9]{1,12}$/.test(name)) {
      $('rs').textContent = '한글과 숫자만 사용할 수 있습니다. 한글 입력 상태를 확인하세요.';
      nameInput.focus();
      return;
    }
    register(name);
  });
  $('cp').addEventListener('click', function () { copyText(me.code, $('cp')); });
  $('nameb').addEventListener('click', editMyName);
  $('lo').addEventListener('click', logout);
  $('nb').addEventListener('click', onNbClick);
  $('addb').addEventListener('click', function () {
    var p = $('addp'); p.hidden = !p.hidden;
    if (!p.hidden) { $('roomp').hidden = true; say(''); $('ac').focus(); }
  });
  $('roomb').addEventListener('click', function () {
    var p = $('roomp'); p.hidden = !p.hidden;
    if (!p.hidden) { $('addp').hidden = true; rsay(''); $('rn').focus(); }
  });
  $('ac').addEventListener('input', function () { this.value = this.value.replace(/\D/g, '').slice(0, 4); });
  $('addp').addEventListener('submit', function (e) { e.preventDefault(); doAdd(); });
  $('rmk').addEventListener('submit', function (e) { e.preventDefault(); doCreateOpenRoom(); });
  $('gmk').addEventListener('submit', function (e) { e.preventDefault(); doCreateCodeRoom(); });
  $('cjn').addEventListener('submit', function (e) { e.preventDefault(); joinCodeRoom(); });
  $('rc').addEventListener('input', function () { this.value = this.value.replace(/\D/g, '').slice(0, 6); });
  $('rnm').addEventListener('click', renameRoom);
  $('pb').addEventListener('click', function () {
    var p = $('pl'); panelOpen = p.hidden;
    p.hidden = !panelOpen;
    if (panelOpen) renderPanel();
  });
  $('lv').addEventListener('click', roomAction);
  $('at').addEventListener('click', function () { $('fi').click(); });
  $('fi').addEventListener('change', function () {
    var f = this.files && this.files[0];
    this.value = '';
    if (f) sendImage(f);
  });
  $('lb').addEventListener('click', closeLb);
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape' && !$('lb').hidden) closeLb(); });
  $('cf').addEventListener('submit', function (e) { e.preventDefault(); sendText(); inp.focus(); });
  inp.addEventListener('input', fitInput);
  inp.addEventListener('keydown', function (e) {
    if (e.key === 'Enter' && !e.shiftKey && !e.isComposing && e.keyCode !== 229) { e.preventDefault(); sendText(); }
  });
  msEl.addEventListener('scroll', function () {
    stick = msEl.scrollHeight - msEl.scrollTop - msEl.clientHeight < 80;
    if (msEl.scrollTop < 80) loadOlder();
  }, { passive: true });
  $('bk').addEventListener('click', function () {
    if (history.state && history.state.chat) history.back(); else showList();
  });
  window.addEventListener('popstate', function () { if (active) showList(); });

  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && me) { scheduleRead(); sync(); }
  });
  window.addEventListener('focus', function () { if (me) scheduleRead(); });
  window.addEventListener('online', function () { if (me) sync(); });
  window.addEventListener('offline', function () { if (me) setNet(false, '오프라인'); });

  start();
}
init();
})();
