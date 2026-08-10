/* ============================================================================
   public.js — THE "PUBLIC" PAGE, FRONTEND
   ============================================================================

   Self-contained — renders into a container you give it, needs only an auth
   token. REQUIRES the routes in public-backend.md (deployed as part of
   src/index.js).

   USAGE:
     import { mountPublic, mountCreatePost } from "./public.js";
     const stop = mountPublic(container, { token, me, onOpenUser, onOpenVideo, jumpToPostId });
     // stop() detaches the scroll listener and the video observer
     // jumpToPostId is optional — pass a post id (e.g. from a profile's
     // Public grid) to page straight to that post instead of the top/last
     // scroll position.

     mountCreatePost(container, { token, onDone });

   You can only POST a photo here — the create screen says so, and the
   backend rejects a post with no image. But the feed itself isn't
   photos-only: one video from the main "For you" pool rides in after every
   3 photo posts, muted and autoplaying as it scrolls into view, so Public
   isn't a dead end for video the way it used to be. Tapping one opens it in
   the real For You feed (via onOpenVideo); tapping its speaker just
   unmutes in place.
   ========================================================================= */

const PAGE_SIZE = 12;

const esc = (s) => String(s ?? "").replace(/[&<>"']/g,
  (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

const fmt = (n) =>
  n >= 1e6 ? (n / 1e6).toFixed(1) + "M" :
  n >= 1e3 ? (n / 1e3).toFixed(1) + "K" : String(n ?? 0);

const ago = (ts) => {
  const s = Math.floor((Date.now() - ts) / 1000);
  if (s < 60) return "now";
  if (s < 3600) return Math.floor(s / 60) + "m";
  if (s < 86400) return Math.floor(s / 3600) + "h";
  if (s < 604800) return Math.floor(s / 86400) + "d";
  return new Date(ts).toLocaleDateString(undefined, { month: "long", day: "numeric" });
};

// Turns a bare URL or WhatsApp link sitting in already-escaped caption text
// into a tappable <a>. Runs AFTER esc(), so it only ever sees the entity-
// escaped text — a link can't inject markup, it can only become one.
// wa.me / whatsapp.com matches without a scheme too, since that's how most
// people paste their own WhatsApp link, and get https:// added for the href.
const LINK_RE = /((?:https?:\/\/)?(?:wa\.me|(?:chat\.)?whatsapp\.com)\/[^\s<]+|https?:\/\/[^\s<]+)/gi;
const linkify = (escapedText) => escapedText.replace(LINK_RE, (m) => {
  const href = /^https?:\/\//i.test(m) ? m : `https://${m}`;
  return `<a class="post-link" href="${href}" target="_blank" rel="noopener noreferrer">${m}</a>`;
});

const avatarInner = (u) =>
  u?.avatarUrl
    ? `<img src="${esc(u.avatarUrl)}" alt="">`
    : esc((u?.displayName || u?.username || "?")[0].toUpperCase());

/* The verified tick. Rendered ONLY when role === 'admin'. It's a claim about
   who someone is, so it has to come from the data — never from styling. */
const tick = (u, size = 14) => u?.role === "admin"
  ? `<svg class="tick" width="${size}" height="${size}" viewBox="0 0 24 24"
       fill="currentColor" stroke="#000" stroke-width="2.2">
       <path d="M12 2l2.3 2.1 3.1-.4 1 3 2.8 1.4-1.1 2.9 1.1 2.9-2.8 1.4-1 3-3.1-.4L12 22l-2.3-2.1-3.1.4-1-3L2.8 15.9 3.9 13 2.8 10.1l2.8-1.4 1-3 3.1.4z"/>
       <path d="M8.5 12.5l2.5 2.5 4.5-5" fill="none" stroke="#fff" stroke-width="2"
             stroke-linecap="round" stroke-linejoin="round"/>
     </svg>` : "";

const ICON = {
  heart: (filled) => `<svg width="26" height="26" viewBox="0 0 24 24"
      fill="${filled ? "currentColor" : "none"}" stroke="currentColor"
      stroke-width="1.9" stroke-linejoin="round">
      <path d="M12 21s-8-4.9-8-10a4.5 4.5 0 0 1 8-2.8A4.5 4.5 0 0 1 20 11c0 5.1-8 10-8 10z"/></svg>`,
  heartSm: (filled) => `<svg width="15" height="15" viewBox="0 0 24 24"
      fill="${filled ? "currentColor" : "none"}" stroke="currentColor" stroke-width="2"
      stroke-linejoin="round">
      <path d="M12 21s-8-4.9-8-10a4.5 4.5 0 0 1 8-2.8A4.5 4.5 0 0 1 20 11c0 5.1-8 10-8 10z"/></svg>`,
  comment: `<svg width="26" height="26" viewBox="0 0 24 24" fill="none"
      stroke="currentColor" stroke-width="1.9" stroke-linejoin="round">
      <path d="M21 12a8 8 0 0 1-11.6 7.1L3 21l1.9-6.4A8 8 0 1 1 21 12z"/></svg>`,
  share: `<svg width="25" height="25" viewBox="0 0 24 24" fill="none"
      stroke="currentColor" stroke-width="1.9" stroke-linejoin="round">
      <path d="M22 2 11 13M22 2l-7 20-4-9-9-4 20-7z"/></svg>`,
  volumeOff: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none"
      stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round">
      <path d="M11 5 6 9H3v6h3l5 4z"/><path d="M23 9l-6 6M17 9l6 6"/></svg>`,
  volumeOn: `<svg width="18" height="18" viewBox="0 0 24 24" fill="none"
      stroke="currentColor" stroke-width="2" stroke-linejoin="round" stroke-linecap="round">
      <path d="M11 5 6 9H3v6h3l5 4z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/></svg>`,
};

function makeApi(token) {
  const headers = () => (token ? { Authorization: `Bearer ${token}` } : {});
  return async (path, opts = {}) => {
    const res = await fetch("/api" + path, {
      ...opts,
      headers: {
        ...headers(),
        ...(opts.body instanceof FormData ? {} : { "Content-Type": "application/json" }),
        ...opts.headers,
      },
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || "Something went wrong");
    return data;
  };
}

// Survives across mount/unmount (module scope, not mountPublic's own state)
// — leaving Public to open a video and coming back re-mounts it from
// scratch, and without this it re-mounts at the top every time instead of
// back where you were.
let savedScrollTop = 0;

/* ============================================================================
   THE FEED
   ========================================================================= */
export function mountPublic(container, { token, me, onOpenUser, onOpenVideo, jumpToPostId } = {}) {
  const api = makeApi(token);
  const state = {
    posts: [], cursor: null, loading: false, done: false, sheet: null,
    // The video side of the feed. videoPool is a queue drawn from the For
    // You feed and spent one-per-splice; videoFeed is every video actually
    // shown so far, in order — that's the list (and index) onOpenVideo
    // hands to the real For You feed, so tapping one keeps scrolling
    // through the rest exactly like tapping a video in a profile grid does.
    videoPool: [], videoFeed: [], videoCursor: null, videoDone: false, videoLoading: false,
    postsSinceVideo: 0,
  };

  container.className = "public-page";
  container.innerHTML = `<div class="public-feed" id="pub-feed"></div>`;
  const feed = container.querySelector("#pub-feed");

  // One pending "pause and nudge toward the real feed" timer per video,
  // keyed by index — armed whenever a muted video starts playing, cleared
  // the moment it stops (scrolled away) or gets unmuted.
  const watchMoreTimers = new Map();

  // Plays a video once at least half of it is on screen, pauses the moment
  // it isn't — same idea as the main feed's scroll-driven playback, just
  // simpler since Public scrolls normally instead of snapping one slide at
  // a time.
  const videoObserver = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      const video = entry.target;
      const card = video.closest("[data-vid]");
      if (entry.isIntersecting && entry.intersectionRatio >= 0.5) {
        video.play().catch(() => {});
        armWatchMore(card, video);
      } else {
        video.pause();
        if (card) clearWatchMore(card.dataset.vid);
      }
    });
  }, { threshold: [0, 0.5] });

  // Five seconds of muted autoplay is the nudge, not the video itself —
  // someone who never unmutes is scrolling past, not watching, so it pauses
  // and offers the real For You feed instead of looping silently forever.
  // Unmuting (here or in toggleMute) cancels this; it only ever fires on a
  // video that's still muted when the timer runs out.
  function armWatchMore(card, video) {
    if (!card) return;
    clearWatchMore(card.dataset.vid);
    if (!video.muted) return;
    const t = setTimeout(() => {
      if (video.muted) { video.pause(); card.classList.add("watch-more"); }
    }, 5000);
    watchMoreTimers.set(card.dataset.vid, t);
  }
  function clearWatchMore(idx) {
    const t = watchMoreTimers.get(idx);
    if (t) { clearTimeout(t); watchMoreTimers.delete(idx); }
  }

  skeletons(2);
  // A post tapped in a profile's Public grid wins over a remembered scroll
  // position — that's an explicit "take me there," not a resume.
  if (jumpToPostId) jumpToPost(jumpToPostId);
  else restore();

  // Same paging-in trick as restore() below, but keyed on finding a specific
  // post rather than reaching a pixel offset — used when a post was tapped
  // from a profile's Public grid, which only knows the post's id, not where
  // it'll land once the feed (and whatever videos interleave into it) is
  // actually built. Hidden the whole time and revealed already positioned —
  // not an animated scroll down to it, which would show every post between
  // the top and the target sweeping past, reading as the feed restarting
  // rather than "here's the post you tapped."
  async function jumpToPost(postId) {
    container.style.visibility = "hidden";
    await load();
    while (!state.done && !state.posts.some((p) => p.id === postId)) {
      await load();
    }
    const el = feed.querySelector(`[data-id="${postId}"]`);
    if (el) container.scrollTop = el.offsetTop;
    savedScrollTop = container.scrollTop;
    container.style.visibility = "";
  }

  // A plain load() always lands at the top of a freshly emptied feed. When
  // there's a remembered position (see savedScrollTop above), page posts in
  // — a fresh mount only has the first page, which usually isn't even tall
  // enough yet to reach where you were — until there's enough feed to
  // actually scroll to it, then jump straight there. Hidden while that
  // happens so it reads as "still where I was," not a visible sweep down
  // from the top through everything in between.
  async function restore() {
    if (!savedScrollTop) { load(); return; }
    container.style.visibility = "hidden";
    await load();
    while (!state.done && feed.scrollHeight < savedScrollTop + container.clientHeight) {
      await load();
    }
    container.scrollTop = Math.min(savedScrollTop, feed.scrollHeight);
    container.style.visibility = "";
  }

  function skeletons(n) {
    feed.insertAdjacentHTML("beforeend", Array.from({ length: n }, () => `
      <div class="post-sk" data-sk="1">
        <i class="sk media"></i>
        <div class="row">
          <i class="sk" style="width:64px;height:26px"></i>
          <i class="sk" style="width:64px;height:26px"></i>
          <i class="sk" style="width:64px;height:26px"></i>
        </div>
        <i class="sk line" style="width:70%"></i>
      </div>`).join(""));
  }
  const clearSk = () => feed.querySelectorAll("[data-sk]").forEach((n) => n.remove());

  // Instant first paint from whatever /api/posts last returned — same
  // stale-while-revalidate trick as the main feed's loadFeed(), and the only
  // thing Public has to show at all when opened with no connection. Reads
  // the exact cache sw.js's isCachedApi rule writes to (see the note next to
  // API_CACHE there — same coupling loadFeed() already has). Kept as its own
  // wrapper rather than merged into state.posts, since these rows are
  // provisional — the real fetch below is what actually owns state.
  async function paintFromCache() {
    if (!("caches" in window)) return;
    try {
      const cache = await caches.open("geereel-api-v1");
      const cached = await cache.match(new Request(`${location.origin}/api/posts?limit=${PAGE_SIZE}`));
      const r = cached && await cached.clone().json();
      if (r?.posts?.length) {
        clearSk();
        feed.insertAdjacentHTML("beforeend",
          `<div data-cache-preview="1">${r.posts.map(postHtml).join("")}</div>`);
      }
    } catch {}
  }

  async function load() {
    if (state.loading || state.done) return;
    state.loading = true;
    const first = !state.posts.length && !state.cursor;
    try {
      if (first) await paintFromCache();
      const q = new URLSearchParams({ limit: String(PAGE_SIZE) });
      if (state.cursor) q.set("cursor", state.cursor);
      const r = await api(`/posts?${q}`);
      clearSk();
      feed.querySelector("[data-cache-preview]")?.remove();
      state.cursor = r.nextCursor;
      if (!r.nextCursor) state.done = true;
      state.posts.push(...r.posts);
      if (!state.posts.length) {
        feed.innerHTML = `
          <div class="public-empty">
            <p>Nothing here yet</p>
            <span>Tap + to post the first photo.</span>
          </div>`;
        return;
      }
      // One video after every 3 photo posts — a running count across pages,
      // not reset per page, so a page boundary landing on a multiple of 3
      // doesn't skip a video or double one up.
      for (const p of r.posts) {
        feed.insertAdjacentHTML("beforeend", postHtml(p));
        state.postsSinceVideo++;
        if (state.postsSinceVideo >= 3) {
          state.postsSinceVideo = 0;
          const v = await nextVideo();
          if (v) {
            const idx = state.videoFeed.push(v) - 1;
            // A caption-less photo has no trailing text line, so its bottom
            // edge would otherwise land flush against the video's top edge
            // with nothing telling the two apart.
            feed.insertAdjacentHTML("beforeend", videoHtml(v, idx, !p.content));
            const el = feed.querySelector(`.pub-video[data-vid="${idx}"] video`);
            if (el) videoObserver.observe(el);
          }
        }
      }
    } catch (e) {
      clearSk();
      // Offline with nothing cached to fall back on is the only real
      // failure — offline WITH a cached preview already on screen means
      // paintFromCache() did its job, and this fetch failing is expected,
      // not something to bury that preview under an error message for.
      if (!feed.querySelector("[data-cache-preview]") && !state.posts.length) {
        feed.insertAdjacentHTML("beforeend",
          `<div class="public-empty"><p>Couldn't load posts</p><span>${esc(e.message)}</span></div>`);
      }
      state.done = true;
    } finally {
      state.loading = false;
    }
  }

  // Draws from videoPool, refilling it from the For You feed when it runs
  // dry. Returns null once that feed itself is exhausted — a post-only page
  // just keeps going without a video slotted in, rather than blocking on one.
  async function nextVideo() {
    if (!state.videoPool.length && !state.videoDone) await loadVideos();
    return state.videoPool.shift() || null;
  }

  async function loadVideos() {
    if (state.videoLoading || state.videoDone) return;
    state.videoLoading = true;
    try {
      const q = new URLSearchParams({ tab: "foryou", limit: "12" });
      if (state.videoCursor) q.set("cursor", state.videoCursor);
      const r = await api(`/feed?${q}`);
      state.videoCursor = r.nextCursor;
      if (!r.nextCursor) state.videoDone = true;
      // Ads belong to the video feed's own ad slot, not spliced into a
      // photo feed that never asked for one.
      state.videoPool.push(...r.videos.filter((v) => !v.isAd));
    } catch {
      state.videoDone = true;
    } finally {
      state.videoLoading = false;
    }
  }

  function postHtml(p) {
    // The aspect ratio is what stops the feed jumping when images load — see
    // the note in design-public.css. Older posts have no stored dimensions and
    // fall back to the CSS default rather than collapsing to zero height.
    const ratio = p.width && p.height ? ` style="aspect-ratio:${p.width} / ${p.height}"` : "";
    const cap = p.content || "";
    // A text-only post (no photo) is the whole point of the post, not a
    // caption underneath something else — it gets a much longer truncation
    // threshold and its own card treatment instead of reading like a
    // photo post that lost its photo.
    const textOnly = !p.mediaUrl;
    const truncateAt = textOnly ? 220 : 72;
    const long = cap.length > truncateAt;
    const mine = p.user.id === me?.id;
    const followBtn = mine ? "" : `
      <button class="post-follow${p.following ? " done" : ""}" data-follow="${p.user.id}">
        ${p.following ? "Following" : "Follow"}
      </button>`;
    const captionHtml = cap
      ? `${linkify(esc(long ? cap.slice(0, truncateAt) + "…" : cap))}${long ? `<button class="post-more-text" data-expand="${p.id}">more</button>` : ""}`
      : "";

    return `
      <article class="post" data-id="${p.id}">
        <div class="post-head">
          <div class="post-av" data-user="${esc(p.user.username)}">${avatarInner(p.user)}</div>
          <span class="post-user" data-user="${esc(p.user.username)}">${esc(p.user.username)}${tick(p.user)}</span>
          ${followBtn}
        </div>

        ${p.mediaUrl ? `
          <div class="post-media"${ratio}>
            <img src="${esc(p.mediaUrl)}" alt="" loading="lazy" decoding="async">
          </div>` : ""}

        ${textOnly && cap ? `
          <div class="post-text-card">
            <p class="post-text-caption" data-cap="${p.id}">${captionHtml}</p>
          </div>` : ""}

        <div class="post-actions">
          <button class="post-like${p.liked ? " on" : ""}" data-like="${p.id}">
            ${ICON.heart(p.liked)}<span class="n">${fmt(p.counts.likes)}</span>
          </button>
          <button class="post-cmt" data-open="${p.id}">
            ${ICON.comment}<span class="n">${fmt(p.counts.comments)}</span>
          </button>
          <button class="post-share" data-share="${p.id}">
            ${ICON.share}<span class="n">${fmt(p.counts.shares || 0)}</span>
          </button>
        </div>

        <div class="post-body">
          ${!textOnly && cap ? `<p class="post-caption" data-cap="${p.id}">${captionHtml}</p>` : ""}
          <p class="post-time">${ago(p.createdAt)}</p>
        </div>
      </article>`;
  }

  function videoHtml(v, idx, gapBefore) {
    // Same reserved-space trick as postHtml's ratio — without it the card
    // has no height until the poster/video loads, and the feed jumps.
    const ratio = v.width && v.height ? ` style="aspect-ratio:${v.width} / ${v.height}"` : "";
    const mine = v.user.id === me?.id;
    const followBtn = mine ? "" : `
      <button class="post-follow${v.following ? " done" : ""}" data-follow="${v.user.id}">
        ${v.following ? "Following" : "Follow"}
      </button>`;
    // src (not just data-src) with preload="none" matches the main feed's
    // slide(): the browser won't fetch bytes until play() actually runs,
    // which the IntersectionObserver only does once this card is on screen.
    return `
      <div class="pub-video-wrap${gapBefore ? " gap-before" : ""}">
        <div class="post-head">
          <div class="post-av" data-user="${esc(v.user.username)}">${avatarInner(v.user)}</div>
          <span class="post-user" data-user="${esc(v.user.username)}">${esc(v.user.username)}${tick(v.user)}</span>
          ${followBtn}
        </div>
        <div class="pub-video"${ratio} data-vid="${idx}">
          <video src="${esc(v.videoUrl)}" data-src="${esc(v.videoUrl)}"
                 ${v.thumbUrl ? `poster="${esc(v.thumbUrl)}"` : ""}
                 muted loop playsinline preload="none"></video>
          <button class="pub-vid-mute" data-mute="${idx}" aria-label="Unmute">${ICON.volumeOff}</button>
          <div class="pub-vid-watchmore"><span>Watch more videos</span></div>
        </div>
      </div>`;
  }

  /* ---------- interaction (delegated once, not per post) ---------- */
  feed.addEventListener("click", (e) => {
    const like = e.target.closest("[data-like]");   if (like)  return toggleLike(like);
    const open = e.target.closest("[data-open]");   if (open)  return openSheet(open.dataset.open);
    const shr  = e.target.closest("[data-share]");  if (shr)   return share(shr);
    const exp  = e.target.closest("[data-expand]"); if (exp)   return expandCaption(exp.dataset.expand);
    const foll = e.target.closest("[data-follow]"); if (foll)  return toggleFollow(foll);
    const mute = e.target.closest("[data-mute]");   if (mute)  return toggleMute(mute);
    const who  = e.target.closest("[data-user]");
    if (who) { if (onOpenUser) onOpenUser(who.dataset.user); return; }
    // Anywhere else on a video card — not the speaker, not the username —
    // hands off to the real For You feed, starting at this video, same as
    // tapping a thumbnail in a profile grid.
    const vidCard = e.target.closest("[data-vid]");
    if (vidCard && onOpenVideo) onOpenVideo(state.videoFeed, parseInt(vidCard.dataset.vid, 10));
  });

  function toggleMute(btn) {
    const card = btn.closest("[data-vid]");
    const video = card?.querySelector("video");
    if (!video) return;
    video.muted = !video.muted;
    btn.innerHTML = video.muted ? ICON.volumeOff : ICON.volumeOn;
    btn.classList.toggle("on", !video.muted);
    if (video.muted) {
      // Re-muting is the same as a fresh muted autoplay — the nudge gets
      // another full 5 seconds rather than firing immediately.
      armWatchMore(card, video);
    } else {
      // Turning the sound on means they're actually watching — the nudge
      // has nothing left to do here, and if it already fired, resume.
      clearWatchMore(card.dataset.vid);
      card.classList.remove("watch-more");
      video.play().catch(() => {});
    }
  }

  // Following an author updates every visible post AND video by that
  // person, not just the one tapped — the same author can show up more than
  // once as the feed pages in, across both media types.
  function syncFollow(uid, on) {
    feed.querySelectorAll(`[data-follow="${uid}"]`).forEach((b) => {
      b.classList.toggle("done", on);
      b.textContent = on ? "Following" : "Follow";
    });
    state.posts.forEach((p) => { if (p.user.id === uid) p.following = on; });
    state.videoFeed.forEach((v) => { if (v.user.id === uid) v.following = on; });
  }

  async function toggleFollow(btn) {
    const uid = btn.dataset.follow;
    const wasOn = btn.classList.contains("done");
    syncFollow(uid, !wasOn);
    try {
      await api(`/users/${uid}/follow`, { method: wasOn ? "DELETE" : "POST" });
    } catch (err) {
      syncFollow(uid, wasOn);
      toast(err.message);
    }
  }

  async function toggleLike(btn) {
    const id = btn.dataset.like;
    const wasOn = btn.classList.contains("on");
    const post = state.posts.find((p) => p.id === id);
    // Paint first so the tap feels instant, then reconcile with the server —
    // and roll back if it refuses.
    paintLike(btn, !wasOn, (post?.counts.likes ?? 0) + (wasOn ? -1 : 1));
    try {
      const r = await api(`/posts/${id}/like`, { method: wasOn ? "DELETE" : "POST" });
      if (post) { post.liked = r.liked; post.counts.likes = r.count; }
      paintLike(btn, r.liked, r.count);
    } catch (err) {
      paintLike(btn, wasOn, post?.counts.likes ?? 0);
      toast(err.message);
    }
  }
  function paintLike(btn, on, count) {
    btn.classList.toggle("on", on);
    btn.querySelector("svg").setAttribute("fill", on ? "currentColor" : "none");
    btn.querySelector(".n").textContent = fmt(count);
  }

  async function share(btn) {
    const id = btn.dataset.share;
    const url = `${location.origin}/p/${id}`;
    try {
      if (navigator.share) await navigator.share({ url });
      else { await navigator.clipboard.writeText(url); toast("Link copied"); }
    } catch { /* the person dismissed the share sheet — not an error */ }
    try {
      const r = await api(`/posts/${id}/share`, { method: "POST" });
      btn.querySelector(".n").textContent = fmt(r.count);
      const post = state.posts.find((p) => p.id === id);
      if (post) post.counts.shares = r.count;
    } catch { /* the count is cosmetic; don't nag if it fails */ }
  }

  function expandCaption(id) {
    const post = state.posts.find((p) => p.id === id);
    const el = feed.querySelector(`[data-cap="${id}"]`);
    if (!post || !el) return;
    el.innerHTML = linkify(esc(post.content));
  }

  /* ---------- comment sheet ---------- */
  async function openSheet(postId) {
    const post = state.posts.find((p) => p.id === postId);
    if (!post) return;
    closeSheet();

    // Deliberately NOT scrolling the feed behind the sheet — it opens as a
    // fixed bottom overlay exactly where it is, with nothing else on screen
    // moving. An earlier version scrolled the tapped post into view first,
    // which meant the feed visibly shifted every time comments opened —
    // exactly the motion this is avoiding.
    const backdrop = document.createElement("div");
    backdrop.className = "cmt-backdrop";
    const sheet = document.createElement("div");
    sheet.className = "cmt-sheet";
    sheet.innerHTML = `
      <div class="cmt-grab"></div>
      <div class="cmt-head">
        <span>Comments</span>
        <button class="x" aria-label="Close">&times;</button>
      </div>
      <div class="cmt-list"><i class="sk" style="width:60%;margin:16px"></i></div>
      <div class="cmt-replying" style="display:none">
        <span class="to"></span>
        <button class="cancel">Cancel</button>
      </div>
      <div class="cmt-compose">
        <div class="av">${avatarInner(me)}</div>
        <input placeholder="Add a comment..." maxlength="500">
        <button class="send">Post</button>
      </div>`;
    // Appended to <body>, not `container` — `container` (.public-page) is
    // position:absolute with its own z-index, which makes it a stacking
    // context of its own. Anything appended inside it is trapped in that
    // context for z-index purposes no matter how high a z-index it's given,
    // so the bottom nav pill (a sibling of .public-page, but stacked above
    // it) was rendering on top of the sheet's bottom edge — the "stuck
    // behind the buttons" look. Appending to <body> escapes that trap.
    document.body.appendChild(backdrop);
    document.body.appendChild(sheet);
    state.sheet = { backdrop, sheet, postId };

    backdrop.onclick = closeSheet;
    sheet.querySelector(".x").onclick = closeSheet;

    const input = sheet.querySelector("input");
    const send = sheet.querySelector(".send");
    input.oninput = () => send.classList.toggle("ready", !!input.value.trim());
    input.onkeydown = (e) => { if (e.key === "Enter") submit(); };
    send.onclick = submit;

    // Replying quotes who you're replying to above the compose box, same
    // idea as the video comment sheet — cleared on send or Cancel.
    let replyTarget = null;
    const replyBar = sheet.querySelector(".cmt-replying");
    const setReplyTarget = (t) => {
      replyTarget = t;
      if (t) {
        replyBar.style.display = "flex";
        replyBar.querySelector(".to").textContent = `Replying to @${t.username}`;
        input.placeholder = `Reply to @${t.username}...`;
        input.focus();
      } else {
        replyBar.style.display = "none";
        input.placeholder = "Add a comment...";
      }
    };
    replyBar.querySelector(".cancel").onclick = () => setReplyTarget(null);

    const list = sheet.querySelector(".cmt-list");
    list.addEventListener("click", (e) => {
      const h = e.target.closest("[data-clike]");
      if (h) return likeComment(h);
      const viewBtn = e.target.closest(".cmt-view-replies");
      if (viewBtn) {
        const repliesEl = list.querySelector(`[data-parent-list="${viewBtn.dataset.parent}"]`);
        const opening = repliesEl.style.display === "none";
        repliesEl.style.display = opening ? "block" : "none";
        viewBtn.classList.toggle("open", opening);
        return;
      }
      const replyBtn = e.target.closest(".cmt-reply");
      if (replyBtn) return setReplyTarget({ id: replyBtn.dataset.replyTo, username: replyBtn.dataset.replyUser });
    });

    try {
      const r = await api(`/posts/${postId}/comments`);
      const { topLevel, repliesByParent } = groupComments(r.comments);
      list.innerHTML = topLevel.length
        ? topLevel.map(c => commentBlockHtml(c, repliesByParent)).join("")
        : `<div class="public-empty"><p>No comments yet</p><span>Be the first.</span></div>`;
    } catch (e) {
      list.innerHTML = `<div class="public-empty"><p>Couldn't load comments</p><span>${esc(e.message)}</span></div>`;
    }

    async function submit() {
      const body = input.value.trim();
      if (!body) return;
      input.disabled = send.disabled = true;
      try {
        const r = await api(`/posts/${postId}/comments`, {
          method: "POST", body: JSON.stringify({ body, parentId: replyTarget?.id || null }),
        });
        input.value = "";
        send.classList.remove("ready");
        const parentId = replyTarget?.id;
        setReplyTarget(null);

        if (parentId) {
          // First reply to this comment — the "View replies" toggle and its
          // (initially hidden) list don't exist yet, build them now.
          let repliesEl = list.querySelector(`[data-parent-list="${parentId}"]`);
          let toggle = list.querySelector(`.cmt-view-replies[data-parent="${parentId}"]`);
          if (!repliesEl) {
            const parentRow = list.querySelector(`[data-cid="${parentId}"]`);
            parentRow?.insertAdjacentHTML("afterend", `
              <button class="cmt-view-replies open" data-parent="${parentId}">View 1 reply</button>
              <div class="cmt-replies" data-parent-list="${parentId}"></div>`);
            repliesEl = list.querySelector(`[data-parent-list="${parentId}"]`);
            toggle = list.querySelector(`.cmt-view-replies[data-parent="${parentId}"]`);
          } else {
            const count = repliesEl.children.length + 1;
            toggle.textContent = `View ${count} ${count === 1 ? "reply" : "replies"}`;
          }
          repliesEl.style.display = "block";
          toggle.classList.add("open");
          repliesEl.insertAdjacentHTML("beforeend", cmtHtml(r.comment, true));
        } else {
          const empty = list.querySelector(".public-empty");
          if (empty) list.innerHTML = "";
          list.insertAdjacentHTML("beforeend", commentBlockHtml(r.comment, new Map()));
        }
        list.scrollTop = list.scrollHeight;
        post.counts.comments = r.count;
        const n = feed.querySelector(`[data-open="${postId}"] .n`);
        if (n) n.textContent = fmt(r.count);
      } catch (e) {
        toast(e.message);
      } finally {
        input.disabled = send.disabled = false;
        input.focus();
      }
    }
  }

  // Replies stay collapsed behind a "View N replies" toggle until tapped —
  // a comment with a long reply thread otherwise pushes everything else in
  // the sheet down out of view.
  function groupComments(comments) {
    const topLevel = [];
    const repliesByParent = new Map();
    for (const c of comments) {
      if (c.parentId) {
        if (!repliesByParent.has(c.parentId)) repliesByParent.set(c.parentId, []);
        repliesByParent.get(c.parentId).push(c);
      } else {
        topLevel.push(c);
      }
    }
    return { topLevel, repliesByParent };
  }

  function commentBlockHtml(c, repliesByParent) {
    const replies = repliesByParent.get(c.id) || [];
    return cmtHtml(c) + (replies.length ? `
      <button class="cmt-view-replies" data-parent="${c.id}">View ${replies.length} ${replies.length === 1 ? "reply" : "replies"}</button>
      <div class="cmt-replies" data-parent-list="${c.id}" style="display:none">
        ${replies.map(r => cmtHtml(r, true)).join("")}
      </div>` : "");
  }

  function closeSheet() {
    if (!state.sheet) return;
    state.sheet.backdrop.remove();
    state.sheet.sheet.remove();
    state.sheet = null;
  }

  const cmtHtml = (c, isReply = false) => `
    <div class="cmt-row${isReply ? " cmt-reply-row" : ""}" data-cid="${c.id}">
      <div class="av">${avatarInner(c.user)}</div>
      <div class="cmt-main">
        <p><span class="cmt-user">${esc(c.user.username)}${tick(c.user, 13)}</span>${esc(c.body)}</p>
        <div class="cmt-meta">
          <span>${ago(c.createdAt)}</span>
          <span class="cmt-likes"${c.likes ? "" : ' hidden'}>${fmt(c.likes || 0)} ${c.likes === 1 ? "like" : "likes"}</span>
          <button class="cmt-reply" data-reply-to="${c.id}" data-reply-user="${esc(c.user.username)}">Reply</button>
        </div>
      </div>
      <button class="cmt-heart${c.liked ? " on" : ""}" data-clike="${c.id}">
        ${ICON.heartSm(c.liked)}
      </button>
    </div>`;

  async function likeComment(btn) {
    const id = btn.dataset.clike;
    const wasOn = btn.classList.contains("on");
    const row = btn.closest(".cmt-row");
    const label = row.querySelector(".cmt-likes");
    btn.classList.toggle("on", !wasOn);
    btn.querySelector("svg").setAttribute("fill", !wasOn ? "currentColor" : "none");
    try {
      const r = await api(`/posts/comments/${id}/like`, { method: wasOn ? "DELETE" : "POST" });
      label.hidden = r.count === 0;
      label.textContent = `${fmt(r.count)} ${r.count === 1 ? "like" : "likes"}`;
    } catch (e) {
      btn.classList.toggle("on", wasOn);
      btn.querySelector("svg").setAttribute("fill", wasOn ? "currentColor" : "none");
      toast(e.message);
    }
  }

  /* ---------- infinite scroll ---------- */
  const onScroll = () => {
    savedScrollTop = container.scrollTop;
    if (container.scrollTop + container.clientHeight > container.scrollHeight - 700) load();
  };
  container.addEventListener("scroll", onScroll, { passive: true });

  function toast(msg) {
    const t = document.createElement("div");
    t.className = "toast";
    t.textContent = msg;
    container.appendChild(t);
    setTimeout(() => t.remove(), 2200);
  }

  return () => {
    container.removeEventListener("scroll", onScroll);
    closeSheet();
    videoObserver.disconnect();
    watchMoreTimers.forEach((t) => clearTimeout(t));
    watchMoreTimers.clear();
  };
}

