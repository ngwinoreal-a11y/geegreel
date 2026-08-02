/* ============================================================================
   live.js — VOICE-ONLY LIVE, FRONTEND LOGIC
   ============================================================================

   FOR CLAUDE CODE:

   Save at public/live.js. This is a self-contained module — it renders its
   own markup into a container you give it and doesn't assume anything about
   the rest of the app beyond a global `api()` helper and an `apiToken`
   (adjust the two lines marked CONNECT BELOW to match however index.html
   currently authenticates requests).

   REQUIRES the backend patch in live-backend-patch.md — this file calls the
   patched shape of /chunk and /chunks (multi-speaker), not the original
   host-only shape.

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

export function mountLive(container, { sessionId, isHost, me, token, apiBase = "/api" }) {
  const state = {
    ws: null,
    participants: new Map(),   // id -> { username, displayName, avatarUrl, role, muted }
    speakers: new Set(),
    myRole: isHost ? "host" : "viewer",
    micStream: null,
    recorder: null,
    recSeq: 0,
    // Playback: one queue + cursor per person whose audio we're pulling.
    players: new Map(),        // id -> { after, timer, queue: [], playing:false, el:Audio }
    ended: false,
    chatEnabled: true,
  };

  // -------------------------------------------------------------- CONNECT BELOW
  // Adjust these two to match how the rest of the app calls the API and
  // carries the session token. Everything else in this file is independent
  // of that choice.
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
        <div class="live-host" id="live-host-slot"></div>
        <div class="live-guests" id="live-guests-slot"></div>
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

  function avatarHtml(p, size) {
    const initial = (p.displayName || p.username || "?")[0].toUpperCase();
    return p.avatarUrl
      ? `<img src="${p.avatarUrl}" alt="">`
      : initial;
  }

  function renderHost() {
    const host = [...state.participants.values()].find((p) => p.role === "host") ||
      { username: me.username, displayName: me.displayName, avatarUrl: me.avatarUrl, role: "host" };
    const speaking = state.speakers.has(host.id) ? "on" : "";
    $("#live-host-slot").innerHTML = `
      <div class="live-av-ring ${speaking}" style="position:relative">
        <div class="live-av">${avatarHtml(host)}</div>
        ${host.muted ? '<div class="live-muted">&#128263;</div>' : ""}
      </div>
      <p class="live-name">${escapeHtml(host.displayName || host.username || "Host")}</p>
    `;
  }

  function renderGuests() {
    const guests = [...state.participants.values()].filter((p) => p.role === "guest");
    $("#live-guests-slot").innerHTML = guests.map((g) => `
      <div class="live-guest">
        <div class="live-av-ring ${state.speakers.has(g.id) ? "on" : ""}" style="position:relative">
          <div class="live-av" style="width:56px;height:56px">${avatarHtml(g)}</div>
          ${g.muted ? '<div class="live-muted" style="width:18px;height:18px">&#128263;</div>' : ""}
        </div>
        <p class="live-name sm">${escapeHtml(g.displayName || g.username)}</p>
        ${isHost ? `<button class="live-req-decline" data-revoke="${g.id}" title="Remove">&times;</button>` : ""}
      </div>
    `).join("");
    container.querySelectorAll("[data-revoke]").forEach((b) =>
      b.addEventListener("click", () => send({ type: "revoke", userId: b.dataset.revoke })));
  }

  function addChatLine(html, { sys = false } = {}) {
    const chat = $("#live-chat");
    const line = document.createElement("p");
    line.className = "live-msg" + (sys ? " sys" : "");
    line.innerHTML = html;
    chat.appendChild(line);
    // Fade lines once there's a real backlog, so the newest few stay crisp.
    const lines = chat.querySelectorAll(".live-msg:not(.sys)");
    if (lines.length > 6) lines[lines.length - 7].classList.add("old");
    while (chat.children.length > 40) chat.removeChild(chat.firstChild);
    chat.scrollTop = chat.scrollHeight;
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
          renderHost(); renderGuests();
          // Start pulling audio for the host, and for any guest already
          // on stage when we joined.
          [...state.participants.values()].filter((p) => p.role === "host" || p.role === "guest")
            .forEach((p) => startPlayback(p.id));
          break;
        case "joined":
          state.participants.set(msg.user.id, msg.user);
          addChatLine(`${escapeHtml(msg.user.displayName || msg.user.username)} joined`, { sys: true });
          renderGuests();
          break;
        case "left":
          state.participants.delete(msg.id);
          stopPlayback(msg.id);
          renderHost(); renderGuests();
          break;
        case "viewerCount":
          $("#live-vcount").textContent = msg.count;
          break;
        case "chat":
          addChatLine(`<b>${escapeHtml(msg.user.displayName || msg.user.username)}</b> ${escapeHtml(msg.body)}`);
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
          startMic();
          addChatLine("You're live — say hi!", { sys: true });
          break;
        case "declined":
          addChatLine("The host didn't accept your request right now", { sys: true });
          break;
        case "revoked":
          state.myRole = "viewer";
          stopMic();
          addChatLine("You're back to listening", { sys: true });
          break;
        case "roleChanged": {
          const p = state.participants.get(msg.id);
          if (p) p.role = msg.role;
          if (msg.role === "guest") startPlayback(msg.id);
          if (msg.role === "viewer") stopPlayback(msg.id);
          renderHost(); renderGuests();
          break;
        }
        case "muteState": {
          const p = state.participants.get(msg.id);
          if (p) { p.muted = msg.muted; renderHost(); renderGuests(); }
          break;
        }
        case "speaking":
          state.speakers = new Set(msg.ids || []);
          renderHost(); renderGuests();
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
  async function startMic() {
    if (state.micStream) return;
    try {
      state.micStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      addChatLine("Microphone access is blocked — allow it in your browser settings", { sys: true });
      return;
    }
    $("#live-mic-btn").classList.add("on");
    const mime = ["audio/webm;codecs=opus", "audio/webm"].find((t) => MediaRecorder.isTypeSupported(t)) || "";
    state.recorder = new MediaRecorder(state.micStream, { mimeType: mime, audioBitsPerSecond: AUDIO_BITRATE });
    state.recSeq = 0;
    state.recorder.ondataavailable = async (e) => {
      if (!e.data || !e.data.size) return;
      const seq = state.recSeq++;
      const fd = new FormData();
      fd.append("chunk", e.data, `${seq}.webm`);
      fd.append("seq", String(seq));
      try { await apiJson(`/live/${sessionId}/chunk`, { method: "POST", body: fd }); } catch { /* drop a lost chunk rather than block */ }
    };
    state.recorder.start(CHUNK_MS);
  }
  function stopMic() {
    if (state.recorder && state.recorder.state !== "inactive") state.recorder.stop();
    if (state.micStream) state.micStream.getTracks().forEach((t) => t.stop());
    state.micStream = null; state.recorder = null;
    $("#live-mic-btn").classList.remove("on");
  }

  $("#live-mic-btn").addEventListener("click", () => {
    if (!state.micStream) return; // viewers with no mic role: no-op
    const track = state.micStream.getAudioTracks()[0];
    track.enabled = !track.enabled;
    $("#live-mic-btn").classList.toggle("muted", !track.enabled);
    send({ type: "muteState", muted: !track.enabled });
  });

  // A viewer taps the mic button to ask to speak; a host or already-approved
  // guest instead toggles mute (handled above).
  if (!isHost) {
    $("#live-mic-btn").addEventListener("click", () => {
      if (state.myRole === "viewer") send({ type: "request-join" });
    }, { once: false });
  }

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
  function playNext(speakerId) {
    const p = state.players.get(speakerId);
    if (!p || p.playing || !p.queue.length) return;
    const chunk = p.queue.shift();
    const audio = new Audio(chunk.url);
    p.playing = true;
    audio.onended = audio.onerror = () => { p.playing = false; playNext(speakerId); };
    audio.play().catch(() => { p.playing = false; playNext(speakerId); });
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
  renderHost(); renderGuests();

  return teardown;
}
