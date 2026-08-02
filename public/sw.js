// Push notifications, plus best-effort offline reads for two things: chat
// threads and videos someone has actually watched. This is NOT a full
// offline-first app — posting, liking, uploading etc. all still require a
// connection. The goal is narrower: open the app with no signal and still
// see the messages and videos you already loaded, instead of a blank/error
// screen.

const API_CACHE = "geereel-api-v1";
const VIDEO_CACHE = "geereel-offline-videos-v1";

self.addEventListener("activate", (event) => {
  // Drop any cache from a previous version name so a future redesign of
  // this file doesn't leave orphaned entries behind forever.
  event.waitUntil((async () => {
    const keep = new Set([API_CACHE, VIDEO_CACHE]);
    const names = await caches.keys();
    await Promise.all(names.filter(n => n.startsWith("geereel-") && !keep.has(n)).map(n => caches.delete(n)));
  })());
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return; // writes always need a real connection
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;

  // Chat threads, the conversation list, and the feed listing: try the
  // network so the data stays current, but keep a copy so the same request
  // works with no signal. The feed listing matters here too — caching a
  // watched video's bytes (below) is useless offline if the JSON that
  // points the feed at it can't load in the first place.
  const isCachedApi = url.pathname === "/api/messages" || /^\/api\/messages\/[\w-]+$/.test(url.pathname)
    || url.pathname === "/api/feed";
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

  // Video/photo bytes. Never written here — see cacheVideoForOffline in
  // index.html, which deliberately caches the full file (no Range) only
  // once a video has actually been watched. Serving THIS request from that
  // cache works even though it carries a Range header: browsers slice a
  // stored full 200 response to satisfy a ranged request automatically.
  if (url.pathname.startsWith("/api/media/")) {
    event.respondWith(
      fetch(req).catch(async () => {
        const cached = await caches.match(req);
        if (cached) return cached;
        throw new Error("offline");
      })
    );
  }
});

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data.json(); } catch {}

  event.waitUntil(self.registration.showNotification(data.title || "GEEREEL", {
    body: data.body || "",
    tag: data.tag || "geereel",
    renotify: false,
    data: { url: data.url || "/" },
  }));
});

// A tap focuses an already-open tab and hands it the target URL rather than
// always opening a fresh one — the app reads the URL itself and navigates.
self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = event.notification.data?.url || "/";

  event.waitUntil((async () => {
    const clientsList = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const c of clientsList) {
      if ("focus" in c) {
        c.postMessage({ type: "navigate", url });
        return c.focus();
      }
    }
    return self.clients.openWindow(url);
  })());
});
