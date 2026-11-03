/* 푸시 알림 전용 Service Worker (오프라인 캐시 없음) */
'use strict';

self.addEventListener('install', function () { self.skipWaiting(); });
self.addEventListener('activate', function (e) { e.waitUntil(self.clients.claim()); });

self.addEventListener('push', function (e) {
  var d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) {}
  e.waitUntil((async function () {
    // 앱 창이 화면에 보이고 포커스가 있으면 앱 안의 숫자 배지로 충분하므로 알림을 띄우지 않는다.
    var wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    var seen = wins.some(function (w) { return w.visibilityState === 'visible' && w.focused; });
    if (seen) return;
    await self.registration.showNotification(String(d.title || '새 메시지'), {
      body: String(d.body || ''),
      tag: d.tag ? String(d.tag) : undefined,   // 같은 메시지의 알림은 하나로 합쳐 중복 방지
      data: { c: d.c || null }
    });
  })());
});

self.addEventListener('notificationclick', function (e) {
  e.notification.close();
  var c = e.notification.data && e.notification.data.c;
  e.waitUntil((async function () {
    var wins = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (var i = 0; i < wins.length; i++) {
      var w = wins[i];
      try { await w.focus(); } catch (err) {}
      w.postMessage({ type: 'open', c: c });      // 열려 있는 탭이 있으면 그 탭에서 해당 방으로 이동
      return;
    }
    var url = new URL(self.registration.scope);
    if (c) url.searchParams.set('c', c);
    await self.clients.openWindow(url.href);      // 탭이 닫혀 있으면 새로 열어 해당 방으로 이동
  })());
});
