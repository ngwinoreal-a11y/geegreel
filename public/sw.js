// Push notifications, plus best-effort offline reads for: the app shell
// itself, chat threads, the feed listing, and videos someone has actually
// watched. This is NOT a full offline-first app — posting, liking,
// uploading etc. all still require a connection. The goal is narrower:
// open the app with no signal and still see the app plus the messages and
// videos you already loaded, instead of a blank tab or a browser error.

// Cache Storage is shared per-origin, not per-context — index.html's
// loadFeed() opens API_CACHE by this same literal name to render the first
// feed page instantly on app open (stale-while-revalidate) instead of
// waiting on the network. If this name changes, update it there too.
const API_CACHE = "geereel-api-v1";
const VIDEO_CACHE = "geereel-offline-videos-v1";
const SHELL_CACHE = "geereel-shell-v1";
const THUMB_CACHE = "geereel-thumbs-v1";

// Without the app shell itself cached, "offline support" only ever worked
// for someone who was already inside the app when the connection dropped —
// closing the tab and reopening with no signal had nothing to load at all,
// browser-error-page territory. These rarely change, so precache them on
// install rather than waiting for a request to happen to hit them first.
const SHELL_FILES = [
  "/", "/index.html",
  "/design.css", "/design-2.css", "/design-3.css", "/design-4.css", "/design-5.css", "/design-feed.css",
  "/manifest.json", "/icons/icon-192.png", "/icons/icon-512.png",
];

