/* ============================================================================
   live.js — VOICE-ONLY LIVE, FRONTEND LOGIC
   ============================================================================

   Save at public/live.js. Self-contained module — renders its own markup
   into a container and doesn't assume anything about the rest of the app
   beyond a global api()-style token (see CONNECT BELOW).

   REQUIRES the backend patch in live-backend-patch.md (multi-speaker chunk
   upload/poll) and GET /api/live/mine (added alongside the fixes below).

   USAGE:
     import { mountLive } from "./live.js";
     const stop = mountLive(container, { sessionId, isHost, me, token });
     // stop() tears down the mic, sockets, and polling when the person
     // leaves the screen.

   HONEST LIMITS (say this if the person asks why voice has a delay):
     - This is NOT a phone call. Audio moves in ~2–3 second chunks uploaded
       to storage and then played back, not a live wire between phones. In
       exchange, it works over any connection — including regular mobile
       data — for free, which a direct WebRTC connection could not
       guarantee without a paid TURN relay. Expect roughly 4–6 seconds of
       delay between someone speaking and it being heard.
     - Chat and gifts travel over a normal WebSocket, so those feel
       instant — only the audio itself has the chunk delay.
   ========================================================================= */

const CHUNK_MS = 2500;          // how much audio each uploaded chunk holds
const POLL_MS = 1800;           // how often each speaker's stream is polled
const AUDIO_BITRATE = 32000;    // opus, speech-only — small files, clear voice
const MAX_GUESTS = 8;           // host + 8 guests = a 3x3 grid, matching the reference

