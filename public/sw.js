/* 푸시 알림 전용 Service Worker (오프라인 캐시 없음) */
'use strict';

self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });

// 화면에 보이는 앱 창에게 "지금 이 대화방을 보고 있나?"를 물어본다. (응답이 없으면 아니라고 본다)
function askViewing(client, c) {
  return new Promise(function (resolve) {
    var done = false, ch = new MessageChannel();
    var t = setTimeout(function () { if (!done) { done = true; resolve(false); } }, 600);
    ch.port1.onmessage = function (e) {
      if (done) return;
      done = true; clearTimeout(t);
      resolve(!!(e.data && e.data.viewing));
    };
    try { client.postMessage({ type: 'viewing?', c: c }, [ch.port2]); }
    catch (err) { done = true; clearTimeout(t); resolve(false); }
  });
}

self.addEventListener('push', function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) {}
  e.waitUntil((async function () {
    // 테스트 알림이 아니고, 사용자가 이미 그 대화방을 보고 있다면 알림을 띄우지 않는다. (중복 알림 방지)
    if (!d.test && d.c) {
      var wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      for (var i = 0; i < wins.length; i++) {
        var w = wins[i];
        if (w.visibilityState === 'visible' && w.focused && await askViewing(w, d.c)) return;
      }
    }
    // 같은 tag(=메시지 id)의 알림은 하나로 합쳐지므로, 앱이 직접 띄운 알림과 겹쳐도 한 번만 보인다.
    await self.registration.showNotification(String(d.title || '새 메시지'), {
      body: String(d.body || ''),
      tag: d.tag ? String(d.tag) : undefined,
      data: { c: d.c || null }
    });
  })());
});

self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var c = e.notification.data && e.notification.data.c;
  e.waitUntil((async function () {
    var wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    if (wins.length) {                              // 열려 있는 탭이 있으면 그 탭에서 해당 방으로 이동
      var w = wins.find(function (x) { return x.visibilityState === 'visible'; }) || wins[0];
      try { await w.focus(); } catch (err) {}
      if (c) w.postMessage({ type: 'open', c: c });
      return;
    }
    var url = new URL(self.registration.scope);     // 탭이 닫혀 있으면 새로 열어서 해당 방으로 이동
    if (c) url.searchParams.set('c', c);
    await self.clients.openWindow(url.href);
  })());
});