self.addEventListener("install", (event) => {
  // Take over immediately on the NEXT activate rather than waiting for
  // every open tab to close — without this, a freshly deployed sw.js can
  // sit "waiting" for a long time and whoever's testing right after a
  // deploy is still running whatever service worker (or none) was
  // registered before it, silently testing the wrong version.
  self.skipWaiting();
  event.waitUntil(
    caches.open(SHELL_CACHE).then(cache => cache.addAll(SHELL_FILES)).catch(() => {})
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    await self.clients.claim();
    // Drop any cache from a previous version name so a future redesign of
    // this file doesn't leave orphaned entries behind forever.
    const keep = new Set([API_CACHE, VIDEO_CACHE, SHELL_CACHE, THUMB_CACHE]);
    const names = await caches.keys();
    await Promise.all(names.filter(n => n.startsWith("geereel-") && !keep.has(n)).map(n => caches.delete(n)));
  })());
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return; // writes always need a real connection
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Navigating to the app (opening it fresh, or reopening after it was
  // fully closed) with no signal — serve the last cached index.html rather
  // than letting the browser show its own offline error page.
  if (req.mode === "navigate") {
    event.respondWith((async () => {
      try {
        const res = await fetch(req);
        if (res.ok) (await caches.open(SHELL_CACHE)).put("/index.html", res.clone());
        return res;
      } catch {
        const cached = await caches.match("/index.html");
        if (cached) return cached;
        throw new Error("offline");
      }
    })());
    return;
  }

  // The design*.css files: same network-first-with-cache-fallback pattern
  // as the app shell above, kept fresh but still available offline.
  if (/^\/design(-[2-5]|-feed)?\.css$/.test(url.pathname)) {
    event.respondWith((async () => {
      try {
        const res = await fetch(req);
        if (res.ok) (await caches.open(SHELL_CACHE)).put(req, res.clone());
        return res;
      } catch {
        const cached = await caches.match(req);
        if (cached) return cached;
        throw new Error("offline");
      }
    })());
    return;
  }

  // Chat threads, the conversation list, the feed listing, and a looked-up
  // profile: try the network so the data stays current, but keep a copy so
  // the same request works with no signal. /api/users/:handle matters here
  // for a reason that isn't obvious — tapping a name in the inbox resolves
  // it to a full user object before opening the chat screen, so without
  // this cached too, opening an already-cached conversation still failed
  // offline: the failure was in getting there, not in the thread itself.
  // /api/posts (the Public tab's photo feed) rides the same rule for the
  // same reason as /api/feed — public.js reads this exact cache name to
  // paint the last page instantly instead of a skeleton, online or not.
  // /api/notifications the same way, for notificationsPage().
  const isCachedApi = url.pathname === "/api/messages" || /^\/api\/messages\/[\w-]+$/.test(url.pathname)
    || url.pathname === "/api/feed" || url.pathname === "/api/posts" || url.pathname === "/api/notifications"
    || /^\/api\/users\/[\w.]+$/.test(url.pathname);
  if (isCachedApi) {
    event.respondWith((async () => {
      try {
        const res = await fetch(req);
        if (res.ok) (await caches.open(API_CACHE)).put(req, res.clone());
        return res;
      } catch {
        const cached = await caches.match(req);
        if (cached) return cached;
        throw new Error("offline");
      }
    })());
    return;
  }

  // Video/photo bytes. A <video> streams with a Range header — those
  // responses are deliberately NOT written here; caching every byte-range
  // chunk separately would balloon storage for no real benefit. A video's
  // full bytes are only ever proactively cached by cacheVideoForOffline()
  // in index.html, once it's actually been watched — serving THIS request
  // from that cache works even though it carries a Range header: browsers
  // slice a stored full 200 response to satisfy a ranged request
  // automatically.
  //
  // A thumbnail or avatar is different — <img> always requests the whole
  // file, no Range, so there's no chunking problem, and these are small.
  // Without caching them too, a profile's video GRID (all thumbnails, no
  // playback) stayed blank offline even when the grid's own listing
  // (GET /api/users/:handle, cached above) loaded fine — the list of
  // videos was there, just nothing to actually show for each one.
  if (url.pathname.startsWith("/api/media/")) {
    const ranged = req.headers.has("Range");
    event.respondWith((async () => {
      try {
        const res = await fetch(req);
        if (res.ok && !ranged) (await caches.open(THUMB_CACHE)).put(req, res.clone());
        return res;
      } catch {
        const cached = await caches.match(req);
        if (cached) return cached;
        throw new Error("offline");
      }
    })());
  }
});

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data.json(); } catch {}

  // A message notification gets a one-tap "Reply" action, matching
  // WhatsApp/TikTok's own notifications. It can't actually send the reply
  // from here without the app open — auth is a Bearer token in localStorage
  // (see store.token in index.html), which a service worker has no access
  // to at all, unlike a cookie-based session. What it CAN do is open
  // straight into that chat with the composer already focused, which is
  // the honest version of this button rather than a fake "send in
  // background" that would silently fail with no page open.
  const isMessage = (data.tag || "").startsWith("message-");

  event.waitUntil(self.registration.showNotification(data.title || "Belople", {
    body: data.body || "",
    icon: "/icons/icon-192.png",
    // Android's status bar / notification-shade badge renders ONLY this
    // image's alpha channel (it tints it itself) — a full-color icon there
    // just shows as a grey blob, which is why the app wasn't showing up
    // clearly at the top the way TikTok/WhatsApp do. badge-mono.png is a
    // plain white silhouette on transparent, built for exactly this.
    badge: "/icons/badge-mono.png",
    tag: data.tag || "geereel",
    renotify: true,
    data: { url: data.url || "/", focusReply: isMessage },
    actions: isMessage ? [{ action: "reply", title: "Reply" }] : [],
  }));
});

// A tap (or the Reply action) focuses an already-open tab and hands it the
// target URL rather than always opening a fresh one — the app reads the URL
// itself and navigates. Reply additionally tells the page to focus the
// message composer once it lands there.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = event.notification.data?.url || "/";
  const focusReply = event.action === "reply" || event.notification.data?.focusReply;

  event.waitUntil((async () => {
    const clientsList = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of clientsList) {
      if ("focus" in c) {
        c.postMessage({ type: "navigate", url, focusReply });
        return c.focus();
      }
    }
    return self.clients.openWindow(focusReply ? `${url}${url.includes("?") ? "&" : "?"}focusReply=1` : url);
  })());
});