export function mountLive(container, { sessionId, isHost, me, token, apiBase = "/api" }) {
  const state = {
    ws: null,
    participants: new Map(),   // id -> { id, username, displayName, avatarUrl, role, muted }
    speakers: new Set(),
    myRole: isHost ? "host" : "viewer",
    joinRequested: false,
    micStream: null,
    micActive: false,
    recorder: null,
    recTimer: null,
    recSeq: 0,
    // Playback: one queue + cursor per person whose audio we're pulling.
    players: new Map(),        // id -> { after, timer, queue: [], playing:false }
    ended: false,
    chatEnabled: true,
  };

  // -------------------------------------------------------------- CONNECT BELOW
  const authHeaders = () => ({ Authorization: `Bearer ${token}` });
  const apiJson = async (path, opts = {}) => {
    const res = await fetch(apiBase + path, {
      ...opts,
      headers: { ...authHeaders(), ...(opts.body instanceof FormData ? {} : { "Content-Type": "application/json" }), ...opts.headers },
    });
    if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || "Request failed");
    return res.json();
  };
  // -------------------------------------------------------------- /CONNECT

  container.innerHTML = render();
  const $ = (sel) => container.querySelector(sel);

  // ---------- rendering ----------
  function render() {
    return `
      <div class="live-topbar">
        <span class="live-badge">LIVE</span>
        <span class="live-viewers"><span id="live-vcount">1</span> watching</span>
        <button class="live-close" id="live-close-btn">&times;</button>
      </div>
      <div class="live-stage">
        <div id="live-stage-grid" style="display:grid;grid-template-columns:repeat(3,1fr);gap:16px 8px;padding:0 12px"></div>
      </div>
      <div id="live-requests"></div>
      <div class="live-chat" id="live-chat"></div>
      <div class="live-composer">
        <input class="live-input" id="live-input" placeholder="Say something..." maxlength="300">
        <button class="live-send" id="live-send-btn">&#10148;</button>
        <button class="live-mic" id="live-mic-btn">&#127908;</button>
        <button class="live-gift-btn" id="live-gift-btn">&#127873;</button>
        ${isHost ? '<button class="live-gift-btn" id="live-chattoggle-btn" title="Turn chat off/on">&#128172;</button>' : ""}
        ${isHost ? '<button class="live-close" id="live-end-btn" style="margin-left:4px">End</button>' : ""}
      </div>
    `;
  }

  function avatarHtml(p) {
    const initial = (p.displayName || p.username || "?")[0].toUpperCase();
    return p.avatarUrl ? `<img src="${p.avatarUrl}" alt="">` : initial;
  }

  // One 3x3-grid cell — the host's own seat, a guest's seat, or (for a
  // viewer who could still request one) the open "+" seat. Matches the
  // reference screenshot: avatar circle with a speaking ring, name below,
  // a small mic-off badge when muted.
  function seatTile(p, { isHostSeat = false, revokable = false } = {}) {
    const speaking = state.speakers.has(p.id) ? "on" : "";
    return `
      <div class="live-seat" data-speaker="${p.id}" style="display:flex;flex-direction:column;align-items:center;gap:5px">
        <div class="live-av-ring ${speaking}" style="position:relative;width:78px;height:78px">
          <div class="live-av" style="width:72px;height:72px;font-size:24px">${avatarHtml(p)}</div>
          ${p.muted ? '<div class="live-muted" style="width:20px;height:20px">&#128263;</div>' : ""}
          ${revokable ? `<button data-revoke="${p.id}" title="Remove" style="position:absolute;top:-2px;right:-2px;width:20px;height:20px;
            border-radius:50%;background:rgba(0,0,0,.75);color:#fff;font-size:12px;display:grid;place-items:center;border:none">&times;</button>` : ""}
        </div>
        <p class="live-name sm" style="max-width:78px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap">${escapeHtml(isHostSeat ? "Host" : (p.displayName || p.username))}</p>
      </div>
    `;
  }

  function openSeatTile() {
    return `
      <button id="live-open-seat" style="display:flex;flex-direction:column;align-items:center;gap:5px;background:none;border:none">
        <div class="live-av-ring" style="width:78px;height:78px">
          <div class="live-av" style="width:72px;height:72px;font-size:28px;opacity:.6">${state.joinRequested ? "&#8230;" : "+"}</div>
        </div>
        <p class="live-name sm" style="opacity:.7">${state.joinRequested ? "Requested" : "Join"}</p>
      </button>
    `;
  }

  // Host tile always first, then guests in the order they were approved,
  // then (only for someone who could actually tap it) one open seat.
  function renderStage() {
    const host = [...state.participants.values()].find((p) => p.role === "host") ||
      (isHost ? { id: me.id, username: me.username, displayName: me.displayName, avatarUrl: me.avatarUrl, role: "host" } : null);
    const guests = [...state.participants.values()].filter((p) => p.role === "guest");

    const tiles = [];
    if (host) tiles.push(seatTile(host, { isHostSeat: true }));
    guests.forEach((g) => tiles.push(seatTile(g, { revokable: isHost })));
    if (!isHost && state.myRole === "viewer" && guests.length < MAX_GUESTS) tiles.push(openSeatTile());

    $("#live-stage-grid").innerHTML = tiles.join("");

    container.querySelectorAll("[data-revoke]").forEach((b) =>
      b.addEventListener("click", (e) => { e.stopPropagation(); send({ type: "revoke", userId: b.dataset.revoke }); }));

    // Tapping the open seat IS the join request — same as tapping an empty
    // seat in TikTok's own multi-guest live.
    $("#live-open-seat")?.addEventListener("click", () => {
      if (state.joinRequested) return;
      state.joinRequested = true;
      send({ type: "request-join" });
      renderStage();
    });
  }

  function addChatLine(html, { sys = false } = {}) {
    const chat = $("#live-chat");
    const line = document.createElement("p");
    line.className = "live-msg" + (sys ? " sys" : "");
    line.innerHTML = html;
    chat.appendChild(line);
    // A username inside the line (real chat, not a system line) is
    // clickable — dispatched, not navigated directly, since this module
    // doesn't know the surrounding app's routing.
    const userBtn = line.querySelector("[data-username]");
    if (userBtn) userBtn.addEventListener("click", () =>
      container.dispatchEvent(new CustomEvent("live:profile-request", { detail: { username: userBtn.dataset.username } })));
    // Fade lines once there's a real backlog, so the newest few stay crisp.
    const lines = chat.querySelectorAll(".live-msg:not(.sys)");
    if (lines.length > 6) lines[lines.length - 7].classList.add("old");
    while (chat.children.length > 40) chat.removeChild(chat.firstChild);
    chat.scrollTop = chat.scrollHeight;
  }

  // A real chat message: small avatar + a tappable @username (opens their
  // profile in the surrounding app), then the message itself.
  function addUserChatLine(user, bodyHtml) {
    addChatLine(
      `<span class="live-av" style="width:18px;height:18px;font-size:9px;display:inline-grid;vertical-align:middle;margin-right:4px">${avatarHtml(user)}</span>` +
      `<button class="live-chat-user" data-username="${escapeHtml(user.username)}" style="background:none;border:none;padding:0;` +
      `color:#5AC8FA;font-weight:700;font-size:inherit;cursor:pointer;vertical-align:middle">@${escapeHtml(user.username)}</button> ${bodyHtml}`
    );
  }

  function floatGift(emoji, fromName) {
    const el = document.createElement("div");
    el.className = "live-gift-float";
    el.textContent = emoji;
    el.style.right = 18 + Math.random() * 30 + "px";
    container.appendChild(el);
    el.addEventListener("animationend", () => el.remove());
    addChatLine(`<b>${escapeHtml(fromName)}</b> sent ${emoji}`);
  }

  function renderRequests(list) {
    $("#live-requests").innerHTML = list.map((u) => `
      <div class="live-request" data-req="${u.id}">
        <div class="live-av" style="width:36px;height:36px">${avatarHtml(u)}</div>
        <span>${escapeHtml(u.displayName || u.username)} wants to join</span>
        <button class="live-req-accept" data-accept="${u.id}">Accept</button>
        <button class="live-req-decline" data-decline="${u.id}">&times;</button>
      </div>
    `).join("");
    container.querySelectorAll("[data-accept]").forEach((b) =>
      b.addEventListener("click", () => { send({ type: "approve", userId: b.dataset.accept }); dropRequest(b.dataset.accept); }));
    container.querySelectorAll("[data-decline]").forEach((b) =>
      b.addEventListener("click", () => { send({ type: "decline", userId: b.dataset.decline }); dropRequest(b.dataset.decline); }));
  }
  const pendingRequests = [];
  function dropRequest(id) {
    const i = pendingRequests.findIndex((r) => r.id === id);
    if (i >= 0) pendingRequests.splice(i, 1);
    renderRequests(pendingRequests);
  }

  function escapeHtml(s) {
    return String(s || "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  // ---------- websocket ----------
  function send(msg) {
    if (state.ws && state.ws.readyState === WebSocket.OPEN) state.ws.send(JSON.stringify(msg));
  }

  function connectSocket() {
    const proto = location.protocol === "https:" ? "wss:" : "ws:";
    const ws = new WebSocket(`${proto}//${location.host}${apiBase}/live/${sessionId}/socket?token=${encodeURIComponent(token)}`);
    state.ws = ws;

    ws.onmessage = (evt) => {
      const msg = JSON.parse(evt.data);
      switch (msg.type) {
        case "welcome":
          state.participants.set(msg.you.id, msg.you);
          msg.participants.forEach((p) => state.participants.set(p.id, p));
          renderStage();
          // Start pulling audio for the host, and for any guest already
          // on stage when we joined.
          [...state.participants.values()].filter((p) => p.role === "host" || p.role === "guest")
            .forEach((p) => startPlayback(p.id));
          break;
        case "joined":
          state.participants.set(msg.user.id, msg.user);
          addChatLine(`${escapeHtml(msg.user.displayName || msg.user.username)} joined`, { sys: true });
          renderStage();
          break;
        case "left": {
          const p = state.participants.get(msg.id);
          // The host is kept, not deleted — their tile stays put (just not
          // speaking) while briefly disconnected/reconnecting, rather than
          // the grid showing an empty slot or, worse, falling back to
          // showing whoever's own client is rendering it.
          if (p && p.role !== "host") state.participants.delete(msg.id);
          stopPlayback(msg.id);
          renderStage();
          break;
        }
        case "viewerCount":
          $("#live-vcount").textContent = msg.count;
          break;
        case "chat":
          addUserChatLine(msg.user, escapeHtml(msg.body));
          break;
        case "gift": {
          const from = msg.user.displayName || msg.user.username;
          floatGift(msg.gift.emoji, from);
          break;
        }
        case "image":
          // "Discuss image" the host posted — render it above the stage if
          // the surrounding page provides a slot for it; safe no-op otherwise.
          container.dispatchEvent(new CustomEvent("live:image", { detail: msg.url }));
          break;
        case "clearImage":
          container.dispatchEvent(new CustomEvent("live:image", { detail: null }));
          break;
        case "request-join":
          if (isHost) { pendingRequests.push(msg.user); renderRequests(pendingRequests); }
          break;
        case "approved":
          state.myRole = "guest";
          state.joinRequested = false;
          startMic();
          addChatLine("You're live — say hi!", { sys: true });
          renderStage();
          break;
        case "declined":
          state.joinRequested = false;
          addChatLine("The host didn't accept your request right now", { sys: true });
          renderStage();
          break;
        case "revoked":
          state.myRole = "viewer";
          state.joinRequested = false;
          stopMic();
          addChatLine("You're back to listening", { sys: true });
          renderStage();
          break;
        case "roleChanged": {
          const p = state.participants.get(msg.id);
          if (p) p.role = msg.role;
          if (msg.role === "guest") startPlayback(msg.id);
          if (msg.role === "viewer") stopPlayback(msg.id);
          renderStage();
          break;
        }
        case "muteState": {
          const p = state.participants.get(msg.id);
          if (p) { p.muted = msg.muted; renderStage(); }
          break;
        }
        case "speaking":
          state.speakers = new Set(msg.ids || []);
          renderStage();
          break;
        case "chatToggle": {
          state.chatEnabled = !!msg.enabled;
          const input = $("#live-input");
          input.disabled = !isHost && !state.chatEnabled;
          input.placeholder = state.chatEnabled ? "Say something..." : "The host turned off chat";
          break;
        }
        case "ended":
          state.ended = true;
          addChatLine("The host ended this live", { sys: true });
          teardown();
          container.dispatchEvent(new CustomEvent("live:ended"));
          break;
      }
    };

    ws.onclose = () => { if (!state.ended) addChatLine("Connection lost", { sys: true }); };
  }

  // ---------- chat + gifts ----------
  $("#live-send-btn").addEventListener("click", sendChat);
  $("#live-input").addEventListener("keydown", (e) => { if (e.key === "Enter") sendChat(); });
  function sendChat() {
    if (!isHost && !state.chatEnabled) return;
    const input = $("#live-input");
    const body = input.value.trim();
    if (!body) return;
    send({ type: "chat", body });
    input.value = "";
  }

  if (isHost) {
    $("#live-chattoggle-btn").addEventListener("click", (e) => {
      state.chatEnabled = !state.chatEnabled;
      e.currentTarget.style.background = state.chatEnabled ? "" : "rgba(217,31,66,.4)";
      send({ type: "chatToggle", enabled: state.chatEnabled });
    });
  }

  // The actual gift picker (coins, catalogue, balance) already exists in
  // the surrounding app — this dispatches instead of sending a fixed gift,
  // so whatever page mounts this can open its own real gift sheet. No-op if
  // nothing is listening.
  $("#live-gift-btn").addEventListener("click", () => {
    container.dispatchEvent(new CustomEvent("live:gift-request", { detail: { sessionId } }));
  });

  // ---------- mic capture (host, and any approved guest) ----------
  //
  // Recorded as a sequence of complete, independently-playable ~2.5s clips
  // (stop and start a FRESH MediaRecorder each cycle) rather than one
  // continuously-running recorder with a timeslice. This is not a style
  // preference: a running recorder's dataavailable events after the first
  // one are WebM continuation clusters, not standalone files — a fresh
  // <audio> element on the listening end can't decode them at all. Only
  // the very first chunk of a session would ever have played; every one
  // after it would silently fail, which matches "nobody can hear anybody"
  // far better than a partial fix would.
  async function startMic() {
    if (state.micStream) return;
    try {
      state.micStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      addChatLine("Microphone access is blocked — allow it in your browser settings", { sys: true });
      return;
    }
    $("#live-mic-btn").classList.add("on");
    state.micActive = true;
    state.recSeq = 0;
    recordSegment();
  }

  function recordSegment() {
    if (!state.micActive || !state.micStream) return;
    // { mimeType: "" } is not "let the browser pick" — it's invalid and
    // makes the constructor throw. Omitting the key entirely is what
    // actually means "browser default"; every iOS Safari and several
    // in-app browsers (WhatsApp's embedded one among them) support neither
    // of the two types tried here.
    const mime = ["audio/webm;codecs=opus", "audio/webm"].find((t) => MediaRecorder.isTypeSupported(t)) || "";
    let recorder;
    try {
      recorder = new MediaRecorder(state.micStream, mime
        ? { mimeType: mime, audioBitsPerSecond: AUDIO_BITRATE }
        : { audioBitsPerSecond: AUDIO_BITRATE });
    } catch {
      addChatLine("This browser can't record audio here — try Chrome or Safari directly, not an in-app browser", { sys: true });
      stopMic();
      return;
    }
    const chunks = [];
    recorder.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
    recorder.onstop = () => {
      const blob = new Blob(chunks, { type: chunks[0]?.type || mime || "audio/webm" });
      if (blob.size > 200) {
        const seq = state.recSeq++;
        const fd = new FormData();
        fd.append("chunk", blob, `${seq}.webm`);
        fd.append("seq", String(seq));
        apiJson(`/live/${sessionId}/chunk`, { method: "POST", body: fd }).catch(() => { /* drop a lost chunk rather than block */ });
      }
      if (state.micActive) recordSegment(); // next segment = a fresh, real standalone file
    };
    state.recorder = recorder;
    recorder.start();
    state.recTimer = setTimeout(() => { if (recorder.state === "recording") recorder.stop(); }, CHUNK_MS);
  }

  function stopMic() {
    state.micActive = false;
    clearTimeout(state.recTimer);
    if (state.recorder && state.recorder.state !== "inactive") state.recorder.stop();
    if (state.micStream) state.micStream.getTracks().forEach((t) => t.stop());
    state.micStream = null; state.recorder = null;
    $("#live-mic-btn").classList.remove("on");
  }

  $("#live-mic-btn").addEventListener("click", () => {
    if (!state.micStream) return; // viewers with no mic role: no-op (they request via the open seat instead)
    const track = state.micStream.getAudioTracks()[0];
    track.enabled = !track.enabled;
    $("#live-mic-btn").classList.toggle("muted", !track.enabled);
    send({ type: "muteState", muted: !track.enabled });
  });

  // ---------- playback: one poller per active speaker ----------
  function startPlayback(speakerId) {
    if (state.players.has(speakerId) || speakerId === me.id) return; // never play your own mic back
    const p = { after: -1, timer: null, queue: [], playing: false };
    state.players.set(speakerId, p);
    p.timer = setInterval(() => pollSpeaker(speakerId), POLL_MS);
    pollSpeaker(speakerId);
  }
  function stopPlayback(speakerId) {
    const p = state.players.get(speakerId);
    if (!p) return;
    clearInterval(p.timer);
    state.players.delete(speakerId);
  }
  async function pollSpeaker(speakerId) {
    const p = state.players.get(speakerId);
    if (!p) return;
    try {
      const r = await apiJson(`/live/${sessionId}/chunks?after=${p.after}&speaker=${encodeURIComponent(speakerId)}`);
      r.chunks.forEach((c) => { p.queue.push(c); p.after = c.seq; });
      playNext(speakerId);
    } catch { /* miss a poll, catch up next tick */ }
  }

  // Browsers block audio.play() from running without a real user gesture
  // behind it — a poll timer doesn't count. That rejection was previously
  // swallowed with nothing shown: every chunk would silently fail to play,
  // forever, which looks exactly like "there's no audio" with no error
  // anywhere. If that's the failure, this shows one tap-to-unlock banner;
  // once the browser has seen ANY play() succeed from a real click, it
  // keeps allowing programmatic playback for the rest of the page's life,
  // so this only ever needs to fire once per visit.
  let audioBlocked = false;
  function showUnlockBanner() {
    if (audioBlocked || $("#live-unlock-audio")) return;
    audioBlocked = true;
    const btn = document.createElement("button");
    btn.id = "live-unlock-audio";
    btn.textContent = "🔊 Tap to hear the live";
    btn.style.cssText = "position:absolute;top:64px;left:50%;transform:translateX(-50%);z-index:9;" +
      "background:var(--accent,#F5A623);color:#111;font-weight:700;font-size:13px;border:none;" +
      "border-radius:20px;padding:10px 18px;box-shadow:0 4px 16px rgba(0,0,0,.4)";
    btn.onclick = () => {
      audioBlocked = false;
      btn.remove();
      const unlock = new Audio();
      unlock.muted = true;
      unlock.play().catch(() => {}).finally(() => {
        state.players.forEach((_, id) => playNext(id));
      });
    };
    container.appendChild(btn);
  }

  function playNext(speakerId) {
    const p = state.players.get(speakerId);
    if (!p || p.playing || !p.queue.length) return;
    if (audioBlocked) return; // wait for the tap — retried from the unlock button itself
    const chunk = p.queue.shift();
    const audio = new Audio(chunk.url);
    p.playing = true;
    audio.onended = audio.onerror = () => { p.playing = false; playNext(speakerId); };
    audio.play().catch((err) => {
      p.playing = false;
      if (err?.name === "NotAllowedError") { p.queue.unshift(chunk); showUnlockBanner(); return; }
      playNext(speakerId);
    });
  }

  // ---------- lifecycle ----------
  $("#live-close-btn").addEventListener("click", teardown);
  if (isHost) $("#live-end-btn").addEventListener("click", async () => {
    try { await apiJson(`/live/${sessionId}/end`, { method: "POST" }); } catch {}
    teardown();
  });

  function teardown() {
    stopMic();
    state.players.forEach((_, id) => stopPlayback(id));
    if (state.ws) { try { state.ws.close(); } catch {} }
  }

  // ---------- start ----------
  connectSocket();
  if (isHost) startMic();
  renderStage();

  return teardown;
}
