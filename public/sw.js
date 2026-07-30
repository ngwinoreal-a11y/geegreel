// Push notifications only — this app has no offline/asset-caching strategy,
// so the service worker's only job is showing a push and routing the tap.

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