/* ============================================================================
   CREATE A POST — photos only
   ========================================================================= */
export function mountCreatePost(container, { token, onDone, initialFile } = {}) {
  const api = makeApi(token);
  let file = null, dims = null;

  container.innerHTML = `
    <div class="post-form">
      <button class="pick" id="pick">&#128206; Choose a photo</button>
      <div class="preview" id="preview" hidden>
        <img id="preview-img" alt="">
        <button class="drop" id="drop">&times;</button>
      </div>
      <div id="details" hidden>
        <textarea id="cap" placeholder="Write a caption... paste a link (like your WhatsApp) and it'll be tappable" maxlength="2000"></textarea>
        <button class="btn-primary" id="submit" style="margin-top:14px">Post</button>
      </div>
      <input type="file" id="file" accept="image/*" hidden>
      <p class="note">Public is photos only. Videos go to the main feed.</p>
    </div>`;

  const $ = (s) => container.querySelector(s);

  // accept="image/*" with no capture attribute is what hands this off to the
  // phone's own photo library picker instead of the camera or a generic file
  // browser — that chooser itself is the OS's, not something a web page can
  // replace with a custom in-page gallery grid.
  $("#pick").onclick = () => $("#file").click();
  $("#drop").onclick = () => {
    file = null; dims = null;
    $("#preview").hidden = true;
    $("#pick").hidden = false;
    $("#details").hidden = true;
  };

  const applyFile = (f) => {
    if (!/^image\//.test(f.type)) return alert("That file isn't an image");
    file = f;
    const img = $("#preview-img");
    img.src = URL.createObjectURL(f);
    // Read the real pixel dimensions so they can be sent with the post. The
    // feed uses them to reserve space before the image downloads, which is
    // what stops posts jumping as you scroll.
    img.onload = () => { dims = { w: img.naturalWidth, h: img.naturalHeight }; };
    $("#preview").hidden = false;
    $("#pick").hidden = true;
    // The caption is a response to the photo, so it has nothing to respond
    // to — and nothing to submit — until a photo is actually picked.
    $("#details").hidden = false;
  };

  $("#file").onchange = (e) => {
    const f = e.target.files?.[0];
    if (f) applyFile(f);
  };

  // A photo captured live in the camera (PHOTO mode) arrives pre-picked —
  // skip straight to the preview/caption step instead of showing the
  // "Choose a photo" button for something already chosen.
  if (initialFile) applyFile(initialFile);

  $("#submit").onclick = async () => {
    if (!file) return alert("Add a photo — this page is photos only");
    const btn = $("#submit");
    btn.disabled = true; btn.classList.add("working");
    try {
      const fd = new FormData();
      const cap = $("#cap").value.trim();
      if (cap) fd.append("content", cap);
      fd.append("image", file);
      if (dims) { fd.append("width", dims.w); fd.append("height", dims.h); }
      const r = await api("/posts", { method: "POST", body: fd });
      onDone && onDone(r.post);
    } catch (e) {
      alert(e.message);
    } finally {
      btn.disabled = false; btn.classList.remove("working");
    }
  };
}
