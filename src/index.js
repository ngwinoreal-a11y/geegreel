// Video app API — Cloudflare Worker
// Bindings: DB (D1), MEDIA (R2)

// Belo Flow — Belople's own recommendation engine (see src/belo_flow.js).
import {
  buildBeloFeed, recordExposure, loadConfig, mergeConfig, DEFAULT_CONFIG,
  markExposureSignal, markCreatorFollowed,
} from "./belo_flow.js";

// Live video. src/mux.js is the ONLY file that knows the provider's name — if
// Mux is ever replaced, that file is what gets rewritten and comments, likes,
// follows, notifications and discovery are untouched.
import {
  createLiveStream, completeLiveStream, deleteLiveStream, deleteAsset,
  verifyWebhook, playbackUrl, maxLiveSeconds,
} from "./mux.js";

const JSON_HEADERS = { "Content-Type": "application/json" };

const json = (data, status = 200, extra = {}) =>
  new Response(JSON.stringify(data), { status, headers: { ...JSON_HEADERS, ...extra } });

const err = (message, status = 400) => json({ error: message }, status);

const uid = () => crypto.randomUUID();
const now = () => Date.now();
const round3 = (x) => (x == null || isNaN(x) ? 0 : Math.round(x * 1000) / 1000);

// ---------- password hashing (PBKDF2, 100k iterations) ----------

async function hashPassword(password, saltHex) {
  const salt = saltHex
    ? Uint8Array.from(saltHex.match(/.{2}/g).map(b => parseInt(b, 16)))
    : crypto.getRandomValues(new Uint8Array(16));

  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(password), "PBKDF2", false, ["deriveBits"]
  );
  const bits = await crypto.subtle.deriveBits(
    { name: "PBKDF2", salt, iterations: 100000, hash: "SHA-256" }, key, 256
  );

  const toHex = buf => [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
  return `${toHex(salt)}:${toHex(bits)}`;
}

async function verifyPassword(password, stored) {
  const [saltHex] = stored.split(":");
  const candidate = await hashPassword(password, saltHex);
  // constant-time-ish compare
  if (candidate.length !== stored.length) return false;
  let diff = 0;
  for (let i = 0; i < candidate.length; i++) diff |= candidate.charCodeAt(i) ^ stored.charCodeAt(i);
  return diff === 0;
}

// A repost points at an existing video rather than duplicating its file —
// engagement (likes, comments, shares, gifts) belongs to that underlying
// content, not the repost row, so resharing something already popular
// doesn't reset it to zero. Every action route resolves the id it's given
// through this before touching likes/comments/shares/gifts, so liking or
// commenting on a repost really acts on the original, and a gift's payout
// reaches the actual creator rather than whoever reposted it.
// repostVideo() (below) always sets repost_of to a true original, never to
// another repost, so one hop here is always enough — no chain to walk.
async function resolveContentId(env, videoId) {
  const row = await env.DB.prepare("SELECT repost_of FROM videos WHERE id = ?").bind(videoId).first();
  return row?.repost_of || videoId;
}

// Message requests: the first message between two people who've never
// talked creates a pending conversation_status row. The sender can't send
// a second message until either the recipient replies (which accepts it
// implicitly) or explicitly accepts/declines from the inbox. pairKey()
// keeps the two people's ids in a fixed order so both directions of a
// conversation land on the same row.
const pairKey = (a, b) => a < b ? [a, b] : [b, a];

async function getConversationStatus(env, userA, userB) {
  const [a, b] = pairKey(userA, userB);
  return env.DB.prepare(
    "SELECT * FROM conversation_status WHERE user_a = ? AND user_b = ?"
  ).bind(a, b).first();
}

// Shared by every "send something into a DM" route (text, image, voice
// note) — checks blocks, then the message-request state, updating it if
// this send is what accepts a pending request. Throws HttpError to reject;
// callers don't need their own try/catch, the outer handler already turns
// a thrown HttpError into the right response.
async function applyConversationGate(env, senderId, recipientId) {
  if (senderId === recipientId) return;

  const blocked = await env.DB.prepare(
    "SELECT 1 FROM blocks WHERE (blocker_id = ? AND blocked_id = ?) OR (blocker_id = ? AND blocked_id = ?)"
  ).bind(senderId, recipientId, recipientId, senderId).first();
  if (blocked) throw new HttpError("You can't message this person", 403);

  const convo = await getConversationStatus(env, senderId, recipientId);
  if (!convo) {
    const [a, b] = pairKey(senderId, recipientId);
    await env.DB.prepare(
      "INSERT INTO conversation_status (user_a, user_b, requested_by, status, created_at) VALUES (?, ?, ?, 'pending', ?)"
    ).bind(a, b, senderId, now()).run();
  } else if (convo.status === "pending") {
    if (convo.requested_by === senderId) {
      throw new HttpError("You've already sent a message request — you can send more once they reply", 409);
    }
    await env.DB.prepare(
      "UPDATE conversation_status SET status = 'accepted' WHERE user_a = ? AND user_b = ?"
    ).bind(...pairKey(senderId, recipientId)).run();
  } else if (convo.status === "declined") {
    throw new HttpError("This person isn't accepting messages from you", 403);
  }
}

// The "who can message you" setting, shared by every send-a-DM route —
// enforced here, not just decoration in the settings screen.
async function checkMessagePermission(env, senderId, them) {
  if (them.status === "banned") throw new HttpError("That account is banned", 403);
  if (them.id === senderId) return;
  const pref = them.allow_messages || "everyone";
  if (pref === "nobody") throw new HttpError("This person isn't accepting messages", 403);
  if (pref === "followers") {
    const follows = await env.DB.prepare(
      "SELECT 1 FROM follows WHERE follower_id = ? AND followee_id = ? AND status = 'accepted'"
    ).bind(them.id, senderId).first();
    if (!follows) throw new HttpError("Only people they follow can message them", 403);
  }
}

// ---------- sessions ----------

const SESSION_TTL = 1000 * 60 * 60 * 24 * 30; // 30 days

async function createSession(env, userId) {
  const token = uid() + uid().replace(/-/g, "");
  await env.DB.prepare(
    "INSERT INTO sessions (token, user_id, created_at, expires_at) VALUES (?, ?, ?, ?)"
  ).bind(token, userId, now(), now() + SESSION_TTL).run();
  return token;
}

async function getUser(request, env) {
  const auth = request.headers.get("Authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7) : null;
  if (!token) return null;
  return getUserByToken(env, token);
}

// Split out of getUser: a WebSocket handshake from a browser can't carry a
// custom Authorization header (the WebSocket constructor has no headers
// option), so the live socket route reads the same session token off a
// ?token= query param instead and needs this without the header parsing.
async function getUserByToken(env, token) {
  if (!token) return null;

  const row = await env.DB.prepare(`
    SELECT u.* FROM sessions s
    JOIN users u ON u.id = s.user_id
    WHERE s.token = ? AND s.expires_at > ?
  `).bind(token, now()).first();

  if (!row) return null;

  // A ban has to bite straight away — otherwise the offender keeps posting
  // until their month-long session happens to expire.
  if (row.status === "banned") {
    throw new HttpError(row.banned_reason || "This account has been banned", 403);
  }

  return row;
}

function requireUser(user) {
  if (!user) throw new HttpError("Not authenticated", 401);
  return user;
}

class HttpError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}

// ---------- roles, monetization rules ----------

// Thresholds for applying. Change these in one place, not scattered in checks.
const MONETIZE_RULES = {
  followers: 10000,
  likes: 10000,
  videos: 5,
};

// What a view is worth. 1000 views = $0.02 is in the ballpark of what short-form
// platforms actually pay; adjust once you know your real ad revenue.
const CENTS_PER_1K_VIEWS = 2;
const MIN_PAYOUT_CENTS = 1000; // $10 — don't queue payouts smaller than the fee

/// Nothing is taken off a cash-out. Belople's share is already taken once, at
/// the gift — 40% of it — and charging again on the way out would be charging
/// twice for the same money. Left as a named constant so the decision is
/// visible rather than absent.
const PAYOUT_FEE_PERCENT = 0;

// ---------- gifts and coins ----------
//
// Two currencies, deliberately:
//   coins  — what a viewer buys and spends. No cash value going out.
//   cents  — what a creator receives and can withdraw.
// They're separate so a creator can't buy coins, gift themselves, and cash out
// the same money in a loop.

const COIN_PRICE_CENTS = 1;          // 1 coin costs $0.01 to buy

/// The creator keeps 50% of a gift's value; Belople keeps 50%.
///
/// Was 60%, lowered once the running costs were counted: storage and
/// bandwidth for every video ever uploaded, and live streaming through Mux,
/// all come out of Belople's half and none of it out of the creator's. 60%
/// left too little to carry that.
///
/// Still the number to say out loud, and still well ahead of the field. On
/// TikTok a creator nets roughly 20-30% of what the viewer actually paid (the
/// store takes 30%, then the coin-to-diamond conversion takes about half of
/// the rest) — and the figure is buried, so creators only discover it when
/// they try to withdraw. Saying "you keep half" plainly, before anyone earns
/// anything, is the whole difference between a rate and a grievance.
///
/// $10 of coins bought on the web: $5 to the creator, $5 to Belople. If Play
/// Billing is ever added, a $10 purchase through it nets $8.50, so the same
/// 50% leaves $3.50. Revisit this number then, not before.
const CREATOR_SHARE = 0.5;

// Nothing below 2 coins: a 1-coin gift floors to zero for the creator — the
// viewer pays and the creator gets nothing, which is indefensible.
// The prices the app shows AND the prices it charges. `giftByKey` takes the
// first match, so a duplicated key silently decides the price — `rose` was in
// here twice, at 2 and at 5, and the 2 won. The app showed 5, the server took
// 2, and the creator was paid on the 2. Five gifts went out that way before
// anyone could see it, which is why assertUniqueGiftKeys() below now refuses
// to let a duplicate exist at all.
const GIFTS = [
  { key: "heart",     name: "Heart",       coins: 2,      emoji: "❤️" },
  { key: "rose",      name: "Rose",        coins: 5,      emoji: "🌹" },
  { key: "star",      name: "Star",        coins: 10,     emoji: "⭐" },
  { key: "clap",      name: "Applause",    coins: 20,     emoji: "👏" },
  { key: "fire",      name: "Fire",        coins: 30,     emoji: "🔥" },
  { key: "crown",     name: "Crown",       coins: 50,     emoji: "👑" },
  { key: "diamond",   name: "Diamond",     coins: 100,    emoji: "💎" },
  { key: "cake",      name: "Cake",        coins: 200,    emoji: "🎂" },
  { key: "rocket",    name: "Rocket",      coins: 500,    emoji: "🚀" },
  { key: "trophy",    name: "Trophy",      coins: 1000,   emoji: "🏆" },
  // The house gift: Belople's own mark, priced where a serious supporter
  // lands (~$20). It's the one gift that says which app you're on.
  { key: "belople",   name: "Belople",     coins: 2000,   emoji: "⚡", brand: true },
  { key: "car",       name: "Car",         coins: 5000,   emoji: "🚗" },
  { key: "ring",      name: "Ring",        coins: 10000,  emoji: "💍" },
  { key: "yacht",     name: "Yacht",       coins: 30000,  emoji: "🛥️" },
  { key: "jet",       name: "Jet",         coins: 40000,  emoji: "✈️" },
  { key: "castle",    name: "Castle",      coins: 50000,  emoji: "🏰" },
  { key: "island",    name: "Island",      coins: 100000, emoji: "🏝️" },
  { key: "galaxy",    name: "Galaxy",      coins: 200000, emoji: "🌌" },
  { key: "universe",  name: "Universe",    coins: 500000, emoji: "🌠" },
];

// 1 coin = 1 cent (COIN_PRICE_CENTS), so cents == coins for every pack. The
// range runs to $500 because the old ceiling of $50 capped what a supporter
// could give in one go — the big gifts (Rocket, Trophy) were unreachable
// without repeat purchases.
const COIN_PACKS = [
  { coins: 100,    cents: 100 },    // $1
  { coins: 500,    cents: 500 },    // $5
  { coins: 1000,   cents: 1000 },   // $10
  { coins: 2500,   cents: 2500 },   // $25
  { coins: 5000,   cents: 5000 },   // $50
  { coins: 10000,  cents: 10000 },  // $100
  { coins: 20000,  cents: 20000 },  // $200
  { coins: 50000,  cents: 50000 },  // $500
];

/// Refuses to start with two gifts sharing a key.
///
/// This is deliberately loud and deliberately at module load. A duplicate does
/// not break anything visibly — it just quietly makes one of the two prices
/// unreachable, and the one that wins is whichever was typed first. That is
/// how Rose came to be shown at 5 and charged at 2 for weeks. A price the code
/// can't reach is worse than a crash, because a crash gets noticed.
function assertUniqueGiftKeys(gifts) {
  const seen = new Set();
  const dupes = [];
  for (const g of gifts) {
    if (seen.has(g.key)) dupes.push(g.key);
    seen.add(g.key);
  }
  if (dupes.length) {
    throw new Error(
      `GIFTS has duplicate keys: ${[...new Set(dupes)].join(", ")}. ` +
      "giftByKey takes the first match, so the later price would never be charged."
    );
  }
  return gifts;
}
assertUniqueGiftKeys(GIFTS);

const giftByKey = k => GIFTS.find(g => g.key === k);

// Every balance change is written to wallet_tx alongside the balance it
// produced. If the numbers are ever questioned, the ledger is the answer.
async function recordTx(env, userId, kind, coinsDelta, centsDelta, balCoins, balCents, refId, note) {
  await env.DB.prepare(`
    INSERT INTO wallet_tx (id, user_id, kind, coins_delta, cents_delta,
                           balance_coins_after, balance_cents_after, ref_id, note, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
  `).bind(uid(), userId, kind, coinsDelta, centsDelta, balCoins, balCents,
          refId || null, note || null, now()).run();
}

const isAdmin = u => u?.role === "admin";
const isStaff = u => u?.role === "admin" || u?.role === "moderator";

function requireAdmin(user) {
  requireUser(user);
  if (!isAdmin(user)) throw new HttpError("Admins only", 403);
  return user;
}

function requireStaff(user) {
  requireUser(user);
  if (!isStaff(user)) throw new HttpError("Moderators only", 403);
  return user;
}

// Every admin action is written down. Without this you can't answer "who
// banned this account and why" three months later.
async function logAdmin(env, adminId, action, targetType, targetId, note) {
  await env.DB.prepare(`
    INSERT INTO admin_log (id, admin_id, action, target_type, target_id, note, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `).bind(uid(), adminId, action, targetType || null, targetId || null, note || null, now()).run();
}

// ---------- notifications + web push ----------
//
// Two halves: a `notifications` row (the in-app inbox, always written) and,
// best-effort, a native push (RFC 8291 message encryption + RFC 8292 VAPID)
// so a like/comment/follow/gift can surface even with the app closed.

const b64urlToBytes = (s) => {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
};
const bytesToB64url = (bytes) => {
  let bin = "";
  const arr = new Uint8Array(bytes);
  for (let i = 0; i < arr.length; i++) bin += String.fromCharCode(arr[i]);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

const te = new TextEncoder();

function concatBytes(...arrs) {
  const total = arrs.reduce((n, a) => n + a.length, 0);
  const out = new Uint8Array(total);
  let off = 0;
  for (const a of arrs) { out.set(a, off); off += a.length; }
  return out;
}

async function hmacSha256(keyBytes, dataBytes) {
  const key = await crypto.subtle.importKey("raw", keyBytes, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  return new Uint8Array(await crypto.subtle.sign("HMAC", key, dataBytes));
}

// A short-lived JWT that identifies this server to the push service, signed
// with the VAPID private key. One per request, scoped to that endpoint's origin.
async function vapidHeader(env, endpoint) {
  // The secret was saved with a leading UTF-8 BOM at some point — JSON.parse
  // rejects that byte outright, which silently killed every single push send
  // from day one (an empty catch{} upstream hid the SyntaxError). Stripping
  // it here is robust regardless of how the secret gets re-set in the future.
  const jwk = JSON.parse(env.VAPID_PRIVATE_JWK.replace(/^﻿/, ""));
  const key = await crypto.subtle.importKey("jwk", jwk, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const aud = new URL(endpoint).origin;
  const header = bytesToB64url(te.encode(JSON.stringify({ typ: "JWT", alg: "ES256" })));
  const payload = bytesToB64url(te.encode(JSON.stringify({
    aud, exp: Math.floor(Date.now() / 1000) + 12 * 3600, sub: env.VAPID_SUBJECT,
  })));
  // WebCrypto's ECDSA signature is already raw r||s (IEEE P1363) — exactly
  // what a JWS expects, no DER conversion needed.
  const sig = new Uint8Array(await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, te.encode(`${header}.${payload}`)
  ));
  return `vapid t=${header}.${payload}.${bytesToB64url(sig)}, k=${env.VAPID_PUBLIC_KEY}`;
}

// Encrypts one payload for one subscription per RFC 8291 (aes128gcm content
// coding): ECDH with the browser's subscription key, double HKDF to derive a
// content-encryption key and nonce, then AES-128-GCM.
async function encryptPushPayload(subscription, payloadObj) {
  const plaintext = te.encode(JSON.stringify(payloadObj));
  const uaPublicRaw = b64urlToBytes(subscription.p256dh);
  const authSecret = b64urlToBytes(subscription.auth);

  const uaPublicKey = await crypto.subtle.importKey("raw", uaPublicRaw, { name: "ECDH", namedCurve: "P-256" }, false, []);
  const serverKeyPair = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, true, ["deriveBits"]);
  const asPublicRaw = new Uint8Array(await crypto.subtle.exportKey("raw", serverKeyPair.publicKey));

  const ecdhSecret = new Uint8Array(await crypto.subtle.deriveBits(
    { name: "ECDH", public: uaPublicKey }, serverKeyPair.privateKey, 256
  ));

  const prkKey = await hmacSha256(authSecret, ecdhSecret);
  const keyInfo = concatBytes(te.encode("WebPush: info\0"), uaPublicRaw, asPublicRaw);
  const ikm = (await hmacSha256(prkKey, concatBytes(keyInfo, new Uint8Array([1])))).slice(0, 32);

  const salt = crypto.getRandomValues(new Uint8Array(16));
  const prk = await hmacSha256(salt, ikm);

  const cek = (await hmacSha256(prk, concatBytes(te.encode("Content-Encoding: aes128gcm\0"), new Uint8Array([1])))).slice(0, 16);
  const nonce = (await hmacSha256(prk, concatBytes(te.encode("Content-Encoding: nonce\0"), new Uint8Array([1])))).slice(0, 12);

  const aesKey = await crypto.subtle.importKey("raw", cek, "AES-GCM", false, ["encrypt"]);
  // Delimiter octet 0x02 marks this as the final (only) record — no padding.
  const ciphertext = new Uint8Array(await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce }, aesKey, concatBytes(plaintext, new Uint8Array([2]))
  ));

  const recordSize = new Uint8Array(4);
  new DataView(recordSize.buffer).setUint32(0, 4096);

  return concatBytes(salt, recordSize, new Uint8Array([asPublicRaw.length]), asPublicRaw, ciphertext);
}

// Best-effort by design: a push failing never fails the like/comment/follow
// that triggered it, and a subscription the browser has abandoned (404/410)
// is quietly dropped rather than retried forever.
async function sendPush(env, userId, payloadObj) {
  if (!env.VAPID_PRIVATE_JWK) return;
  const { results: subs } = await env.DB.prepare(
    "SELECT * FROM push_subscriptions WHERE user_id = ?"
  ).bind(userId).all();
  if (!subs.length) return;

  await Promise.all(subs.map(async (sub) => {
    try {
      const body = await encryptPushPayload(sub, payloadObj);
      const authHeader = await vapidHeader(env, sub.endpoint);
      const res = await fetch(sub.endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/octet-stream",
          "Content-Encoding": "aes128gcm",
          // A 60s TTL meant FCM silently dropped the message rather than
          // queuing it for later if the device wasn't reachable at that
          // exact instant (screen off, Android Doze mode) — the server saw
          // a clean 201 either way, so this looked like success while the
          // notification just never arrived. 4 weeks is the practical max
          // that's still useful; Urgency: high asks FCM to prioritize
          // waking the device rather than batching it with low-priority
          // traffic, which matters specifically because of Doze/App
          // Standby throttling non-urgent push on Android.
          "TTL": "2419200",
          "Urgency": "high",
          "Authorization": authHeader,
        },
        body,
      });
      if (res.status === 404 || res.status === 410) {
        await env.DB.prepare("DELETE FROM push_subscriptions WHERE id = ?").bind(sub.id).run();
      } else if (!res.ok) {
        // Was silently swallowed before — logged now (temporary, while
        // diagnosing why nothing arrives) so `wrangler tail` actually shows
        // what the push service objected to instead of nothing at all.
        console.error("push failed", res.status, await res.text().catch(() => ""), sub.endpoint.slice(0, 60));
      }
    } catch (e) {
      console.error("push threw", e?.message || e);
    }
  }));
}

// ---------------------------------------------------------------------------
// FCM (native app push).
//
// Web Push above reaches BROWSERS. An installed Android app can only be woken
// through Firebase Cloud Messaging, so the native app registers an FCM token
// (POST /api/push/device) and we deliver to it here via the HTTP v1 API.
// Authentication is a service-account JWT exchanged for an OAuth2 access
// token — FCM_SERVICE_ACCOUNT holds the key JSON from the Firebase console.
// ---------------------------------------------------------------------------

// Access tokens last an hour; a Worker isolate outlives many requests, so
// caching one here avoids a token round-trip on every single notification.
let fcmTokenCache = { token: null, expiresAt: 0 };

function serviceAccount(env) {
  if (!env.FCM_SERVICE_ACCOUNT) return null;
  try {
    // Same BOM guard as VAPID_PRIVATE_JWK: a secret pasted from a file can
    // carry a leading U+FEFF, and JSON.parse rejects it outright.
    return JSON.parse(env.FCM_SERVICE_ACCOUNT.replace(/^﻿/, ""));
  } catch (e) {
    console.error("FCM_SERVICE_ACCOUNT is not valid JSON:", e?.message || e);
    return null;
  }
}

// PEM (PKCS#8) -> CryptoKey for RS256 signing.
async function importServiceAccountKey(pem) {
  const body = pem
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8", der,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false, ["sign"]
  );
}

async function fcmAccessToken(env) {
  const nowSec = Math.floor(Date.now() / 1000);
  // 60s of slack so a token can't expire mid-flight.
  if (fcmTokenCache.token && fcmTokenCache.expiresAt > nowSec + 60) return fcmTokenCache.token;

  const sa = serviceAccount(env);
  if (!sa?.private_key || !sa?.client_email) return null;

  const key = await importServiceAccountKey(sa.private_key);
  const header = bytesToB64url(te.encode(JSON.stringify({ alg: "RS256", typ: "JWT" })));
  const claims = bytesToB64url(te.encode(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: sa.token_uri || "https://oauth2.googleapis.com/token",
    iat: nowSec,
    exp: nowSec + 3600,
  })));
  const sig = new Uint8Array(await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5", key, te.encode(`${header}.${claims}`)
  ));
  const assertion = `${header}.${claims}.${bytesToB64url(sig)}`;

  const res = await fetch(sa.token_uri || "https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion,
    }),
  });
  if (!res.ok) {
    console.error("FCM token exchange failed", res.status, await res.text().catch(() => ""));
    return null;
  }
  const data = await res.json();
  fcmTokenCache = { token: data.access_token, expiresAt: nowSec + (data.expires_in || 3600) };
  return fcmTokenCache.token;
}

// Delivers one notification to every native device registered to a user.
//
// DATA-ONLY on purpose. If the message carried a `notification` block, Android
// would draw it itself — and the system's own rendering has no way to show the
// actor's photo or an action button; FCM's schema has no field for either. By
// sending the pieces as data and letting PushService build the notification,
// the app controls the large icon, the actions and where a tap lands. The
// trade-off is that the app must be woken to draw it, which is what
// priority HIGH and the background isolate handler are for.
async function sendFcm(env, userId, { title, body, url, tag, route, type, avatar, actorName, image }) {
  const sa = serviceAccount(env);
  if (!sa?.project_id) return; // not configured — web push still runs

  let devices = [];
  try {
    ({ results: devices } = await env.DB.prepare(
      "SELECT token FROM fcm_devices WHERE user_id = ?"
    ).bind(userId).all());
  } catch (_) { return; } // table not migrated yet
  if (!devices.length) return;

  const accessToken = await fcmAccessToken(env);
  if (!accessToken) return;

  const endpoint = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
  await Promise.all(devices.map(async (d) => {
    try {
      const res = await fetch(endpoint, {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          message: {
            token: d.token,
            // Every value must be a string — FCM rejects the message otherwise.
            data: {
              title: title || "Belople",
              body: body || "",
              route: route || "/",
              url: url || "/",
              tag: tag || "",
              type: type || "",
              avatar: avatar || "",
              actor: actorName || "",
              // The video's poster, shown large when the notification is
              // expanded. A like or comment means little until you can see
              // WHICH of your videos it landed on.
              image: image || "",
            },
            android: {
              // AndroidMessagePriority is an enum: "HIGH"/"NORMAL". Lowercase
              // risks an INVALID_ARGUMENT rejection of the whole message.
              // HIGH also lets a data message wake the app under Doze, which a
              // normal-priority one would be held back from doing.
              priority: "HIGH",
            },
          },
        }),
      });
      if (res.ok) return;
      const text = await res.text().catch(() => "");
      // ONLY UNREGISTERED means a dead token. INVALID_ARGUMENT usually means a
      // malformed payload — deleting the token for that would quietly
      // unsubscribe a perfectly good device for a bug on our side.
      if (res.status === 404 || /UNREGISTERED/.test(text)) {
        await env.DB.prepare("DELETE FROM fcm_devices WHERE token = ?").bind(d.token).run();
      }
      console.error("fcm failed", res.status, text.slice(0, 300));
    } catch (e) {
      console.error("fcm threw", e?.message || e);
    }
  }));
}

const NOTIF_TEXT = {
  like: (name) => [`${name} liked your video`, ""],
  comment: (name, text) => [`${name} commented`, text || ""],
  reply: (name, text) => [`${name} replied to your comment`, text || ""],
  follow: (name) => [`${name} started following you`, ""],
  gift: (name) => [`${name} sent you a gift`, ""],
  repost: (name) => [`${name} reposted your video`, ""],
  post: (name, caption) => [`${name} posted a new video`, caption || "Tap to watch"],
  // From Belople itself, not a person — so it doesn't read "@admin says".
  announcement: (_name, text) => ["Belople", text || ""],
  message: (name, text) => [name, text || "Sent you a message"],
  ad_approved: () => ["Your ad is live", "It's now being shown to people."],
  ad_rejected: () => ["Your ad wasn't approved", "It didn't meet the guidelines."],
  ad_complete: () => ["Your ad finished", "It reached everyone it was paid for."],
  // From Belople, about the poster's OWN video — they need to know it's gone
  // and why, or it just silently disappears from their profile.
  video_removed: (_name, reason) =>
    ["Your video was removed", reason ? `Reported for ${reason}.` : "It broke the community guidelines."],
};

// Writes the in-app notification (always) and fires a push (best-effort),
// respecting the recipient's existing notify_* toggles — gifts are the one
// exception, since money landing on your video shouldn't be optional.
// Absolute base for URLs that leave the Worker and get fetched by something
// else — notably the avatar the phone downloads to draw a notification, which
// has no request context to resolve a relative path against.
const PUBLIC_ORIGIN = "https://www.belople.com";

// The link-preview fetchers. Matched on user agent because that is the only
// thing distinguishing them from a browser — they request the same URL. Kept
// deliberately narrow: a false positive would serve a real person a blank
// redirect page instead of the app.
const CRAWLER_UA = /whatsapp|facebookexternalhit|facebot|twitterbot|telegrambot|slackbot|discordbot|linkedinbot|skypeuripreview|pinterest|redditbot|embedly|vkshare|tiktok|bingbot|googlebot|applebot|iframely|quora link preview|nuzzel|outbrain|w3c_validator/i;

const isCrawler = (request) => CRAWLER_UA.test(request.headers.get("User-Agent") || "");

async function notify(env, ctx, userId, actorId, type, extra = {}) {
  // ad_* are account notifications about your OWN ad, so a self-target is
  // allowed there (ad_complete has no other actor); everything else blocks it.
  if (!userId) return;
  if (userId === actorId && !type.startsWith("ad_")) return;
  const recipient = await env.DB.prepare(
    "SELECT notify_likes, notify_comments, notify_follows FROM users WHERE id = ?"
  ).bind(userId).first();
  if (!recipient) return;

  const pref = type.startsWith("ad_") ? 1 // ad approval/rejection/completion always notifies
             : type === "follow" ? recipient.notify_follows
             // A new video from someone you chose to follow belongs to the
             // follows toggle, not the comments one.
             : type === "post" ? recipient.notify_follows
             : type === "like" || type === "repost" ? recipient.notify_likes
             // Gifts and direct messages are addressed to you personally —
             // silently dropping either would look like the app is broken.
             // A moderation notice is not a preference either: your video is
             // gone whether or not you asked to hear about comments.
             : type === "gift" || type === "message" || type === "video_removed" ? 1
             : recipient.notify_comments; // comment, reply
  if (!pref) return;

  // Collapse repeats instead of stacking them. Following, unfollowing and
  // following again produced a fresh row every time, so one person filled the
  // list with "started following you" over and over. A like has the same shape
  // (like, unlike, like) but is per-video, so it collapses on the video too.
  // Comments, replies, gifts and messages each carry distinct content and are
  // never collapsed — every one of those is genuinely a new thing to read.
  const collapsible = type === "follow" || type === "like" || type === "repost";
  if (collapsible) {
    const existing = await env.DB.prepare(`
      SELECT id FROM notifications
      WHERE user_id = ? AND actor_id = ? AND type = ?
        AND (video_id IS ? OR video_id = ?)
      LIMIT 1
    `).bind(userId, actorId, type, extra.videoId || null, extra.videoId || null).first();
    if (existing) {
      // Move it back to the top and mark it unread again — the event did just
      // happen — but don't push a second time for something already reported.
      await env.DB.prepare(
        "UPDATE notifications SET created_at = ?, read = 0 WHERE id = ?"
      ).bind(now(), existing.id).run();
      return;
    }
  }

  const id = uid();
  await env.DB.prepare(`
    INSERT INTO notifications (id, user_id, actor_id, type, video_id, comment_id, read, created_at)
    VALUES (?, ?, ?, ?, ?, ?, 0, ?)
  `).bind(id, userId, actorId, type, extra.videoId || null, extra.commentId || null, now()).run();

  ctx.waitUntil((async () => {
    // Actor and, when this is about a video, its poster — fetched together
    // rather than one after the other, since neither depends on the other.
    const [actor, vid] = await Promise.all([
      env.DB.prepare("SELECT username, display_name, avatar_key FROM users WHERE id = ?")
        .bind(actorId).first(),
      extra.videoId
        ? env.DB.prepare("SELECT thumb_key FROM videos WHERE id = ?")
            .bind(extra.videoId).first().catch(() => null)
        : Promise.resolve(null),
    ]);
    const name = actor?.display_name || actor?.username || "Someone";
    const build = NOTIF_TEXT[type];
    if (!build) return;
    const [title, body] = build(name, extra.text);
    const url = extra.videoId ? `/?video=${extra.videoId}`
              : extra.username ? `/?user=${extra.username}` : "/";
    // The native app navigates by app route, the browser by web URL — send
    // both so one payload serves either client. `username` is always the
    // actor's, so a "liked your video" can still offer their profile.
    const actorName = actor?.username || extra.username;
    // A comment notification lands on the video WITH the comments open — the
    // action button says "Reply", so it has to arrive somewhere you can.
    const wantsComments = type === "comment" || type === "reply";
    const route = type === "message" && actorName ? `/chat/${actorName}`
                : extra.videoId ? `/v/${extra.videoId}${wantsComments ? "?comments=1" : ""}`
                : actorName ? `/profile/${actorName}` : "/notifications";
    // The person's photo, shown as the notification's large icon — the app
    // draws it, so it needs an absolute URL it can fetch without a session.
    const avatar = actor?.avatar_key ? `${PUBLIC_ORIGIN}/api/media/${actor.avatar_key}` : null;
    // Browsers and installed apps are different delivery channels, and a user
    // can have both. Neither failing may stop the other.
    await Promise.all([
      sendPush(env, userId, { title, body, url, tag: type }),
      sendFcm(env, userId, {
        title, body, url, route,
        // Per-conversation for messages so a run of them collapses into one
        // entry; per-type otherwise.
        tag: type === "message" ? `message-${actorId}` : type,
        type, avatar, actorName,
        // Shown large when the notification is expanded, so you can see which
        // of your videos it's about.
        image: vid?.thumb_key ? `${PUBLIC_ORIGIN}/api/media/${vid.thumb_key}` : null,
      }),
    ]);
  })().catch(() => {}));
}

// Real follower/like/video counts for a user, used by both the applicant's
// progress screen and the admin review — the same numbers either way.
async function monetizeStats(env, userId) {
  const row = await env.DB.prepare(`
    SELECT
      (SELECT COUNT(*) FROM follows WHERE followee_id = ? AND status = 'accepted') AS followers,
      (SELECT COUNT(*) FROM likes l JOIN videos v ON v.id = l.video_id
         WHERE v.user_id = ?) +
      (SELECT COUNT(*) FROM post_likes pl JOIN posts p ON p.id = pl.post_id
         WHERE p.user_id = ?) AS likes,
      (SELECT COUNT(*) FROM videos WHERE user_id = ? AND repost_of IS NULL) AS videos,
      (SELECT COALESCE(SUM(views), 0) FROM videos WHERE user_id = ?) AS views
  `).bind(userId, userId, userId, userId, userId).first();

  return {
    followers: row.followers,
    likes: row.likes,
    videos: row.videos,
    views: row.views,
    eligible:
      row.followers >= MONETIZE_RULES.followers &&
      row.likes >= MONETIZE_RULES.likes &&
      row.videos >= MONETIZE_RULES.videos,
    requirements: MONETIZE_RULES,
  };
}

// Fixed list an interests picker offers at signup — whitelisted server-side
// (in the signup handler) so the column only ever holds one of these, not
// arbitrary client-supplied strings.
const INTERESTS = [
  "Music", "Comedy", "Dance", "Sports", "Fashion & Beauty", "Food & Cooking",
  "Lifestyle", "Gaming", "Movies & TV", "Travel", "Technology", "Education",
  "Art & Design", "Fitness", "News", "Animals & Pets", "Family",
];

/// A video's category is drawn from the SAME list people pick their interests
/// from at signup, so "Music" on a video and "Music" in a viewer's profile are
/// the same token and match directly instead of being inferred from a caption.
const isValidCategory = c => typeof c === "string" && INTERESTS.includes(c);

/// ONE country name, stored as a JSON array (the array shape is kept so the
/// column can hold more later without a migration). Empty means everywhere.
/// Names rather than codes because users.country already holds names from
/// signup — a code would need a mapping on both sides to compare the two.
const MAX_TARGET_COUNTRIES = 1;
function normalizeCountries(raw) {
  let list = raw;
  if (typeof raw === "string") {
    try { list = JSON.parse(raw); } catch { list = raw.split(",").map(s => s.trim()); }
  }
  if (!Array.isArray(list)) return null;                 // null = everywhere
  const clean = [...new Set(list.map(c => String(c || "").trim()).filter(Boolean))]
    .slice(0, MAX_TARGET_COUNTRIES);
  return clean.length ? JSON.stringify(clean) : null;
}

/// Every row that references ONE video, in an order the foreign keys allow.
///
/// D1 enforces the REFERENCES clauses, so deleting a video while anything
/// still points at it is a constraint failure, not a warning — and each delete
/// path used to clear only the tables somebody remembered at the time. Two
/// reports on the same clip was enough to break it: handling the first deleted
/// the video, the second still pointed at it, and "Remove video" came back as
/// "Something went wrong on our end" on essentially every reported clip.
///
/// The referrers, read off the live schema rather than assumed —
/// videos(id): videos.repost_of, likes, comments, shares, messages, reports,
/// gifts. comments(id): comments.parent_id, comment_reactions,
/// reports.comment_id. notifications and video_exposures carry a video_id
/// with no REFERENCES, so they can't block a delete, but are tidied here too
/// rather than left pointing at nothing.
function videoChildStatements(env, videoId, handledBy) {
  const t = now();
  // Any other report about this video (or about a comment on it) is moot once
  // the video is gone — closing them is what stops the next moderator click
  // hitting the very same constraint.
  const closeReports = (column) => env.DB.prepare(`
    UPDATE reports SET ${column} = NULL,
      status      = CASE WHEN status = 'open' THEN 'resolved' ELSE status END,
      handled_by  = COALESCE(handled_by, ?),
      handled_at  = COALESCE(handled_at, ?),
      action_taken= COALESCE(action_taken, 'video deleted')
    WHERE ${column} ${column === "video_id" ? "= ?" : "IN (SELECT id FROM comments WHERE video_id = ?)"}
  `).bind(handledBy, t, videoId);

  return [
    // Comments and everything hanging off them, deepest first.
    env.DB.prepare(
      "DELETE FROM comment_reactions WHERE comment_id IN (SELECT id FROM comments WHERE video_id = ?)"
    ).bind(videoId),
    closeReports("comment_id"),
    env.DB.prepare(
      "DELETE FROM comments WHERE parent_id IN (SELECT id FROM comments WHERE video_id = ?)"
    ).bind(videoId),
    env.DB.prepare("DELETE FROM comments WHERE video_id = ?").bind(videoId),

    env.DB.prepare("DELETE FROM likes  WHERE video_id = ?").bind(videoId),
    env.DB.prepare("DELETE FROM shares WHERE video_id = ?").bind(videoId),
    env.DB.prepare("DELETE FROM gifts  WHERE video_id = ?").bind(videoId),
    // A conversation keeps its message; it just loses the attachment. Deleting
    // the message would take someone else's chat history with it.
    env.DB.prepare("UPDATE messages SET video_id = NULL WHERE video_id = ?").bind(videoId),
    closeReports("video_id"),
    env.DB.prepare("DELETE FROM video_exposures WHERE video_id = ?").bind(videoId),
    env.DB.prepare("DELETE FROM notifications   WHERE video_id = ?").bind(videoId),
  ];
}

/// Deletes [v] and everything that points at it, reposts included. A repost is
/// itself a row in `videos` and can carry its own likes, comments and reports,
/// so it needs the same teardown before the parent can go.
///
/// [orphanedSoundId] is the sound to delete outright (this video created it and
/// nobody else uses it); pass null to just decrement the reuse counter.
/// [handledBy] is the moderator closing the reports, or null when the owner is
/// deleting their own video — nobody "handled" anything in that case.
async function deleteVideoEverywhere(env, v, { orphanedSoundId = null, handledBy = null } = {}) {
  const reposts = await env.DB.prepare("SELECT id FROM videos WHERE repost_of = ?").bind(v.id).all();
  const statements = [];
  for (const id of [...reposts.results.map(r => r.id), v.id]) {
    statements.push(...videoChildStatements(env, id, handledBy));
  }
  // Videos that merely USE this one's sound have to let go before it can go.
  statements.push(
    env.DB.prepare("UPDATE videos SET sound_id = NULL WHERE sound_id = ? AND id != ?")
      .bind(v.sound_id || "", v.id),
    env.DB.prepare("DELETE FROM videos WHERE repost_of = ?").bind(v.id),
    env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(v.id),
  );
  if (orphanedSoundId) {
    statements.push(env.DB.prepare("DELETE FROM sounds WHERE id = ?").bind(orphanedSoundId));
  } else if (v.sound_id) {
    // This video only used the sound — its reuse count has to come back down
    // or the sound's owner is permanently blocked from deleting their video.
    statements.push(
      env.DB.prepare("UPDATE sounds SET uses = MAX(0, uses - 1) WHERE id = ?").bind(v.sound_id)
    );
  }
  await env.DB.batch(statements);
}

// ---------- feed shaping ----------

const publicUser = u => ({
  id: u.id,
  username: u.username,
  displayName: u.display_name,
  bio: u.bio,
  avatarUrl: u.avatar_key ? `/api/media/${u.avatar_key}` : null,
});

// Everything the settings screen needs — only ever sent to the owner.
const privateUser = u => ({
  ...publicUser(u),
  email: u.email,
  role: u.role || "user",
  monetized: !!u.monetized,
  coins: u.coin_balance ?? 0,
  giftBalanceCents: u.gift_balance_cents ?? 0,
  isPrivate: !!u.is_private,
  allowMessages: u.allow_messages || "everyone",
  allowComments: u.allow_comments || "everyone",
  notifyLikes: !!u.notify_likes,
  notifyComments: !!u.notify_comments,
  notifyFollows: !!u.notify_follows,
  language: u.language || "en",
  country: u.country || null,
  city: u.city || null,
  interests: u.interests ? JSON.parse(u.interests) : [],
});

// One query returns every video with real counts + whether the viewer liked it.
// A repost row (v.repost_of IS NOT NULL) has no engagement of its own — likes,
// comments, shares and gifts are all recorded against the original content
// (see resolveContentId), so every count below reads through
// COALESCE(v.repost_of, v.id) rather than v.id. For an original video that's
// just v.id unchanged; for a repost it's the video it reposts, so a fresh
// reshare of something popular shows the real numbers instead of zero.
const FEED_SQL = `
  SELECT
    v.id, v.caption, v.song, v.r2_key, v.thumb_key, v.width, v.height,
    v.duration, v.views, v.created_at, v.repost_of, v.sound_id, v.visibility,
    v.category, v.countries,
    u.id AS user_id, u.username, u.display_name, u.avatar_key,
    ru.id AS repost_of_user_id, ru.username AS repost_of_username,
    ru.display_name AS repost_of_display_name, ru.avatar_key AS repost_of_avatar_key,
    (SELECT COUNT(*) FROM likes    l WHERE l.video_id = COALESCE(v.repost_of, v.id)) AS like_count,
    (SELECT COUNT(*) FROM comments c WHERE c.video_id = COALESCE(v.repost_of, v.id)) AS comment_count,
    (SELECT COUNT(*) FROM shares   s WHERE s.video_id = COALESCE(v.repost_of, v.id) AND s.completed = 1) AS share_count,
    (SELECT COUNT(*) FROM videos   r WHERE r.repost_of = COALESCE(v.repost_of, v.id)) AS repost_count,
    (SELECT COALESCE(SUM(g.coins), 0) FROM gifts g WHERE g.video_id = COALESCE(v.repost_of, v.id)) AS gift_coins,
    EXISTS(SELECT 1 FROM likes l WHERE l.video_id = COALESCE(v.repost_of, v.id) AND l.user_id = ?) AS liked,
    -- A repost's "author" for follow purposes is the original creator, not
    -- whoever reposted it — see shapeVideo's displayUser.
    EXISTS(SELECT 1 FROM follows f
            WHERE f.follower_id = ? AND f.followee_id = COALESCE(ru.id, u.id)
              AND f.status = 'accepted')                        AS following
  FROM videos v
  JOIN users u ON u.id = v.user_id
  LEFT JOIN videos rv ON rv.id = v.repost_of
  LEFT JOIN users ru ON ru.id = rv.user_id
`;

// Videos from banned accounts must disappear from the feed — a ban that leaves
// the content playing isn't a ban. Appended to FEED_SQL wherever a viewer-facing
// list is built (feed, search, profile), but not in admin views.
const NOT_BANNED = " u.status != 'banned' ";

// Round-robin rows across their creators so no single creator forms a run,
// while preserving recency order within each creator's queue. Used by the
// Following tab (Belo Flow handles this itself for the main feed). Gracefully
// degrades: with only one creator it just returns them in order.
function interleaveByCreator(rows, keyFn) {
  const groups = new Map();
  for (const r of rows) {
    const k = keyFn(r);
    if (!groups.has(k)) groups.set(k, []);
    groups.get(k).push(r);
  }
  const queues = [...groups.values()];
  const out = [];
  let progress = true;
  while (progress) {
    progress = false;
    for (const q of queues) if (q.length) { out.push(q.shift()); progress = true; }
  }
  return out;
}

const shapeVideo = r => ({
  id: r.id,
  caption: r.caption,
  song: r.song,
  soundId: r.sound_id || null,
  videoUrl: `/api/media/${r.r2_key}`,
  thumbUrl: r.thumb_key ? `/api/media/${r.thumb_key}` : null,
  width: r.width,
  height: r.height,
  duration: r.duration,
  // Surfaced so the owner sees at a glance which of their videos are not
  // public — a profile grid of identical tiles gave no way to tell.
  visibility: r.visibility || "public",
  category: r.category || null,
  // Parsed back to a list for the client; stored as JSON. Empty = everywhere.
  countries: (() => { try { return r.countries ? JSON.parse(r.countries) : []; } catch { return []; } })(),
  views: r.views,
  createdAt: r.created_at,
  // The person who made this row exist — for a repost, that's whoever
  // reposted it, not the creator. The frontend shows this as a small
  // "Reposted by" line; the creator (repostOf below, when present) is what
  // gets the main avatar/name/profile-link treatment instead.
  user: {
    id: r.user_id,
    username: r.username,
    displayName: r.display_name,
    avatarUrl: r.avatar_key ? `/api/media/${r.avatar_key}` : null,
  },
  repostOf: r.repost_of ? {
    id: r.repost_of,
    username: r.repost_of_username,
    displayName: r.repost_of_display_name,
    avatarUrl: r.repost_of_avatar_key ? `/api/media/${r.repost_of_avatar_key}` : null,
  } : null,
  counts: {
    likes: r.like_count,
    comments: r.comment_count,
    shares: r.share_count,
    reposts: r.repost_count,
  },
  liked: !!r.liked,
  following: !!r.following,
  giftCoins: r.gift_coins || 0,
});

const shapeAd = r => ({
  id: r.id,
  isAd: true,
  // 'admin' ads render minimal (one like, no author/comments); 'user' ads are
  // self-serve and render with the creator + full engagement.
  adKind: r.kind || "admin",
  adType: r.type,
  mediaUrl: r.media_key ? `/api/media/${r.media_key}` : null,
  sponsorName: r.sponsor_name,
  caption: r.caption,
  ctaText: r.cta_text,
  linkUrl: r.link_url,
  likes: r.like_count || 0,
  liked: !!r.liked,
  comments: r.comment_count || 0,
  reach: r.reach_target || null,
  impressions: r.impressions || 0,
  // The creator, shown as the author on user ads (null on admin ads).
  user: r.owner_id ? {
    id: r.owner_id,
    username: r.owner_username,
    displayName: r.owner_display_name || r.owner_username,
    avatarUrl: r.owner_avatar_key ? `/api/media/${r.owner_avatar_key}` : null,
  } : null,
});

/// One active ad this viewer is allowed to see, or null.
///
/// [video] splits the two feeds by what the ad IS: Shorts carries the video
/// ads, Public the photo ones. Every ad used to go to Shorts regardless, so a
/// photo ad sat as a still frame in a full-screen vertical video feed while
/// Public — a photo feed, the one place a photo ad belongs — carried none.
///
/// Country targeting. Unlike a video's (a preference the recommender damps
/// by), an ad's is a hard constraint: the advertiser paid to reach a place,
/// and spending their reach elsewhere is spending their money wrongly. An
/// untargeted ad still shows to everyone, and a viewer with no country set
/// sees untargeted ads rather than none at all.
async function pickAd(env, user, { video }) {
  const viewerCountry = user?.country || "";
  return env.DB.prepare(`
    SELECT a.*,
      (SELECT COUNT(*) FROM ad_likes    WHERE ad_id = a.id) AS like_count,
      (SELECT COUNT(*) FROM ad_comments WHERE ad_id = a.id) AS comment_count,
      EXISTS(SELECT 1 FROM ad_likes WHERE ad_id = a.id AND user_id = ?) AS liked,
      ou.id AS owner_id, ou.username AS owner_username,
      ou.display_name AS owner_display_name, ou.avatar_key AS owner_avatar_key
    FROM ads a
    LEFT JOIN users ou ON ou.id = a.created_by AND a.kind = 'user'
    WHERE a.status = 'active'
      AND a.type ${video ? "=" : "!="} 'video'
      AND (a.kind = 'admin'
           OR (a.paid = 1 AND (a.reach_target IS NULL OR a.impressions < a.reach_target)))
      AND (a.countries IS NULL OR a.countries = '[]'
           OR (? != '' AND instr(a.countries, ?) > 0))
    ORDER BY RANDOM() LIMIT 1
  `).bind(user?.id || "", viewerCountry, `"${viewerCountry}"`).first();
}

const shapePost = (r) => ({
  id: r.id,
  content: r.content,
  mediaUrl: r.media_key ? `/api/media/${r.media_key}` : null,
  mediaType: r.media_type,            // 'image' | null
  width: r.width,
  height: r.height,
  createdAt: r.created_at,
  user: {
    id: r.user_id,
    username: r.username,
    displayName: r.display_name,
    avatarUrl: r.avatar_key ? `/api/media/${r.avatar_key}` : null,
    // The verified tick is driven by this and nothing else. It's a claim
    // about who someone is, so it has to come from the data.
    role: r.role,
  },
  counts: { likes: r.like_count, comments: r.comment_count, shares: r.share_count },
  liked: !!r.liked,
  following: !!r.following,
  // Only the last few comments ride along with the feed — see the note on
  // the feed route below.
  comments: r.preview_comments || [],
});

// ---------- routes ----------

async function handle(request, env, ctx) {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

  // ----- link unfurling: /v/:id for a chat app's crawler -----
  //
  // WhatsApp, Facebook and the rest fetch a shared URL once and read the OG
  // tags out of the HTML. They do NOT run JavaScript, so the SPA's index.html
  // gives them nothing to show and the link renders as a bare address. Serving
  // a small pre-filled document to those crawlers (only — real browsers still
  // get the app) is what puts a thumbnail, title and creator on the preview.
  const unfurlMatch = /^\/v\/([\w-]+)$/.exec(path);
  if (unfurlMatch && method === "GET" && isCrawler(request)) {
    const row = await env.DB.prepare(`
      SELECT v.caption, v.thumb_key, v.r2_key, v.width, v.height,
             u.username, u.display_name
      FROM videos v JOIN users u ON u.id = v.user_id WHERE v.id = ?
    `).bind(unfurlMatch[1]).first();
    if (row) {
      const esc = (s) => String(s || "").replace(/[&<>"]/g, (c) =>
        ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
      const name = row.display_name || row.username;
      const title = row.caption?.trim() ? `${name}: ${row.caption.trim().slice(0, 90)}` : `${name} on Belople`;
      const image = row.thumb_key ? `${PUBLIC_ORIGIN}/api/media/${row.thumb_key}` : `${PUBLIC_ORIGIN}/icons/icon-512.png`;
      const pageUrl = `${PUBLIC_ORIGIN}/v/${unfurlMatch[1]}`;
      return new Response(`<!doctype html><html><head>
<meta charset="utf-8">
<title>${esc(title)}</title>
<meta property="og:site_name" content="Belople">
<meta property="og:type" content="video.other">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="Watch on Belople">
<meta property="og:url" content="${esc(pageUrl)}">
<meta property="og:image" content="${esc(image)}">
<meta property="og:image:width" content="${row.width || 720}">
<meta property="og:image:height" content="${row.height || 1280}">
<meta property="og:video" content="${esc(`${PUBLIC_ORIGIN}/api/media/${row.r2_key}`)}">
<meta property="og:video:type" content="video/mp4">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:image" content="${esc(image)}">
<meta http-equiv="refresh" content="0; url=${esc(pageUrl)}">
</head><body></body></html>`, {
        headers: {
          "Content-Type": "text/html; charset=utf-8",
          // Short cache: a caption can be edited, and crawlers re-fetch.
          "Cache-Control": "public, max-age=300",
        },
      });
    }
  }

  if (!path.startsWith("/api/")) return null; // fall through to static assets

  // ----- media streaming (supports HTTP Range so video seeking works) -----
  if (path.startsWith("/api/media/")) {
    const key = decodeURIComponent(path.slice("/api/media/".length));
    const range = request.headers.get("Range");

    // Media is immutable — a video's bytes never change once uploaded — so it
    // can be cached at the edge indefinitely. Without this, every viewer pulls
    // from R2 again: slower for them, and billed per operation for you.
    // The Cache API isn't available on every deployment target (notably plain
    // workers.dev), so a miss there must degrade to "serve from R2" rather
    // than take the whole request down.
    let cache = null, cacheKey = null;
    try {
      cache = caches.default;
      cacheKey = new Request(new URL(request.url).toString(), {
        method: "GET",
        headers: range ? { Range: range } : {},
      });
      const hit = await cache.match(cacheKey);
      if (hit) return hit;
    } catch {
      cache = null;
    }

    let response;

    if (range) {
      const match = /bytes=(\d*)-(\d*)/.exec(range);
      const start = match[1] ? parseInt(match[1]) : undefined;
      const end = match[2] ? parseInt(match[2]) : undefined;

      const obj = await env.MEDIA.get(key, {
        range: start !== undefined
          ? { offset: start, length: end !== undefined ? end - start + 1 : undefined }
          : { suffix: end },
      });
      if (!obj) return err("Not found", 404);

      const total = obj.size ?? 0;
      const r = obj.range || {};
      const from = r.offset ?? 0;
      const to = from + (r.length ?? total) - 1;

      response = new Response(obj.body, {
        status: 206,
        headers: {
          "Content-Type": obj.httpMetadata?.contentType || "video/mp4",
          "Content-Range": `bytes ${from}-${to}/${total}`,
          "Accept-Ranges": "bytes",
          "Cache-Control": "public, max-age=31536000, immutable",
          "ETag": obj.httpEtag,
        },
      });
    } else {
      const obj = await env.MEDIA.get(key);
      if (!obj) return err("Not found", 404);

      response = new Response(obj.body, {
        headers: {
          "Content-Type": obj.httpMetadata?.contentType || "video/mp4",
          "Accept-Ranges": "bytes",
          "Cache-Control": "public, max-age=31536000, immutable",
          "ETag": obj.httpEtag,
        },
      });
    }

    // Fill the cache in the background — the viewer doesn't wait for it.
    if (cache) ctx.waitUntil(cache.put(cacheKey, response.clone()).catch(() => {}));
    return response;
  }

  const user = await getUser(request, env);

  // ----- auth -----
  if (path === "/api/auth/signup" && method === "POST") {
    const { username, email, password, displayName, country, city, interests } = await request.json();
    if (!username || !email || !password) return err("username, email and password are required");
    if (password.length < 8) return err("Password must be at least 8 characters");
    if (!/^[a-z0-9_]{3,20}$/i.test(username)) return err("Username must be 3-20 letters, numbers or underscores");

    // Interests, country and city are collected on later steps of the signup
    // wizard but all land in this one call — the account isn't created until
    // the whole flow finishes, so there's no half-signed-up row to clean up
    // if someone abandons partway through.
    let interestsJson = null;
    if (interests !== undefined) {
      if (!Array.isArray(interests) || interests.length > 5 || interests.some(i => typeof i !== "string" || !INTERESTS.includes(i))) {
        return err("Invalid interests");
      }
      interestsJson = JSON.stringify(interests);
    }

    const existing = await env.DB.prepare(
      "SELECT id FROM users WHERE username = ? OR email = ?"
    ).bind(username, email).first();
    if (existing) return err("That username or email is already taken", 409);

    const id = uid();
    await env.DB.prepare(`
      INSERT INTO users (id, username, email, password_hash, display_name, bio, created_at, country, city, interests)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      id, username, email, await hashPassword(password), displayName || username, "", now(),
      country || null, city || null, interestsJson
    ).run();

    const token = await createSession(env, id);
    const u = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(id).first();
    return json({ token, user: privateUser(u) }, 201);
  }

  if (path === "/api/auth/login" && method === "POST") {
    const { email, password } = await request.json();
    const u = await env.DB.prepare(
      "SELECT * FROM users WHERE email = ? OR username = ?"
    ).bind(email, email).first();
    if (!u || !(await verifyPassword(password, u.password_hash))) {
      return err("Incorrect email or password", 401);
    }
    if (u.status === "banned") {
      return err(u.banned_reason || "This account has been banned", 403);
    }
    const token = await createSession(env, u.id);
    return json({ token, user: privateUser(u) });
  }

  if (path === "/api/auth/logout" && method === "POST") {
    const auth = request.headers.get("Authorization") || "";
    if (auth.startsWith("Bearer ")) {
      await env.DB.prepare("DELETE FROM sessions WHERE token = ?").bind(auth.slice(7)).run();
    }
    return json({ ok: true });
  }

  if (path === "/api/auth/me" && method === "GET") {
    requireUser(user);
    return json({ user: privateUser(user) });
  }

  // ----- Google sign-in -----
  // Server-side authorization-code flow — two redirects, no client-side
  // Google library. GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET are Worker
  // secrets (wrangler secret put), not vars — until they're set, these
  // 501 instead of silently pretending to work.
  if (path === "/api/auth/google/start" && method === "GET") {
    if (!env.GOOGLE_CLIENT_ID) return err("Google sign-in isn't configured yet", 501);
    const state = uid();
    const authUrl = new URL("https://accounts.google.com/o/oauth2/v2/auth");
    authUrl.searchParams.set("client_id", env.GOOGLE_CLIENT_ID);
    authUrl.searchParams.set("redirect_uri", `${url.origin}/api/auth/google/callback`);
    authUrl.searchParams.set("response_type", "code");
    authUrl.searchParams.set("scope", "openid email profile");
    authUrl.searchParams.set("state", state);
    authUrl.searchParams.set("prompt", "select_account");

    return new Response(null, {
      status: 302,
      headers: {
        Location: authUrl.toString(),
        // HttpOnly + short-lived — only ever read back by the callback
        // below, to confirm the request that comes back from Google really
        // started here (blocks login CSRF) instead of being forged.
        "Set-Cookie": `oauth_state=${state}; Max-Age=600; Path=/; HttpOnly; Secure; SameSite=Lax`,
      },
    });
  }

  if (path === "/api/auth/google/callback" && method === "GET") {
    const fail = (reason) => Response.redirect(`${url.origin}/?authError=${encodeURIComponent(reason)}`, 302);
    if (!env.GOOGLE_CLIENT_ID || !env.GOOGLE_CLIENT_SECRET) return err("Google sign-in isn't configured yet", 501);

    const code = url.searchParams.get("code");
    const state = url.searchParams.get("state");
    const cookieState = (request.headers.get("Cookie") || "").match(/oauth_state=([^;]+)/)?.[1];
    if (!code || !state || !cookieState || state !== cookieState) {
      return fail("Could not verify this sign-in attempt — please try again");
    }

    const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code, client_id: env.GOOGLE_CLIENT_ID, client_secret: env.GOOGLE_CLIENT_SECRET,
        redirect_uri: `${url.origin}/api/auth/google/callback`, grant_type: "authorization_code",
      }),
    });
    if (!tokenRes.ok) return fail("Google sign-in failed — please try again");
    const tokens = await tokenRes.json();

    const profileRes = await fetch("https://www.googleapis.com/oauth2/v3/userinfo", {
      headers: { Authorization: `Bearer ${tokens.access_token}` },
    });
    if (!profileRes.ok) return fail("Google sign-in failed — please try again");
    const profile = await profileRes.json(); // { sub, email, email_verified, name, picture }
    if (!profile.email_verified) return fail("That Google account's email isn't verified");

    let account = await env.DB.prepare("SELECT * FROM users WHERE google_id = ?").bind(profile.sub).first();

    if (!account) {
      // Same email, no Google link yet — Google has already verified this
      // address, so linking it to the existing password account is safe
      // and saves someone who signed up with a password from ending up
      // with two accounts for the same email.
      account = await env.DB.prepare("SELECT * FROM users WHERE email = ?").bind(profile.email).first();
      if (account) {
        await env.DB.prepare("UPDATE users SET google_id = ? WHERE id = ?").bind(profile.sub, account.id).run();
      } else {
        // New account. Google gives no username, so derive one from the
        // email and disambiguate if it's taken.
        const base = (profile.email.split("@")[0] || "user").toLowerCase().replace(/[^a-z0-9_]/g, "").slice(0, 16) || "user";
        let username = base, tries = 0;
        while (await env.DB.prepare("SELECT id FROM users WHERE username = ?").bind(username).first()) {
          username = `${base}${Math.floor(Math.random() * 10000)}`;
          if (++tries > 20) return fail("Couldn't create an account — please try again");
        }
        const id = uid();
        // No password was ever set — hash a random value so password_hash
        // stays satisfied (NOT NULL) but unusable for logging in.
        const unusablePassword = await hashPassword(crypto.randomUUID() + crypto.randomUUID());
        await env.DB.prepare(`
          INSERT INTO users (id, username, email, password_hash, display_name, bio, created_at, google_id)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        `).bind(id, username, profile.email, unusablePassword, profile.name || username, "", now(), profile.sub).run();
        account = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(id).first();
      }
    }

    if (account.status === "banned") return fail(account.banned_reason || "This account has been banned");

    const token = await createSession(env, account.id);
    // The token can't go in a query string (server logs, browser history) —
    // the fragment never leaves the browser, and the frontend's bootstrap
    // picks it up on load (see the IIFE at the bottom of index.html).
    return new Response(null, {
      status: 302,
      headers: { Location: `${url.origin}/#auth=${token}`, "Set-Cookie": "oauth_state=; Max-Age=0; Path=/" },
    });
  }

  // ----- settings -----

  // Everything the settings screen reads
  if (path === "/api/settings" && method === "GET") {
    requireUser(user);
    return json({ user: privateUser(user) });
  }

  // Profile + privacy + notification updates. Send only the fields you change.
  if (path === "/api/settings" && method === "PATCH") {
    requireUser(user);
    const b = await request.json();

    const updates = [];
    const binds = [];

    if (b.displayName !== undefined) {
      const v = String(b.displayName).trim();
      if (v.length > 40) return err("Display name must be under 40 characters");
      updates.push("display_name = ?"); binds.push(v);
    }

    if (b.bio !== undefined) {
      const v = String(b.bio).trim();
      if (v.length > 160) return err("Bio must be under 160 characters");
      updates.push("bio = ?"); binds.push(v);
    }

    if (b.username !== undefined) {
      const v = String(b.username).trim();
      if (!/^[a-z0-9_]{3,20}$/i.test(v)) {
        return err("Username must be 3-20 letters, numbers or underscores");
      }
      if (v.toLowerCase() !== user.username.toLowerCase()) {
        const taken = await env.DB.prepare(
          "SELECT id FROM users WHERE LOWER(username) = LOWER(?) AND id != ?"
        ).bind(v, user.id).first();
        if (taken) return err("That username is already taken", 409);
      }
      updates.push("username = ?"); binds.push(v);
    }

    if (b.email !== undefined) {
      const v = String(b.email).trim();
      if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(v)) return err("That email doesn't look right");
      const taken = await env.DB.prepare(
        "SELECT id FROM users WHERE LOWER(email) = LOWER(?) AND id != ?"
      ).bind(v, user.id).first();
      if (taken) return err("That email is already in use", 409);
      updates.push("email = ?"); binds.push(v);
    }

    if (b.isPrivate !== undefined) { updates.push("is_private = ?"); binds.push(b.isPrivate ? 1 : 0); }

    for (const [field, col] of [["allowMessages", "allow_messages"], ["allowComments", "allow_comments"]]) {
      if (b[field] !== undefined) {
        if (!["everyone", "followers", "nobody"].includes(b[field])) {
          return err(`${field} must be everyone, followers or nobody`);
        }
        updates.push(`${col} = ?`); binds.push(b[field]);
      }
    }

    for (const [field, col] of [
      ["notifyLikes", "notify_likes"],
      ["notifyComments", "notify_comments"],
      ["notifyFollows", "notify_follows"],
    ]) {
      if (b[field] !== undefined) { updates.push(`${col} = ?`); binds.push(b[field] ? 1 : 0); }
    }

    if (b.language !== undefined) { updates.push("language = ?"); binds.push(String(b.language)); }

    // Country was collected at signup and then never again. Everyone who
    // joined before that step existed — and everyone who skipped it — was
    // stuck with no country, which means ad targeting can never reach them
    // and the "where are my viewers" numbers can never count them. Blank
    // clears it back to "not set" (= sees untargeted ads, as before).
    if (b.country !== undefined) {
      const v = String(b.country || "").trim();
      if (v.length > 60) return err("That doesn't look like a country");
      updates.push("country = ?"); binds.push(v || null);
    }

    if (!updates.length) return err("Nothing to update");

    binds.push(user.id);
    await env.DB.prepare(`UPDATE users SET ${updates.join(", ")} WHERE id = ?`).bind(...binds).run();

    const fresh = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(user.id).first();
    return json({ user: privateUser(fresh) });
  }

  // Live check while typing a new username
  if (path === "/api/settings/username-available" && method === "GET") {
    requireUser(user);
    const v = (url.searchParams.get("username") || "").trim();
    if (!/^[a-z0-9_]{3,20}$/i.test(v)) {
      return json({ available: false, reason: "3-20 letters, numbers or underscores" });
    }
    const taken = await env.DB.prepare(
      "SELECT id FROM users WHERE LOWER(username) = LOWER(?) AND id != ?"
    ).bind(v, user.id).first();
    return json({ available: !taken, reason: taken ? "Already taken" : null });
  }

  // Profile photo
  if (path === "/api/settings/avatar" && method === "POST") {
    requireUser(user);
    const form = await request.formData();
    const file = form.get("avatar");
    if (!file || typeof file === "string") return err("An image file is required");
    if (!/^image\//.test(file.type)) return err("That file isn't an image");
    if (file.size > 5 * 1024 * 1024) return err("Image must be under 5MB");

    const key = `avatars/${user.id}/${uid()}.jpg`;
    await env.MEDIA.put(key, file.stream(), {
      httpMetadata: { contentType: file.type || "image/jpeg" },
    });

    // Drop the old file so R2 doesn't accumulate orphans
    if (user.avatar_key) await env.MEDIA.delete(user.avatar_key).catch(() => {});

    await env.DB.prepare("UPDATE users SET avatar_key = ? WHERE id = ?").bind(key, user.id).run();
    return json({ avatarUrl: `/api/media/${key}` });
  }

  if (path === "/api/settings/avatar" && method === "DELETE") {
    requireUser(user);
    if (user.avatar_key) await env.MEDIA.delete(user.avatar_key).catch(() => {});
    await env.DB.prepare("UPDATE users SET avatar_key = NULL WHERE id = ?").bind(user.id).run();
    return json({ avatarUrl: null });
  }

  if (path === "/api/settings/password" && method === "POST") {
    requireUser(user);
    const { currentPassword, newPassword } = await request.json();
    if (!(await verifyPassword(currentPassword || "", user.password_hash))) {
      return err("Your current password is incorrect", 403);
    }
    if (!newPassword || newPassword.length < 8) {
      return err("New password must be at least 8 characters");
    }

    await env.DB.prepare("UPDATE users SET password_hash = ? WHERE id = ?")
      .bind(await hashPassword(newPassword), user.id).run();

    // Signing out everywhere else is the point of a password change
    const auth = request.headers.get("Authorization").slice(7);
    await env.DB.prepare("DELETE FROM sessions WHERE user_id = ? AND token != ?")
      .bind(user.id, auth).run();

    return json({ ok: true });
  }

  if (path === "/api/settings/sessions" && method === "DELETE") {
    requireUser(user);
    const auth = request.headers.get("Authorization").slice(7);
    await env.DB.prepare("DELETE FROM sessions WHERE user_id = ? AND token != ?")
      .bind(user.id, auth).run();
    return json({ ok: true });
  }

  if (path === "/api/settings/account" && method === "DELETE") {
    requireUser(user);
    const { password } = await request.json();
    if (!(await verifyPassword(password || "", user.password_hash))) {
      return err("Password is incorrect", 403);
    }

    // Remove this user's files from R2 first
    const own = await env.DB.prepare(
      "SELECT r2_key, thumb_key FROM videos WHERE user_id = ? AND repost_of IS NULL"
    ).bind(user.id).all();
    for (const v of own.results) {
      await env.MEDIA.delete(v.r2_key).catch(() => {});
      if (v.thumb_key) await env.MEDIA.delete(v.thumb_key).catch(() => {});
    }
    if (user.avatar_key) await env.MEDIA.delete(user.avatar_key).catch(() => {});

    // Sounds this account originated go with it — the r2 object backing
    // their audio was just deleted above. Other people's videos pointing at
    // one are unhooked rather than left referencing a sound that 404s.
    // Sounds this account only reused (didn't own) get their count corrected
    // the same way a single-video delete does, so it doesn't drift upward
    // and strand the real owner.
    const ownedSounds = await env.DB.prepare("SELECT id FROM sounds WHERE author_user_id = ?").bind(user.id).all();
    const reusedSounds = await env.DB.prepare(
      "SELECT DISTINCT sound_id FROM videos WHERE user_id = ? AND sound_id IS NOT NULL"
    ).bind(user.id).all();
    const ownedSoundIds = new Set(ownedSounds.results.map(s => s.id));

    await env.DB.batch([
      env.DB.prepare("DELETE FROM likes WHERE user_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM comments WHERE user_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM shares WHERE user_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM follows WHERE follower_id = ? OR followee_id = ?").bind(user.id, user.id),
      env.DB.prepare("DELETE FROM messages WHERE sender_id = ? OR recipient_id = ?").bind(user.id, user.id),
      ...ownedSoundIds.size
        ? [...ownedSoundIds].map(id => env.DB.prepare("UPDATE videos SET sound_id = NULL WHERE sound_id = ?").bind(id))
        : [],
      ...ownedSoundIds.size ? [env.DB.prepare("DELETE FROM sounds WHERE author_user_id = ?").bind(user.id)] : [],
      ...reusedSounds.results
        .filter(s => !ownedSoundIds.has(s.sound_id))
        .map(s => env.DB.prepare("UPDATE sounds SET uses = MAX(0, uses - 1) WHERE id = ?").bind(s.sound_id)),
      env.DB.prepare("DELETE FROM videos WHERE user_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM users WHERE id = ?").bind(user.id),
    ]);

    return json({ ok: true });
  }

  // ----- feed -----
  if (path === "/api/feed" && method === "GET") {
    // "belo" is the real name of the main recommendation feed; "foryou" is kept
    // as an alias for older clients. Both route through Belo Flow.
    const tab = url.searchParams.get("tab") || "belo";
    const limit = Math.min(parseInt(url.searchParams.get("limit") || "15"), 30);
    const cursor = url.searchParams.get("cursor");
    const seed = url.searchParams.get("session");
    const viewerId = user?.id || "";

    // ----- FOLLOWING: explicit follows, freshest first, creator-interleaved -----
    if (tab === "following") {
      requireUser(user);
      const visible = `(
        v.user_id = ?
        OR (v.visibility = 'public' AND u.is_private = 0)
        OR ((v.visibility = 'followers' OR u.is_private = 1) AND v.visibility != 'private' AND EXISTS(
              SELECT 1 FROM follows f
              WHERE f.follower_id = ? AND f.followee_id = v.user_id AND f.status = 'accepted'))
      )`;
      let sql = FEED_SQL + ` WHERE ${NOT_BANNED} AND ${visible} AND v.user_id IN (
                 SELECT followee_id FROM follows WHERE follower_id = ? AND status = 'accepted')`;
      const binds = [viewerId, viewerId, viewerId, viewerId, user.id];
      if (cursor) { sql += " AND v.created_at < ?"; binds.push(parseInt(cursor)); }
      // Pull a little extra so the interleave has room to separate creators.
      sql += " ORDER BY v.created_at DESC LIMIT ?";
      binds.push(limit + 6);
      const { results } = await env.DB.prepare(sql).bind(...binds).all();
      // Even in Following, don't show a run of one creator when others have
      // fresh content — round-robin interleave, preserving recency within each.
      const ordered = interleaveByCreator(results, (r) => r.repost_of_user_id || r.user_id).slice(0, limit);
      const videos = ordered.map(shapeVideo);
      const nextCursor = results.length > limit
        ? String(ordered[ordered.length - 1].created_at) : null;
      return json({ videos, nextCursor });
    }

    // ----- BELO: the recommendation feed (Belo Flow) -----
    let videos, nextCursor;
    try {
      const { rows, nextOffset } = await buildBeloFeed(env, { viewerId, limit, cursor, seed });
      videos = rows.map((r) => {
        const v = shapeVideo(r);
        v.recoReason = r.recoReason || null;   // explainable "why you see this"
        v.recoBucket = r.recoBucket || null;   // personalized|discovery|trending|exploration
        return v;
      });
      nextCursor = nextOffset != null ? String(nextOffset) : null;
    } catch (e) {
      // Belo Flow needs the 002_belo_flow migration. Until it's applied, fall
      // back to the legacy hot-score ranking so the feed is never empty.
      console.error("Belo Flow fell back to legacy ranking:", e?.message || e);
      const visible = `(
        v.user_id = ?
        OR (v.visibility = 'public' AND u.is_private = 0)
        OR ((v.visibility = 'followers' OR u.is_private = 1) AND v.visibility != 'private' AND EXISTS(
              SELECT 1 FROM follows f
              WHERE f.follower_id = ? AND f.followee_id = v.user_id AND f.status = 'accepted'))
      )`;
      const offset = cursor ? Math.max(0, parseInt(cursor)) : 0;
      const sql = FEED_SQL + ` WHERE ${NOT_BANNED} AND ${visible}
        ORDER BY (
          (COALESCE(like_count,0) * 3 + COALESCE(comment_count,0) * 4 +
           COALESCE(share_count,0) * 5 + COALESCE(repost_count,0) * 3 +
           v.views * 0.05 + 1)
          / pow((? - v.created_at) / 3600000.0 + 2, 1.5)
          + (CASE WHEN EXISTS(SELECT 1 FROM follows f2
               WHERE f2.follower_id = ? AND f2.followee_id = v.user_id AND f2.status = 'accepted')
             THEN 80 ELSE 0 END)
        ) DESC, v.created_at DESC LIMIT ? OFFSET ?`;
      const { results } = await env.DB.prepare(sql)
        .bind(viewerId, viewerId, viewerId, viewerId, now(), viewerId, limit, offset).all();
      videos = results.map(shapeVideo);
      nextCursor = results.length === limit ? String(offset + limit) : null;
    }

    // One ad woven into each batch, a few videos in rather than first thing —
    // never on the (ad-free) following tab. Video ads only: the photo ones go
    // to Public, where a photo belongs.
    if (videos.length >= 3) {
      const ad = await pickAd(env, user, { video: true });
      if (ad) videos.splice(Math.min(4, videos.length), 0, shapeAd(ad));
    }

    return json({ videos, nextCursor });
  }

  // ----- public: photo feed -----
  if (path === "/api/posts" && method === "GET") {
    const limit = Math.min(parseInt(url.searchParams.get("limit") || "15"), 30);
    const cursor = url.searchParams.get("cursor");
    const viewerId = user?.id || "";

    let sql = `
      SELECT p.id, p.content, p.media_key, p.media_type, p.width, p.height, p.created_at,
             u.id AS user_id, u.username, u.display_name, u.avatar_key, u.role,
             (SELECT COUNT(*) FROM post_likes    WHERE post_id = p.id) AS like_count,
             (SELECT COUNT(*) FROM post_comments WHERE post_id = p.id) AS comment_count,
             (SELECT COUNT(*) FROM post_shares   WHERE post_id = p.id) AS share_count,
             EXISTS(SELECT 1 FROM post_likes WHERE post_id = p.id AND user_id = ?) AS liked,
             EXISTS(SELECT 1 FROM follows f
                     WHERE f.follower_id = ? AND f.followee_id = u.id
                       AND f.status = 'accepted')                       AS following
      FROM posts p JOIN users u ON u.id = p.user_id
      WHERE u.status != 'banned'
        -- A private account's posts are for its accepted followers, exactly
        -- like its videos. This feed had no privacy gate at all, so marking an
        -- account private hid its Shorts and left every photo and written post
        -- of theirs in front of the whole world.
        AND (u.is_private = 0 OR u.id = ? OR EXISTS(
              SELECT 1 FROM follows f
              WHERE f.follower_id = ? AND f.followee_id = u.id AND f.status = 'accepted'))
    `;
    const binds = [viewerId, viewerId, viewerId, viewerId];
    if (cursor) { sql += " AND p.created_at < ?"; binds.push(parseInt(cursor)); }
    sql += " ORDER BY p.created_at DESC LIMIT ?";
    binds.push(limit);

    const { results } = await env.DB.prepare(sql).bind(...binds).all();

    // Attach the two most recent comments per post in ONE query rather than one
    // per post. With 15 posts that's the difference between 2 queries and 16 —
    // and D1 charges per query, so the loop version gets expensive as the feed
    // grows, not just slow.
    if (results.length) {
      const ids = results.map(r => r.id);
      const marks = ids.map(() => "?").join(",");
      const { results: cmts } = await env.DB.prepare(`
        SELECT * FROM (
          SELECT c.id, c.post_id, c.body, c.created_at,
                 u.username, u.display_name, u.avatar_key,
                 ROW_NUMBER() OVER (PARTITION BY c.post_id ORDER BY c.created_at DESC) AS rn
          FROM post_comments c JOIN users u ON u.id = c.user_id
          WHERE c.post_id IN (${marks}) AND u.status != 'banned'
        ) WHERE rn <= 2
      `).bind(...ids).all();

      const byPost = new Map();
      for (const c of cmts) {
        if (!byPost.has(c.post_id)) byPost.set(c.post_id, []);
        byPost.get(c.post_id).push({
          id: c.id,
          body: c.body,
          createdAt: c.created_at,
          user: {
            username: c.username,
            displayName: c.display_name,
            avatarUrl: c.avatar_key ? `/api/media/${c.avatar_key}` : null,
          },
        });
      }
      // Oldest first within each post, so they read top to bottom like a
      // conversation rather than newest-first like a list.
      for (const r of results) r.preview_comments = (byPost.get(r.id) || []).reverse();
    }

    // Public carries the photo and text ads — the ones that read as a post
    // rather than as a full-screen video. Sent alongside the posts, not inside
    // them, so a post is only ever a post: the client splices it in a few
    // cards down, the same way it already splices in videos. Only on the first
    // page, so scrolling doesn't stack a new ad on every batch.
    const ad = (!cursor && results.length >= 3) ? await pickAd(env, user, { video: false }) : null;

    return json({
      posts: results.map(shapePost),
      ad: ad ? shapeAd(ad) : null,
      nextCursor: results.length === limit
        ? String(results[results.length - 1].created_at) : null,
    });
  }

  if (path === "/api/posts" && method === "POST") {
    requireUser(user);
    const form = await request.formData();
    const content = (form.get("content") || "").trim();
    const file = form.get("image");
    const hasFile = file && typeof file !== "string";

    // Public is photos or text — never neither. Videos still go to the main
    // feed. Enforced here, not just hidden in the UI, because a client can
    // post whatever it likes and a genuinely empty row would render as a
    // blank card in the feed.
    if (!hasFile && !content) {
      return err("Add a photo or write something");
    }
    if (content.length > 2000) return err("Post must be under 2000 characters");

    const id = uid();
    let mediaKey = null, mediaType = null, width = null, height = null;

    if (file && typeof file !== "string") {
      if (!/^image\//.test(file.type)) return err("That file isn't an image");
      if (file.size > 10 * 1024 * 1024) return err("Image must be under 10MB");
      const ext = (file.type.split("/")[1] || "jpg").split("+")[0];
      mediaKey = `posts/${user.id}/${id}.${ext}`;
      mediaType = "image";
      width  = parseInt(form.get("width"))  || null;
      height = parseInt(form.get("height")) || null;
      await env.MEDIA.put(mediaKey, file.stream(), {
        httpMetadata: { contentType: file.type },
      });
    }

    await env.DB.prepare(`
      INSERT INTO posts (id, user_id, content, media_key, media_type, width, height, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(id, user.id, content || null, mediaKey, mediaType, width, height, now()).run();

    const row = await env.DB.prepare(`
      SELECT p.*, u.id AS user_id, u.username, u.display_name, u.avatar_key,
             0 AS like_count, 0 AS comment_count, 0 AS liked, 0 AS following
      FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = ?
    `).bind(id).first();
    return json({ post: shapePost(row) }, 201);
  }

  const postLikeMatch = /^\/api\/posts\/([\w-]+)\/like$/.exec(path);
  if (postLikeMatch && (method === "POST" || method === "DELETE")) {
    requireUser(user);
    const postId = postLikeMatch[1];
    if (method === "POST") {
      const post = await env.DB.prepare("SELECT user_id FROM posts WHERE id = ?").bind(postId).first();
      if (!post) return err("Post not found", 404);
      await env.DB.prepare(
        "INSERT OR IGNORE INTO post_likes (post_id, user_id, created_at) VALUES (?, ?, ?)"
      ).bind(postId, user.id, now()).run();
    } else {
      await env.DB.prepare(
        "DELETE FROM post_likes WHERE post_id = ? AND user_id = ?"
      ).bind(postId, user.id).run();
    }
    const c = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM post_likes WHERE post_id = ?"
    ).bind(postId).first();
    return json({ liked: method === "POST", count: c.n });
  }

  const postCommentsMatch = /^\/api\/posts\/([\w-]+)\/comments$/.exec(path);

  if (postCommentsMatch && method === "GET") {
    const { results } = await env.DB.prepare(`
      SELECT c.id, c.body, c.created_at, c.parent_id,
             u.id AS user_id, u.username, u.display_name, u.avatar_key, u.role,
             (SELECT COUNT(*) FROM post_comment_likes WHERE comment_id = c.id) AS like_count,
             EXISTS(SELECT 1 FROM post_comment_likes
                     WHERE comment_id = c.id AND user_id = ?)                  AS liked
      FROM post_comments c JOIN users u ON u.id = c.user_id
      WHERE c.post_id = ? AND u.status != 'banned'
      ORDER BY c.created_at ASC LIMIT 200
    `).bind(user?.id || "", postCommentsMatch[1]).all();
    return json({
      comments: results.map(c => ({
        id: c.id, body: c.body, createdAt: c.created_at, parentId: c.parent_id,
        likes: c.like_count, liked: !!c.liked,
        user: {
          id: c.user_id, username: c.username, displayName: c.display_name,
          avatarUrl: c.avatar_key ? `/api/media/${c.avatar_key}` : null,
          role: c.role,
        },
      })),
    });
  }

  if (postCommentsMatch && method === "POST") {
    requireUser(user);
    const { body, parentId } = await request.json();
    if (!body?.trim()) return err("Write something first");
    if (body.length > 500) return err("Comment must be under 500 characters");

    // The post author's "who can comment" setting applies here exactly as it
    // does on videos. Two comment systems with two different privacy rules
    // would be a setting that silently doesn't mean what it says.
    const post = await env.DB.prepare(`
      SELECT p.user_id, u.allow_comments FROM posts p
      JOIN users u ON u.id = p.user_id WHERE p.id = ?
    `).bind(postCommentsMatch[1]).first();
    if (!post) return err("Post not found", 404);
    if (post.user_id !== user.id) {
      const pref = post.allow_comments || "everyone";
      if (pref === "nobody") return err("Comments are turned off for this post", 403);
      if (pref === "followers") {
        const f = await env.DB.prepare(
          "SELECT 1 FROM follows WHERE follower_id = ? AND followee_id = ? AND status = 'accepted'"
        ).bind(user.id, post.user_id).first();
        if (!f) return err("Only followers can comment on this post", 403);
      }
    }

    // A reply must actually point at a comment on this same post — otherwise
    // a stray/forged parentId could nest a reply under an unrelated post's
    // comment.
    let parent = null;
    if (parentId) {
      parent = await env.DB.prepare(
        "SELECT id, user_id FROM post_comments WHERE id = ? AND post_id = ?"
      ).bind(parentId, postCommentsMatch[1]).first();
      if (!parent) return err("That comment no longer exists", 404);
    }

    const id = uid();
    await env.DB.prepare(
      "INSERT INTO post_comments (id, post_id, user_id, body, parent_id, created_at) VALUES (?, ?, ?, ?, ?, ?)"
    ).bind(id, postCommentsMatch[1], user.id, body.trim(), parent?.id || null, now()).run();
    const c = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM post_comments WHERE post_id = ?"
    ).bind(postCommentsMatch[1]).first();

    if (parent && parent.user_id !== user.id) {
      await notify(env, ctx, parent.user_id, user.id, "reply", { commentId: id, text: body.trim() });
    }

    return json({
      comment: {
        id, body: body.trim(), createdAt: now(), parentId: parent?.id || null,
        likes: 0, liked: false,
        user: { ...publicUser(user), role: user.role },
      },
      count: c.n,
    }, 201);
  }

  const postShareMatch = /^\/api\/posts\/([\w-]+)\/share$/.exec(path);
  if (postShareMatch && method === "POST") {
    requireUser(user);
    const post = await env.DB.prepare("SELECT id FROM posts WHERE id = ?").bind(postShareMatch[1]).first();
    if (!post) return err("Post not found", 404);
    await env.DB.prepare(
      "INSERT INTO post_shares (id, post_id, user_id, created_at) VALUES (?, ?, ?, ?)"
    ).bind(uid(), post.id, user.id, now()).run();
    const c = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM post_shares WHERE post_id = ?"
    ).bind(post.id).first();
    return json({ count: c.n });
  }
  // Note this records every share, not one per person — the same person sharing
  // twice counts twice, which is what a share count is supposed to mean. That's
  // deliberately different from likes, where a second tap toggles rather than
  // adding.

  const cmtLikeMatch = /^\/api\/posts\/comments\/([\w-]+)\/like$/.exec(path);
  if (cmtLikeMatch && (method === "POST" || method === "DELETE")) {
    requireUser(user);
    const cid = cmtLikeMatch[1];
    if (method === "POST") {
      const c = await env.DB.prepare("SELECT id FROM post_comments WHERE id = ?").bind(cid).first();
      if (!c) return err("Comment not found", 404);
      await env.DB.prepare(
        "INSERT OR IGNORE INTO post_comment_likes (comment_id, user_id, created_at) VALUES (?, ?, ?)"
      ).bind(cid, user.id, now()).run();
    } else {
      await env.DB.prepare(
        "DELETE FROM post_comment_likes WHERE comment_id = ? AND user_id = ?"
      ).bind(cid, user.id).run();
    }
    const n = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM post_comment_likes WHERE comment_id = ?"
    ).bind(cid).first();
    return json({ liked: method === "POST", count: n.n });
  }

  const postMatch = /^\/api\/posts\/([\w-]+)$/.exec(path);
  if (postMatch && method === "DELETE") {
    requireUser(user);
    const p = await env.DB.prepare("SELECT * FROM posts WHERE id = ?").bind(postMatch[1]).first();
    if (!p) return err("Post not found", 404);
    if (p.user_id !== user.id) return err("That isn't your post", 403);
    if (p.media_key) await env.MEDIA.delete(p.media_key).catch(() => {});
    // Comment likes are cleared through their comments — deleting the comments
    // alone would leave orphan rows in post_comment_likes that nothing can ever
    // reach or clean up.
    await env.DB.batch([
      env.DB.prepare(`DELETE FROM post_comment_likes WHERE comment_id IN
                        (SELECT id FROM post_comments WHERE post_id = ?)`).bind(p.id),
      env.DB.prepare("DELETE FROM post_likes    WHERE post_id = ?").bind(p.id),
      env.DB.prepare("DELETE FROM post_comments WHERE post_id = ?").bind(p.id),
      env.DB.prepare("DELETE FROM post_shares   WHERE post_id = ?").bind(p.id),
      env.DB.prepare("DELETE FROM posts         WHERE id = ?").bind(p.id),
    ]);
    return json({ ok: true });
  }

  // ----- ads: public view/click tracking -----
  const adViewMatch = /^\/api\/ads\/([\w-]+)\/view$/.exec(path);
  if (adViewMatch && method === "POST") {
    await env.DB.prepare("UPDATE ads SET impressions = impressions + 1 WHERE id = ?")
      .bind(adViewMatch[1]).run();
    // A paid user ad that has reached its target audience stops showing, and
    // the owner is notified it's done (with the final view count in stats).
    const ad = await env.DB.prepare(
      "SELECT created_by, kind, status, impressions, reach_target FROM ads WHERE id = ?"
    ).bind(adViewMatch[1]).first();
    if (ad && ad.kind === "user" && ad.status === "active"
        && ad.reach_target && ad.impressions >= ad.reach_target) {
      await env.DB.prepare("UPDATE ads SET status = 'complete' WHERE id = ?").bind(adViewMatch[1]).run();
      await notify(env, ctx, ad.created_by, ad.created_by, "ad_complete", { adId: adViewMatch[1] });
    }
    return json({ ok: true });
  }

  const adClickMatch = /^\/api\/ads\/([\w-]+)\/click$/.exec(path);
  if (adClickMatch && method === "POST") {
    await env.DB.prepare("UPDATE ads SET clicks = clicks + 1 WHERE id = ?")
      .bind(adClickMatch[1]).run();
    return json({ ok: true });
  }

  const adLikeMatch = /^\/api\/ads\/([\w-]+)\/like$/.exec(path);
  if (adLikeMatch && (method === "POST" || method === "DELETE")) {
    requireUser(user);
    if (method === "POST") {
      await env.DB.prepare(
        "INSERT OR IGNORE INTO ad_likes (user_id, ad_id, created_at) VALUES (?, ?, ?)"
      ).bind(user.id, adLikeMatch[1], now()).run();
    } else {
      await env.DB.prepare(
        "DELETE FROM ad_likes WHERE user_id = ? AND ad_id = ?"
      ).bind(user.id, adLikeMatch[1]).run();
    }
    const c = await env.DB.prepare("SELECT COUNT(*) AS n FROM ad_likes WHERE ad_id = ?").bind(adLikeMatch[1]).first();
    return json({ liked: method === "POST", count: c.n });
  }

  // ----- self-serve ads (users create + pay; admin approves) -----
  // reach → required price in cents, the single source of truth for pricing.
  const AD_TIERS = { 1000: 200, 10000: 2000, 200000: 20000 };

  if (path === "/api/ads" && method === "POST") {
    requireUser(user);
    const form = await request.formData();
    const kind = (form.get("kind") || "").trim();          // 'video' | 'image' | 'link'
    const reach = parseInt(form.get("reach")) || 0;
    const priceCents = parseInt(form.get("priceCents")) || 0;
    if (!AD_TIERS[reach]) return err("Pick a valid reach tier");
    if (priceCents !== AD_TIERS[reach]) return err("Price doesn't match the selected reach");

    const linkUrl = (form.get("linkUrl") || "").trim();
    const caption = (form.get("caption") || "").trim();
    const ctaText = (form.get("ctaText") || "Learn more").trim();

    let type = null, mediaKey = null;
    if (kind === "link") {
      if (!/^https?:\/\//i.test(linkUrl)) return err("A valid link (http/https) is required");
      type = "link";
    } else {
      const file = form.get("media");
      if (!file || typeof file === "string") return err("A photo or video is required");
      type = /^video\//.test(file.type) ? "video" : /^image\//.test(file.type) ? "image" : null;
      if (!type) return err("File must be an image or a video");
      const mid = uid();
      const ext = (file.name?.split(".").pop() || (type === "video" ? "mp4" : "jpg")).toLowerCase();
      mediaKey = `ads/${mid}.${ext}`;
      await env.MEDIA.put(mediaKey, file.stream(), { httpMetadata: { contentType: file.type } });
    }

    const id = uid();
    await env.DB.prepare(`
      INSERT INTO ads (id, kind, type, media_key, sponsor_name, caption, cta_text, link_url,
                       status, reach_target, price_cents, paid, impressions, clicks, created_by, created_at, countries)
      VALUES (?, 'user', ?, ?, ?, ?, ?, ?, 'pending', ?, ?, 0, 0, 0, ?, ?, ?)
    `).bind(id, type, mediaKey, user.display_name || user.username, caption, ctaText,
            linkUrl || null, reach, priceCents, user.id, now(),
            // Where the advertiser wants to be seen. Null = everywhere.
            normalizeCountries(form.get("countries"))).run();
    return json({ ad: { id } }, 201);
  }

  // Checkout — STUBBED until a real payment provider is wired in. Marks the ad
  // paid so it enters the admin review queue. TODO: charge, only mark on success.
  const adPayMatch = /^\/api\/ads\/([\w-]+)\/pay$/.exec(path);
  if (adPayMatch && method === "POST") {
    requireUser(user);
    const ad = await env.DB.prepare("SELECT id, paid FROM ads WHERE id = ? AND created_by = ?")
      .bind(adPayMatch[1], user.id).first();
    if (!ad) return err("Ad not found", 404);
    if (!ad.paid) await env.DB.prepare("UPDATE ads SET paid = 1 WHERE id = ?").bind(ad.id).run();
    return json({ ok: true });
  }

  // The caller's own ads with live stats (views/clicks/status).
  if (path === "/api/ads/mine" && method === "GET") {
    requireUser(user);
    const { results } = await env.DB.prepare(`
      SELECT a.*, (SELECT COUNT(*) FROM ad_likes    WHERE ad_id = a.id) AS like_count,
                  (SELECT COUNT(*) FROM ad_comments WHERE ad_id = a.id) AS comment_count
      FROM ads a WHERE a.created_by = ? AND a.kind = 'user' ORDER BY a.created_at DESC
    `).bind(user.id).all();
    return json({ ads: results.map(a => ({
      ...shapeAd(a), status: a.status, paid: !!a.paid,
      reach: a.reach_target, impressions: a.impressions, clicks: a.clicks,
      priceCents: a.price_cents, createdAt: a.created_at,
    })) });
  }

  // Comments on a user ad (list + add).
  const adCommentsMatch = /^\/api\/ads\/([\w-]+)\/comments$/.exec(path);
  if (adCommentsMatch && method === "GET") {
    const { results } = await env.DB.prepare(`
      SELECT c.id, c.body, c.created_at, u.username, u.display_name, u.avatar_key
      FROM ad_comments c JOIN users u ON u.id = c.user_id
      WHERE c.ad_id = ? ORDER BY c.created_at ASC LIMIT 200
    `).bind(adCommentsMatch[1]).all();
    return json({ comments: results.map(c => ({
      id: c.id, body: c.body, createdAt: c.created_at,
      user: { username: c.username, displayName: c.display_name,
              avatarUrl: c.avatar_key ? `/api/media/${c.avatar_key}` : null },
    })) });
  }
  if (adCommentsMatch && method === "POST") {
    requireUser(user);
    const { body } = await request.json();
    const text = (body || "").trim();
    if (!text) return err("Comment can't be empty");
    await env.DB.prepare("INSERT INTO ad_comments (id, ad_id, user_id, body, created_at) VALUES (?, ?, ?, ?, ?)")
      .bind(uid(), adCommentsMatch[1], user.id, text, now()).run();
    const c = await env.DB.prepare("SELECT COUNT(*) AS n FROM ad_comments WHERE ad_id = ?").bind(adCommentsMatch[1]).first();
    return json({ ok: true, count: c.n }, 201);
  }

  // Admin review queue + approve/reject.
  if (path === "/api/admin/ads/pending" && method === "GET") {
    requireStaff(user);
    const { results } = await env.DB.prepare(`
      SELECT a.*, u.username AS owner_username, u.display_name AS owner_display_name, u.avatar_key AS owner_avatar_key,
             a.created_by AS owner_id
      FROM ads a JOIN users u ON u.id = a.created_by
      WHERE a.kind = 'user' AND a.paid = 1 AND a.status = 'pending'
      ORDER BY a.created_at ASC
    `).all();
    return json({ ads: results.map(a => ({
      ...shapeAd(a), status: a.status, reach: a.reach_target, priceCents: a.price_cents, createdAt: a.created_at,
    })) });
  }
  const adDecideMatch = /^\/api\/admin\/ads\/([\w-]+)\/(approve|reject)$/.exec(path);
  if (adDecideMatch && method === "POST") {
    requireStaff(user);
    const ad = await env.DB.prepare("SELECT id, created_by FROM ads WHERE id = ?").bind(adDecideMatch[1]).first();
    if (!ad) return err("Ad not found", 404);
    const approve = adDecideMatch[2] === "approve";
    await env.DB.prepare("UPDATE ads SET status = ? WHERE id = ?")
      .bind(approve ? "active" : "rejected", ad.id).run();
    await logAdmin(env, user.id, approve ? "ad_approved" : "ad_rejected", "ad", ad.id);
    await notify(env, ctx, ad.created_by, user.id, approve ? "ad_approved" : "ad_rejected", { adId: ad.id });
    return json({ ok: true, status: approve ? "active" : "rejected" });
  }

  // ----- admin: ads -----
  if (path === "/api/admin/ads" && method === "GET") {
    requireStaff(user);
    // Search over everything the admin list actually shows: sponsor, caption,
    // destination link, the target country, the status word, and — for
    // self-serve ads — whose ad it is. Once there are more than a screenful of
    // ads, finding one meant scrolling; there was no way to ask for it.
    // instr(lower(), lower()) rather than LIKE so a % or _ typed into the box
    // is searched for literally instead of behaving as a wildcard.
    const q = (url.searchParams.get("q") || "").trim();
    const { results } = q
      ? await env.DB.prepare(`
          SELECT a.* FROM ads a
          LEFT JOIN users u ON u.id = a.created_by
          WHERE instr(lower(coalesce(a.sponsor_name, '')), lower(?)) > 0
             OR instr(lower(coalesce(a.caption,      '')), lower(?)) > 0
             OR instr(lower(coalesce(a.link_url,     '')), lower(?)) > 0
             OR instr(lower(coalesce(a.countries,    '')), lower(?)) > 0
             OR instr(lower(coalesce(a.status,       '')), lower(?)) > 0
             OR instr(lower(coalesce(u.username,     '')), lower(?)) > 0
          ORDER BY a.created_at DESC
        `).bind(q, q, q, q, q, q).all()
      : await env.DB.prepare("SELECT * FROM ads ORDER BY created_at DESC").all();
    return json({ ads: results.map(a => ({ ...shapeAd(a), status: a.status, impressions: a.impressions, clicks: a.clicks, createdAt: a.created_at, countries: (() => { try { return a.countries ? JSON.parse(a.countries) : []; } catch { return []; } })() })) });
  }

  if (path === "/api/admin/ads" && method === "POST") {
    requireStaff(user);
    const form = await request.formData();
    const file = form.get("media");
    if (!file || typeof file === "string") return err("A photo or video file is required");

    const type = /^video\//.test(file.type) ? "video" : /^image\//.test(file.type) ? "photo" : null;
    if (!type) return err("File must be an image or a video");

    const linkUrl = (form.get("linkUrl") || "").trim();
    if (!linkUrl) return err("A destination link is required");
    if (!/^https?:\/\//i.test(linkUrl)) return err("Link must start with http:// or https://");

    const sponsorName = (form.get("sponsorName") || "").trim();
    if (!sponsorName) return err("Sponsor name is required");

    const id = uid();
    const ext = (file.name?.split(".").pop() || (type === "video" ? "mp4" : "jpg")).toLowerCase();
    const key = `ads/${id}.${ext}`;
    await env.MEDIA.put(key, file.stream(), {
      httpMetadata: { contentType: file.type },
    });

    await env.DB.prepare(`
      INSERT INTO ads (id, type, media_key, sponsor_name, caption, cta_text, link_url, status, created_by, created_at, countries)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?)
    `).bind(
      id, type, key, sponsorName,
      (form.get("caption") || "").trim(),
      (form.get("ctaText") || "Learn more").trim(),
      linkUrl, user.id, now(),
      // Admin house ads target the same way self-serve ones do. Null = everywhere.
      normalizeCountries(form.get("countries"))
    ).run();

    await logAdmin(env, user.id, "ad_created", "ad", id, sponsorName);

    const row = await env.DB.prepare("SELECT * FROM ads WHERE id = ?").bind(id).first();
    return json({ ad: shapeAd(row) }, 201);
  }

  const adPatchMatch = /^\/api\/admin\/ads\/([\w-]+)$/.exec(path);
  if (adPatchMatch && method === "PATCH") {
    requireStaff(user);
    const { status } = await request.json();
    if (!["active", "paused"].includes(status)) return err("status must be active or paused");
    await env.DB.prepare("UPDATE ads SET status = ? WHERE id = ?").bind(status, adPatchMatch[1]).run();
    await logAdmin(env, user.id, status === "active" ? "ad_resumed" : "ad_paused", "ad", adPatchMatch[1]);
    return json({ ok: true });
  }

  if (adPatchMatch && method === "DELETE") {
    requireStaff(user);
    const ad = await env.DB.prepare("SELECT media_key FROM ads WHERE id = ?").bind(adPatchMatch[1]).first();
    if (!ad) return err("Not found", 404);
    await env.MEDIA.delete(ad.media_key).catch(() => {});
    await env.DB.prepare("DELETE FROM ads WHERE id = ?").bind(adPatchMatch[1]).run();
    await logAdmin(env, user.id, "ad_deleted", "ad", adPatchMatch[1]);
    return json({ ok: true });
  }

  // ----- notifications -----
  if (path === "/api/notifications" && method === "GET") {
    requireUser(user);
    const cursor = url.searchParams.get("cursor");
    let sql = `
      SELECT n.id, n.type, n.video_id, n.comment_id, n.read, n.created_at, n.body,
             a.id AS actor_id, a.username AS actor_username, a.display_name AS actor_display_name, a.avatar_key AS actor_avatar_key,
             v.thumb_key AS video_thumb_key
      FROM notifications n
      LEFT JOIN users a ON a.id = n.actor_id
      LEFT JOIN videos v ON v.id = n.video_id
      WHERE n.user_id = ?
    `;
    const binds = [user.id];
    if (cursor) { sql += " AND n.created_at < ?"; binds.push(parseInt(cursor)); }
    sql += " ORDER BY n.created_at DESC LIMIT 30";

    const { results } = await env.DB.prepare(sql).bind(...binds).all();
    return json({
      notifications: results.map(r => ({
        id: r.id,
        type: r.type,
        read: !!r.read,
        createdAt: r.created_at,
        videoId: r.video_id,
        videoThumb: r.video_thumb_key ? `/api/media/${r.video_thumb_key}` : null,
        actor: r.actor_id ? {
          id: r.actor_id, username: r.actor_username, displayName: r.actor_display_name,
          avatarUrl: r.actor_avatar_key ? `/api/media/${r.actor_avatar_key}` : null,
        } : null,
      })),
      nextCursor: results.length === 30 ? String(results[results.length - 1].created_at) : null,
    });
  }

  if (path === "/api/notifications/unread-count" && method === "GET") {
    requireUser(user);
    const r = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM notifications WHERE user_id = ? AND read = 0"
    ).bind(user.id).first();
    return json({ count: r.n });
  }

  if (path === "/api/notifications/read" && method === "POST") {
    requireUser(user);
    await env.DB.prepare("UPDATE notifications SET read = 1 WHERE user_id = ? AND read = 0").bind(user.id).run();
    return json({ ok: true });
  }

  // ----- admin broadcast: one announcement to every user -----
  //
  // Writes a notification row per recipient (so it appears in Activity like
  // anything else) and pushes it. Batched and run after the response, because
  // on a growing platform this is the one action whose cost scales with the
  // whole user base.
  if (path === "/api/admin/broadcast" && method === "POST") {
    requireUser(user);
    if (!isAdmin(user)) throw new HttpError("Admins only", 403);
    const { title, body } = await request.json().catch(() => ({}));
    const text = (body || "").trim();
    if (!text) return err("Write the message to send");
    const heading = (title || "Belople").trim().slice(0, 60);

    const { results: recipients } = await env.DB.prepare(
      "SELECT id FROM users WHERE status != 'banned' AND id != ?"
    ).bind(user.id).all();

    ctx.waitUntil((async () => {
      const at = now();
      for (const r of recipients) {
        try {
          // The text is stored, not just pushed: an announcement has no actor
          // or video to derive wording from, so without this the Activity list
          // showed an empty row and the message existed only in the push.
          await env.DB.prepare(`
            INSERT INTO notifications (id, user_id, actor_id, type, video_id, comment_id, read, created_at, body)
            VALUES (?, ?, ?, 'announcement', NULL, NULL, 0, ?, ?)
          `).bind(uid(), r.id, user.id, at, text).run();
          await Promise.all([
            sendPush(env, r.id, { title: heading, body: text, url: "/", tag: "announcement" }),
            sendFcm(env, r.id, {
              title: heading, body: text, url: "/", route: "/notifications",
              tag: "announcement", type: "announcement", avatar: null, actorName: null,
            }),
          ]);
        } catch (e) {
          console.error("broadcast to one user failed", e?.message || e);
        }
      }
    })());

    return json({ ok: true, recipients: recipients.length });
  }

  // ----- push self-test: sends a notification to your own devices and reports
  // exactly what FCM said. Push failures are invisible by design (they run in
  // waitUntil, off the request path), so without this the only symptom is
  // "nothing arrives" with nowhere to look. -----
  if (path === "/api/push/test" && method === "POST") {
    requireUser(user);
    const sa = serviceAccount(env);
    const report = {
      secretPresent: !!env.FCM_SERVICE_ACCOUNT,
      // Length only — never the value. A Windows console truncates pasted
      // input at 254 characters, so a service-account key pasted at a prompt
      // arrives cut in half and JSON.parse fails; the length is what makes that
      // diagnosable at a glance (a real key is ~2300).
      secretLength: env.FCM_SERVICE_ACCOUNT ? env.FCM_SERVICE_ACCOUNT.length : 0,
      secretParsed: !!sa,
      projectId: sa?.project_id || null,
      clientEmail: sa?.client_email || null,
      devices: 0,
      accessToken: false,
      sends: [],
    };
    if (!sa) return json(report);

    const { results: devices } = await env.DB.prepare(
      "SELECT token FROM fcm_devices WHERE user_id = ?"
    ).bind(user.id).all().catch(() => ({ results: [] }));
    report.devices = devices.length;

    let accessToken = null;
    try {
      accessToken = await fcmAccessToken(env);
    } catch (e) {
      report.accessTokenError = String(e?.message || e);
    }
    report.accessToken = !!accessToken;
    if (!accessToken || !devices.length) return json(report);

    const endpoint = `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`;
    for (const d of devices) {
      try {
        const res = await fetch(endpoint, {
          method: "POST",
          headers: { Authorization: `Bearer ${accessToken}`, "Content-Type": "application/json" },
          // Same data-only shape as a real notification, so this exercises the
          // path that actually ships rather than a simpler one that might pass
          // while the real one fails.
          body: JSON.stringify({
            message: {
              token: d.token,
              data: {
                title: "Belople",
                body: "Push is working 🎉",
                route: "/notifications",
                url: "/",
                tag: "test",
                type: "test",
                avatar: "",
                actor: "",
              },
              android: { priority: "HIGH" },
            },
          }),
        });
        report.sends.push({
          token: `${d.token.slice(0, 12)}…`,
          status: res.status,
          body: (await res.text().catch(() => "")).slice(0, 300),
        });
      } catch (e) {
        report.sends.push({ token: `${d.token.slice(0, 12)}…`, error: String(e?.message || e) });
      }
    }
    return json(report);
  }

  // ----- native app push: FCM device registration -----
  if (path === "/api/push/device" && method === "POST") {
    requireUser(user);
    const { token, platform } = await request.json().catch(() => ({}));
    if (!token) return err("Missing token");
    // Keyed on the token, not the user: reinstalling or signing in as someone
    // else on the same phone must MOVE the token, never leave the previous
    // owner still receiving that device's notifications.
    await env.DB.prepare(`
      INSERT INTO fcm_devices (token, user_id, platform, created_at, updated_at)
      VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(token) DO UPDATE SET
        user_id = excluded.user_id, platform = excluded.platform, updated_at = excluded.updated_at
    `).bind(token, user.id, platform === "ios" ? "ios" : "android", now(), now()).run();
    return json({ ok: true });
  }

  if (path === "/api/push/device" && method === "DELETE") {
    requireUser(user);
    const { token } = await request.json().catch(() => ({}));
    if (token) {
      await env.DB.prepare("DELETE FROM fcm_devices WHERE token = ? AND user_id = ?")
        .bind(token, user.id).run();
    }
    return json({ ok: true });
  }

  // ----- web push subscriptions -----
  if (path === "/api/push/subscribe" && method === "POST") {
    requireUser(user);
    const { endpoint, keys } = await request.json();
    if (!endpoint || !keys?.p256dh || !keys?.auth) return err("Invalid subscription");
    await env.DB.prepare(`
      INSERT INTO push_subscriptions (id, user_id, endpoint, p256dh, auth, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(endpoint) DO UPDATE SET user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth
    `).bind(uid(), user.id, endpoint, keys.p256dh, keys.auth, now()).run();
    return json({ ok: true });
  }

  if (path === "/api/push/unsubscribe" && method === "POST") {
    requireUser(user);
    const { endpoint } = await request.json();
    if (endpoint) await env.DB.prepare("DELETE FROM push_subscriptions WHERE endpoint = ? AND user_id = ?").bind(endpoint, user.id).run();
    return json({ ok: true });
  }


  // ----- upload -----
  if (path === "/api/videos" && method === "POST") {
    requireUser(user);
    const form = await request.formData();
    const file = form.get("video");
    if (!file || typeof file === "string") return err("A video file is required");

    const maxBytes = parseInt(env.MAX_UPLOAD_BYTES || "104857600");
    if (file.size > maxBytes) return err(`Video must be under ${Math.round(maxBytes / 1048576)}MB`, 413);
    if (!/^video\//.test(file.type)) return err("That file isn't a video");

    const id = uid();
    const ext = (file.name?.split(".").pop() || "mp4").toLowerCase();
    const key = `videos/${user.id}/${id}.${ext}`;

    const duration = parseFloat(form.get("duration")) || null;
    if (duration && duration > 601) return err("Video must be 10 minutes or shorter");

    const visibility = form.get("visibility") || "public";
    if (!["public", "followers", "private"].includes(visibility)) {
      return err("visibility must be public, followers or private");
    }

    await env.MEDIA.put(key, file.stream(), {
      httpMetadata: { contentType: file.type || "video/mp4" },
    });

    let thumbKey = null;
    const thumb = form.get("thumbnail");
    if (thumb && typeof thumb !== "string") {
      thumbKey = `thumbs/${user.id}/${id}.jpg`;
      await env.MEDIA.put(thumbKey, thumb.stream(), {
        httpMetadata: { contentType: thumb.type || "image/jpeg" },
      });
    }

    // A video either USES an existing shareable sound (soundId, picked from
    // that sound's page) or may become a new shareable sound itself
    // (soundShareable, an opt-in checkbox at post time — default off, since
    // handing someone's audio to everyone by default is a rights question,
    // not just a technical one). It can't be both.
    const useSoundId = form.get("soundId") || null;
    let soundId = null;
    if (useSoundId) {
      const sound = await env.DB.prepare("SELECT id FROM sounds WHERE id = ?").bind(useSoundId).first();
      if (!sound) return err("That sound isn't available anymore");
      soundId = sound.id;
    }

    await env.DB.prepare(`
      INSERT INTO videos (id, user_id, r2_key, thumb_key, caption, song, width, height, duration, visibility, sound_id, created_at, category, countries)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      id, user.id, key, thumbKey,
      form.get("caption") || "",
      form.get("song") || `Original sound - ${user.username}`,
      parseInt(form.get("width")) || null,
      parseInt(form.get("height")) || null,
      duration,
      visibility,
      soundId,
      now(),
      // Both optional. A video with no category still ranks — Belo Flow falls
      // back to topics read from the caption — it just doesn't get the direct
      // interest match. No countries means shown everywhere.
      isValidCategory(form.get("category")) ? form.get("category") : null,
      normalizeCountries(form.get("countries"))
    ).run();

    if (useSoundId) {
      await env.DB.prepare("UPDATE sounds SET uses = uses + 1 WHERE id = ?").bind(useSoundId).run();
    } else if (form.get("soundShareable") === "1") {
      const newSoundId = uid();
      await env.DB.prepare(`
        INSERT INTO sounds (id, title, author_user_id, source_video_id, r2_key, uses, created_at)
        VALUES (?, ?, ?, ?, ?, 0, ?)
      `).bind(newSoundId, form.get("song") || `Original sound - ${user.username}`, user.id, id, key, now()).run();
      await env.DB.prepare("UPDATE videos SET sound_id = ? WHERE id = ?").bind(newSoundId, id).run();
    }

    // Tell this creator's followers there's something new. Public uploads only
    // — a followers-only or private post shouldn't announce itself beyond who
    // can open it. Runs after the response (waitUntil) so a creator with many
    // followers never waits on the fan-out, and is capped so one upload can't
    // become an unbounded write burst.
    if (visibility === "public") {
      const caption = (form.get("caption") || "").slice(0, 120);
      ctx.waitUntil((async () => {
        try {
          const { results: followers } = await env.DB.prepare(`
            SELECT follower_id FROM follows
            WHERE followee_id = ? AND status = 'accepted'
            ORDER BY created_at DESC LIMIT 500
          `).bind(user.id).all();
          for (const f of followers || []) {
            await notify(env, ctx, f.follower_id, user.id, "post", { videoId: id, text: caption });
          }
        } catch (e) {
          console.error("new-post fan-out failed", e?.message || e);
        }
      })());
    }

    const row = await env.DB.prepare(FEED_SQL + " WHERE v.id = ?").bind(user.id, user.id, id).first();
    return json({ video: shapeVideo(row) }, 201);
  }

  // ----- single video -----
  const videoMatch = /^\/api\/videos\/([\w-]+)$/.exec(path);
  if (videoMatch && method === "GET") {
    // Visibility was never checked here. Every list endpoint filters, but this
    // one fetched by id alone — so a "Private" or followers-only video was
    // readable by anyone who had the id, which is exactly what a share link
    // hands out. The same rule the feed uses is applied here: yours always,
    // public when the account is public, followers-only when you actually
    // follow them, and private to nobody but the owner.
    const viewerId = user?.id || "";
    const row = await env.DB.prepare(FEED_SQL + `
      WHERE v.id = ? AND (
        v.user_id = ?
        OR (v.visibility = 'public' AND u.is_private = 0)
        OR ((v.visibility = 'followers' OR u.is_private = 1) AND v.visibility != 'private' AND EXISTS(
              SELECT 1 FROM follows f
              WHERE f.follower_id = ? AND f.followee_id = v.user_id AND f.status = 'accepted'))
      )`)
      .bind(viewerId, viewerId, videoMatch[1], viewerId, viewerId).first();
    // Deliberately the same 404 as a missing video: a distinct "no permission"
    // would confirm to a stranger that the id exists.
    if (!row) return err("Video not found", 404);
    return json({ video: shapeVideo(row) });
  }

  // ----- edit your own video: visibility, category, target countries -----
  //
  // Deleting was the only thing you could do to a video you'd already posted,
  // so a clip published to the wrong audience had to be deleted and re-uploaded
  // — losing its likes, comments and watch history with it.
  if (videoMatch && method === "PATCH") {
    requireUser(user);
    const own = await env.DB.prepare("SELECT user_id FROM videos WHERE id = ?").bind(videoMatch[1]).first();
    if (!own) return err("Video not found", 404);
    if (own.user_id !== user.id && !isStaff(user)) return err("That isn't your video", 403);

    const patch = await request.json().catch(() => ({}));
    const sets = [];
    const binds = [];

    if (patch.visibility !== undefined) {
      if (!["public", "followers", "private"].includes(patch.visibility)) {
        return err("visibility must be public, followers or private");
      }
      sets.push("visibility = ?");
      binds.push(patch.visibility);
    }
    if (patch.category !== undefined) {
      // null clears it; anything else has to be a real category.
      if (patch.category !== null && !isValidCategory(patch.category)) {
        return err("That isn't one of the categories");
      }
      sets.push("category = ?");
      binds.push(patch.category);
    }
    if (patch.countries !== undefined) {
      sets.push("countries = ?");
      binds.push(normalizeCountries(patch.countries));
    }
    if (!sets.length) return err("Nothing to change");

    binds.push(videoMatch[1]);
    await env.DB.prepare(`UPDATE videos SET ${sets.join(", ")} WHERE id = ?`).bind(...binds).run();

    const viewerId = user.id;
    const row = await env.DB.prepare(FEED_SQL + " WHERE v.id = ?")
      .bind(viewerId, viewerId, videoMatch[1]).first();
    return json({ video: shapeVideo(row) });
  }

  if (videoMatch && method === "DELETE") {
    requireUser(user);
    const v = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(videoMatch[1]).first();
    if (!v) return err("Video not found", 404);
    if (v.user_id !== user.id) return err("That isn't your video", 403);

    // This video's audio may be the r2 object other people's videos point at
    // as their sound. Deleting it here would 404 that audio for everyone
    // already using it, silently — refuse instead. If nobody has used it yet,
    // the sound row is deleted along with the video instead of turning into
    // a dead link that still shows up in sound search.
    //
    // The gate below counts live from `videos`, not from `sounds.uses` —
    // `uses` is only a display counter incremented on reuse, and if it were
    // ever trusted here without also being decremented when a REUSING video
    // is deleted (handled further down), it would drift upward forever and
    // permanently lock the original owner out of deleting their own video.
    let orphanedSoundId = null;
    if (v.sound_id) {
      const sound = await env.DB.prepare("SELECT source_video_id FROM sounds WHERE id = ?")
        .bind(v.sound_id).first();
      if (sound && sound.source_video_id === v.id) {
        const stillUsed = await env.DB.prepare(
          "SELECT COUNT(*) AS n FROM videos WHERE sound_id = ? AND id != ?"
        ).bind(v.sound_id, v.id).first();
        if (stillUsed.n > 0) {
          return err("Other people's videos use this video's sound — can't delete it while that's true", 409);
        }
        orphanedSoundId = v.sound_id;
      }
    }

    await env.MEDIA.delete(v.r2_key);
    if (v.thumb_key) await env.MEDIA.delete(v.thumb_key);
    // Clears gifts, messages, reports and reposts too — this path only knew
    // about likes, comments and shares, so deleting a video anyone had
    // reported, gifted or shared into a chat failed on the foreign key.
    await deleteVideoEverywhere(env, v, { orphanedSoundId });
    return json({ ok: true });
  }

  // ----- view + watch signal (feeds Belo Flow's "I just saw this" memory) -----
  const viewMatch = /^\/api\/videos\/([\w-]+)\/view$/.exec(path);
  if (viewMatch && method === "POST") {
    const videoId = viewMatch[1];
    // Raw counter stays (backwards compatible); ranking uses DISTINCT viewers.
    await env.DB.prepare("UPDATE videos SET views = views + 1 WHERE id = ?").bind(videoId).run();

    // Optional watch payload from the player: how long/how much was watched, and
    // whether it was an early swipe, a replay, or a "not interested". All best-
    // effort — a bare view (no body) still works. Only recorded for signed-in
    // users, since exposures are per-viewer.
    if (user) {
      try {
        const body = await request.json().catch(() => ({}));
        const meta = await env.DB.prepare(
          "SELECT v.duration, v.caption, COALESCE(v.repost_of, v.id) AS content_id, " +
          "COALESCE(ru.id, u.id) AS creator_id, cu.interests AS creator_interests " +
          "FROM videos v JOIN users u ON u.id = v.user_id " +
          "LEFT JOIN videos rv ON rv.id = v.repost_of LEFT JOIN users ru ON ru.id = rv.user_id " +
          "LEFT JOIN users cu ON cu.id = COALESCE(ru.id, u.id) WHERE v.id = ?"
        ).bind(videoId).first();
        if (meta) {
          const durationMs = Math.round(((body.durationMs ?? (meta.duration || 0) * 1000)) || 0);
          const watchMs = Math.max(0, Math.round(body.watchMs || 0));
          const completion = durationMs > 0 ? Math.min(1, watchMs / durationMs) : 0;
          await recordExposure(env, {
            viewerId: user.id,
            videoId,
            creatorId: meta.creator_id,
            caption: meta.caption || "",
            declaredInterests: meta.creator_interests || [],
            watchMs,
            durationMs,
            completed: completion >= 0.9 || !!body.completed,
            // An early swipe: less than 2s watched AND under 20% of the clip.
            skipped: !!body.skipped || (watchMs > 0 && watchMs < 2000 && completion < 0.2),
            replayed: !!body.replayed,
            notInterested: !!body.notInterested,
          });
        }
      } catch (_) { /* never let signal capture break the view call */ }
    }
    return json({ ok: true });
  }

  // ----- "not interested" — a strong negative signal (hides similar content) -----
  const notInterestedMatch = /^\/api\/videos\/([\w-]+)\/not-interested$/.exec(path);
  if (notInterestedMatch && method === "POST") {
    requireUser(user);
    const videoId = notInterestedMatch[1];
    const meta = await env.DB.prepare(
      "SELECT v.caption, COALESCE(ru.id, u.id) AS creator_id, cu.interests AS creator_interests " +
      "FROM videos v JOIN users u ON u.id = v.user_id " +
      "LEFT JOIN videos rv ON rv.id = v.repost_of LEFT JOIN users ru ON ru.id = rv.user_id " +
      "LEFT JOIN users cu ON cu.id = COALESCE(ru.id, u.id) WHERE v.id = ?"
    ).bind(videoId).first();
    if (meta) {
      await recordExposure(env, {
        viewerId: user.id, videoId, creatorId: meta.creator_id,
        caption: meta.caption || "", declaredInterests: meta.creator_interests || [],
        notInterested: true,
      });
    }
    return json({ ok: true });
  }

  // ----- Belo Flow: runtime-tunable weights (admin) -----
  if (path === "/api/reco/config" && method === "GET") {
    requireUser(user);
    if (!isAdmin(user)) throw new HttpError("Admins only", 403);
    return json({ config: await loadConfig(env), defaults: DEFAULT_CONFIG });
  }
  if (path === "/api/reco/config" && method === "PATCH") {
    requireUser(user);
    if (!isAdmin(user)) throw new HttpError("Admins only", 403);
    const patch = await request.json().catch(() => ({}));
    // Validate by merging onto defaults, then persist the merged result.
    const merged = mergeConfig(patch);
    await env.DB.prepare(
      "INSERT INTO reco_config (id, json, updated_at) VALUES (1, ?, ?) " +
      "ON CONFLICT(id) DO UPDATE SET json = ?, updated_at = ?"
    ).bind(JSON.stringify(merged), now(), JSON.stringify(merged), now()).run();
    return json({ config: merged });
  }

  // ----- Belo Flow analytics: platform overview (admin) -----
  if (path === "/api/analytics/overview" && method === "GET") {
    requireUser(user);
    if (!isAdmin(user)) throw new HttpError("Admins only", 403);
    const dayAgo = now() - 24 * 3600 * 1000;
    const weekAgo = now() - 7 * 24 * 3600 * 1000;
    const [users, content, engagement, dau, wau] = await Promise.all([
      env.DB.prepare("SELECT COUNT(*) AS n FROM users").first(),
      env.DB.prepare("SELECT COUNT(*) AS n FROM videos").first(),
      env.DB.prepare(
        "SELECT COUNT(*) AS exposures, COUNT(DISTINCT user_id) AS viewers, " +
        "AVG(completion) AS avg_completion, AVG(watch_ms) AS avg_watch_ms, " +
        "SUM(CASE WHEN skipped > 0 THEN 1 ELSE 0 END) AS skip_events " +
        "FROM video_exposures"
      ).first().catch(() => ({})),
      env.DB.prepare("SELECT COUNT(DISTINCT user_id) AS n FROM video_exposures WHERE last_seen_at > ?").bind(dayAgo).first().catch(() => ({ n: 0 })),
      env.DB.prepare("SELECT COUNT(DISTINCT user_id) AS n FROM video_exposures WHERE last_seen_at > ?").bind(weekAgo).first().catch(() => ({ n: 0 })),
    ]);
    const exposures = engagement.exposures || 0;
    return json({
      users: users.n, videos: content.n,
      dau: dau.n || 0, wau: wau.n || 0,
      exposures, uniqueViewers: engagement.viewers || 0,
      avgCompletion: round3(engagement.avg_completion), avgWatchMs: Math.round(engagement.avg_watch_ms || 0),
      skipRate: exposures ? round3((engagement.skip_events || 0) / exposures) : 0,
    });
  }

  // ----- Belo Flow analytics: a creator's own reach/discovery metrics -----
  if (path === "/api/analytics/creator" && method === "GET") {
    requireUser(user);
    const followers = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM follows WHERE followee_id = ? AND status = 'accepted'"
    ).bind(user.id).first();
    const m = await env.DB.prepare(
      "SELECT COUNT(DISTINCT e.user_id) AS unique_viewers, COUNT(*) AS exposures, " +
      "AVG(e.completion) AS avg_completion, AVG(e.watch_ms) AS avg_watch_ms, " +
      "SUM(e.replay_count) AS replays, SUM(e.followed_creator) AS follows_generated, " +
      "SUM(e.skipped) AS skips " +
      "FROM video_exposures e WHERE e.creator_id = ?"
    ).bind(user.id).first().catch(() => ({}));
    const vids = await env.DB.prepare("SELECT COUNT(*) AS n FROM videos WHERE user_id = ?").bind(user.id).first();
    const uniq = m.unique_viewers || 0;
    return json({
      videos: vids.n, followers: followers.n,
      uniqueViewers: uniq, exposures: m.exposures || 0,
      avgWatchQuality: round3(m.avg_completion), avgWatchMs: Math.round(m.avg_watch_ms || 0),
      replays: m.replays || 0,
      // Follower conversion: of the people reached, how many followed.
      followerConversion: uniq ? round3((m.follows_generated || 0) / uniq) : 0,
      // Discovery rate: share of viewers who don't already follow the creator.
      discoveryRate: uniq ? round3(Math.max(0, uniq - followers.n) / uniq) : 0,
    });
  }

  // ----- likes -----
  const likeMatch = /^\/api\/videos\/([\w-]+)\/like$/.exec(path);
  if (likeMatch && (method === "POST" || method === "DELETE")) {
    requireUser(user);
    const videoId = await resolveContentId(env, likeMatch[1]);

    if (method === "POST") {
      await env.DB.prepare(
        "INSERT OR IGNORE INTO likes (user_id, video_id, created_at) VALUES (?, ?, ?)"
      ).bind(user.id, videoId, now()).run();
      const owner = await env.DB.prepare("SELECT user_id FROM videos WHERE id = ?").bind(videoId).first();
      if (owner) await notify(env, ctx, owner.user_id, user.id, "like", { videoId });
      await markExposureSignal(env, { viewerId: user.id, videoId, field: "liked" });
    } else {
      await env.DB.prepare(
        "DELETE FROM likes WHERE user_id = ? AND video_id = ?"
      ).bind(user.id, videoId).run();
    }

    const c = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM likes WHERE video_id = ?"
    ).bind(videoId).first();
    return json({ liked: method === "POST", count: c.n });
  }

  // ----- comments -----
  const commentMatch = /^\/api\/videos\/([\w-]+)\/comments$/.exec(path);
  if (commentMatch && method === "GET") {
    const viewerId = user?.id || "";
    const videoId = await resolveContentId(env, commentMatch[1]);
    const { results } = await env.DB.prepare(`
      SELECT c.id, c.body, c.created_at, c.parent_id,
             u.id AS user_id, u.username, u.display_name, u.avatar_key,
             (SELECT COUNT(*) FROM comment_reactions r
               WHERE r.comment_id = c.id AND r.kind = 'like')     AS likes,
             (SELECT COUNT(*) FROM comment_reactions r
               WHERE r.comment_id = c.id AND r.kind = 'dislike')  AS dislikes,
             (SELECT r.kind FROM comment_reactions r
               WHERE r.comment_id = c.id AND r.user_id = ?)       AS my_reaction
      FROM comments c JOIN users u ON u.id = c.user_id
      WHERE c.video_id = ?
      ORDER BY c.created_at ASC LIMIT 300
    `).bind(viewerId, videoId).all();

    const shape = c => ({
      id: c.id,
      body: c.body,
      createdAt: c.created_at,
      parentId: c.parent_id,
      likes: c.likes,
      dislikes: c.dislikes,
      myReaction: c.my_reaction || null,
      user: {
        id: c.user_id,
        username: c.username,
        displayName: c.display_name,
        avatarUrl: c.avatar_key ? `/api/media/${c.avatar_key}` : null,
      },
      replies: [],
    });

    // Nest replies under their parent, newest threads first
    const byId = new Map();
    const roots = [];
    results.forEach(c => byId.set(c.id, shape(c)));
    results.forEach(c => {
      const node = byId.get(c.id);
      const parent = c.parent_id && byId.get(c.parent_id);
      parent ? parent.replies.push(node) : roots.push(node);
    });
    roots.reverse();

    return json({ comments: roots, total: results.length });
  }

  if (commentMatch && method === "POST") {
    requireUser(user);
    const { body, parentId } = await request.json();
    if (!body?.trim()) return err("Write something first");
    if (body.length > 500) return err("Comment must be under 500 characters");
    const videoId = await resolveContentId(env, commentMatch[1]);

    // Respect the video owner's "who can comment" choice. The owner can always
    // comment on their own video; otherwise nobody blocks everyone, and
    // followers limits it to people who follow the owner.
    const vid = await env.DB.prepare(
      "SELECT v.user_id, u.allow_comments FROM videos v JOIN users u ON u.id = v.user_id WHERE v.id = ?"
    ).bind(videoId).first();
    if (!vid) return err("Video not found", 404);
    if (vid.user_id !== user.id) {
      const pref = vid.allow_comments || "everyone";
      if (pref === "nobody") return err("Comments are turned off for this video", 403);
      if (pref === "followers") {
        const follows = await env.DB.prepare(
          "SELECT 1 FROM follows WHERE follower_id = ? AND followee_id = ? AND status = 'accepted'"
        ).bind(user.id, vid.user_id).first();
        if (!follows) return err("Only followers can comment on this video", 403);
      }
    }

    // A reply attaches to the top-level comment, so threads stay one level deep
    let rootId = null;
    let parentAuthorId = null;
    if (parentId) {
      const parent = await env.DB.prepare(
        "SELECT id, parent_id, video_id, user_id FROM comments WHERE id = ?"
      ).bind(parentId).first();
      if (!parent) return err("That comment no longer exists", 404);
      if (parent.video_id !== videoId) return err("Comment doesn't belong to this video");
      rootId = parent.parent_id || parent.id;
      parentAuthorId = parent.user_id;
    }

    const id = uid();
    await env.DB.prepare(
      "INSERT INTO comments (id, video_id, user_id, body, parent_id, created_at) VALUES (?, ?, ?, ?, ?, ?)"
    ).bind(id, videoId, user.id, body.trim(), rootId, now()).run();
    await markExposureSignal(env, { viewerId: user.id, videoId, field: "commented" });

    await notify(env, ctx, vid.user_id, user.id, "comment", { videoId, commentId: id, text: body.trim() });
    if (parentAuthorId && parentAuthorId !== vid.user_id) {
      await notify(env, ctx, parentAuthorId, user.id, "reply", { videoId, commentId: id, text: body.trim() });
    }

    const c = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM comments WHERE video_id = ?"
    ).bind(videoId).first();

    return json({
      comment: {
        id, body: body.trim(), createdAt: now(), parentId: rootId,
        likes: 0, dislikes: 0, myReaction: null, replies: [],
        user: publicUser(user),
      },
      count: c.n,
    }, 201);
  }

  // ----- comment reactions (like / dislike) -----
  const reactMatch = /^\/api\/comments\/([\w-]+)\/react$/.exec(path);
  if (reactMatch && method === "POST") {
    requireUser(user);
    const { kind } = await request.json();
    if (!["like", "dislike"].includes(kind)) return err("kind must be like or dislike");

    const existing = await env.DB.prepare(
      "SELECT kind FROM comment_reactions WHERE user_id = ? AND comment_id = ?"
    ).bind(user.id, reactMatch[1]).first();

    // Tapping the same reaction again clears it; the other one replaces it.
    if (existing?.kind === kind) {
      await env.DB.prepare(
        "DELETE FROM comment_reactions WHERE user_id = ? AND comment_id = ?"
      ).bind(user.id, reactMatch[1]).run();
    } else {
      await env.DB.prepare(`
        INSERT INTO comment_reactions (user_id, comment_id, kind, created_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(user_id, comment_id) DO UPDATE SET kind = excluded.kind
      `).bind(user.id, reactMatch[1], kind, now()).run();
    }

    const counts = await env.DB.prepare(`
      SELECT
        (SELECT COUNT(*) FROM comment_reactions WHERE comment_id = ? AND kind = 'like')    AS likes,
        (SELECT COUNT(*) FROM comment_reactions WHERE comment_id = ? AND kind = 'dislike') AS dislikes
    `).bind(reactMatch[1], reactMatch[1]).first();

    return json({
      likes: counts.likes,
      dislikes: counts.dislikes,
      myReaction: existing?.kind === kind ? null : kind,
    });
  }

  const commentDelMatch = /^\/api\/comments\/([\w-]+)$/.exec(path);
  if (commentDelMatch && method === "DELETE") {
    requireUser(user);
    const c = await env.DB.prepare("SELECT * FROM comments WHERE id = ?").bind(commentDelMatch[1]).first();
    if (!c) return err("Comment not found", 404);
    if (c.user_id !== user.id) return err("That isn't your comment", 403);

    // Collect this comment and every descendant, however deep the chain runs,
    // then delete children before parents so no foreign key is left dangling.
    const { results: doomed } = await env.DB.prepare(`
      WITH RECURSIVE tree(id, depth) AS (
        SELECT id, 0 FROM comments WHERE id = ?
        UNION ALL
        SELECT c.id, tree.depth + 1
        FROM comments c JOIN tree ON c.parent_id = tree.id
      )
      SELECT id, depth FROM tree ORDER BY depth DESC
    `).bind(c.id).all();

    const ids = doomed.map(r => r.id);
    const marks = ids.map(() => "?").join(",");

    const ops = [
      env.DB.prepare(`DELETE FROM comment_reactions WHERE comment_id IN (${marks})`).bind(...ids),
    ];
    // deepest first
    for (const row of doomed) {
      ops.push(env.DB.prepare("DELETE FROM comments WHERE id = ?").bind(row.id));
    }
    await env.DB.batch(ops);

    const cnt = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM comments WHERE video_id = ?"
    ).bind(c.video_id).first();

    return json({ ok: true, count: cnt.n });
  }

  // ----- shares -----
  const shareMatch = /^\/api\/videos\/([\w-]+)\/share$/.exec(path);
  if (shareMatch && method === "POST") {
    requireUser(user);
    const shareId = uid();
    // The link stays pointed at whatever the person was actually looking at
    // (shareMatch[1]) — if that's a repost, the recipient should still see
    // "reposted by X". The count is attributed to the underlying content
    // (resolveContentId) so it matches likes/comments/gifts and doesn't
    // reset to zero for every repost of something already popular.
    const contentId = await resolveContentId(env, shareMatch[1]);
    // Row starts uncompleted — this only means a share link was generated,
    // not that it went anywhere. The count below (and everywhere else that
    // shows a share count) only counts completed=1, so tapping Share and
    // then cancelling the native share sheet — or never picking an app in
    // the "More" sheet — doesn't move the number. POST /shares/:id/complete
    // is what actually counts it, once the share genuinely happens.
    await env.DB.prepare(
      "INSERT INTO shares (id, video_id, user_id, created_at, completed) VALUES (?, ?, ?, ?, 0)"
    ).bind(shareId, contentId, user.id, now()).run();

    const c = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM shares WHERE video_id = ? AND completed = 1"
    ).bind(contentId).first();
    // ?s= is this specific share event, not just the video — it's how the
    // person who opens the link finds out who sent it to them.
    // Always the brand domain, never whatever origin the request happened to
    // arrive on — a shared link is the first thing a stranger sees of Belople,
    // and "video-app.ngwinoreal.workers.dev" isn't it.
    return json({ count: c.n, shareId, url: `${PUBLIC_ORIGIN}/v/${shareMatch[1]}?s=${shareId}` });
  }

  // Marks a share as having actually reached somewhere — navigator.share
  // resolved without being cancelled, a clipboard copy succeeded, or a
  // share-app deep link was opened. Idempotent, and checks ownership so
  // only the person who generated the link can complete it.
  const shareCompleteMatch = /^\/api\/shares\/([\w-]+)\/complete$/.exec(path);
  if (shareCompleteMatch && method === "POST") {
    requireUser(user);
    const share = await env.DB.prepare(
      "SELECT video_id, user_id FROM shares WHERE id = ?"
    ).bind(shareCompleteMatch[1]).first();
    if (!share) return err("Share not found", 404);
    if (share.user_id !== user.id) return err("That isn't your share", 403);

    await env.DB.prepare("UPDATE shares SET completed = 1 WHERE id = ?").bind(shareCompleteMatch[1]).run();
    // Marked here, not when the link was generated: this is the point the share
    // actually happened, which is what the ranking signal is supposed to mean.
    await markExposureSignal(env, { viewerId: share.user_id, videoId: share.video_id, field: "shared" });
    const c = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM shares WHERE video_id = ? AND completed = 1"
    ).bind(share.video_id).first();
    return json({ count: c.n });
  }

  // Resolves a share link's ?s= token to who actually sent it, so the
  // recipient sees "Shared by @username" instead of a bare video.
  const shareLookupMatch = /^\/api\/shares\/([\w-]+)$/.exec(path);
  if (shareLookupMatch && method === "GET") {
    const row = await env.DB.prepare(`
      SELECT s.video_id, u.id AS user_id, u.username, u.display_name, u.avatar_key
      FROM shares s JOIN users u ON u.id = s.user_id
      WHERE s.id = ?
    `).bind(shareLookupMatch[1]).first();
    if (!row) return err("Share link not found", 404);
    return json({
      videoId: row.video_id,
      sharedBy: {
        id: row.user_id, username: row.username, displayName: row.display_name,
        avatarUrl: row.avatar_key ? `/api/media/${row.avatar_key}` : null,
      },
    });
  }

  // ----- sounds -----
  // GET /api/sounds/search must come before /api/sounds/:id or "search"
  // would be parsed as an id.
  if (path === "/api/sounds/search" && method === "GET") {
    const q = (url.searchParams.get("q") || "").trim();

    // Everything a picker row needs, from data we already had and weren't
    // sending: the source video's thumbnail is the sound's cover art, and its
    // duration is the sound's length. Its caption is a fallback name — every
    // sound is titled "Original sound - <username>" (nothing ever asks the
    // poster for a title), so a search returned four identical rows with no
    // way to tell them apart.
    const SELECT = `
      SELECT snd.id, snd.title, snd.uses, snd.r2_key, snd.created_at,
             u.username AS author_username, u.display_name AS author_display_name,
             v.thumb_key AS cover_key, v.duration AS duration, v.caption AS source_caption
      FROM sounds snd
      JOIN users u ON u.id = snd.author_user_id
      LEFT JOIN videos v ON v.id = snd.source_video_id
    `;

    // An empty box used to return an empty list, so the sheet opened blank and
    // you had to already know what you were looking for. The most-used sounds
    // are a better answer to "what's here?" than nothing.
    const { results } = q
      ? await env.DB.prepare(`${SELECT}
          WHERE snd.title LIKE ? OR u.username LIKE ? OR v.caption LIKE ?
          ORDER BY snd.uses DESC LIMIT 30
        `).bind(`%${q}%`, `%${q}%`, `%${q}%`).all()
      : await env.DB.prepare(`${SELECT}
          ORDER BY snd.uses DESC, snd.created_at DESC LIMIT 30
        `).all();

    return json({
      sounds: results.map(s => ({
        id: s.id,
        title: s.title,
        uses: s.uses,
        audioUrl: `/api/media/${s.r2_key}`,
        coverUrl: s.cover_key ? `/api/media/${s.cover_key}` : null,
        duration: s.duration || null,
        // Shown under the title when the sound has no name of its own, so two
        // clips by the same person read as two different sounds.
        sourceCaption: (s.source_caption || "").trim() || null,
        author: { username: s.author_username, displayName: s.author_display_name },
      })),
    });
  }

  const soundMatch = /^\/api\/sounds\/([\w-]+)$/.exec(path);
  if (soundMatch && method === "GET") {
    const sound = await env.DB.prepare(`
      SELECT snd.id, snd.title, snd.uses, snd.created_at, snd.r2_key, snd.source_video_id,
             u.id AS author_id, u.username AS author_username, u.display_name AS author_display_name,
             u.avatar_key AS author_avatar_key,
             -- Same three the picker needs, for the same reason: the source
             -- video is where a sound's cover, its length and its only real
             -- name come from.
             v.thumb_key AS cover_key, v.duration AS duration, v.caption AS source_caption
      FROM sounds snd
      JOIN users u ON u.id = snd.author_user_id
      LEFT JOIN videos v ON v.id = snd.source_video_id
      WHERE snd.id = ?
    `).bind(soundMatch[1]).first();
    if (!sound) return err("Sound not found", 404);

    const { results } = await env.DB.prepare(
      FEED_SQL + " WHERE v.sound_id = ? ORDER BY v.created_at DESC LIMIT 60"
    ).bind(user?.id || "", user?.id || "", sound.id).all();

    return json({
      sound: {
        id: sound.id,
        title: sound.title,
        uses: sound.uses,
        audioUrl: `/api/media/${sound.r2_key}`,
        coverUrl: sound.cover_key ? `/api/media/${sound.cover_key}` : null,
        duration: sound.duration || null,
        sourceCaption: (sound.source_caption || "").trim() || null,
        author: {
          id: sound.author_id, username: sound.author_username,
          displayName: sound.author_display_name,
          avatarUrl: sound.author_avatar_key ? `/api/media/${sound.author_avatar_key}` : null,
        },
      },
      videos: results.map(shapeVideo),
    });
  }

  // ----- repost -----
  const repostMatch = /^\/api\/videos\/([\w-]+)\/repost$/.exec(path);
  if (repostMatch && method === "POST") {
    requireUser(user);
    const target = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(repostMatch[1]).first();
    if (!target) return err("Video not found", 404);
    // Reposting a repost points at the TRUE original, not at that repost —
    // otherwise reposts could chain, and the engagement-rollup in FEED_SQL
    // (COALESCE(v.repost_of, v.id), one hop) would stop finding the real
    // content two hops down.
    const original = target.repost_of
      ? await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(target.repost_of).first()
      : target;
    if (!original) return err("Video not found", 404);
    // The frontend already hides the repost button on your own video — this
    // is the same rule enforced server-side, since the endpoint itself
    // doesn't otherwise know or care who's calling it.
    if (original.user_id === user.id) return err("You can't repost your own video", 400);

    const dupe = await env.DB.prepare(
      "SELECT id FROM videos WHERE user_id = ? AND repost_of = ?"
    ).bind(user.id, original.id).first();
    if (dupe) return err("You already reposted this", 409);

    const id = uid();
    try {
      // Reposts point at the same R2 object — no file is copied.
      await env.DB.prepare(`
        INSERT INTO videos (id, user_id, r2_key, thumb_key, caption, song, width, height, duration, repost_of, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).bind(
        id, user.id, original.r2_key, original.thumb_key,
        original.caption, original.song, original.width, original.height,
        original.duration, original.id, now()
      ).run();
    } catch (e) {
      // The check above isn't atomic with the insert — two taps within the
      // same instant (the rail's repost icon and the "More" sheet's Repost
      // row both call this) can both pass it. idx_videos_unique_repost is
      // the real guard; this just turns its rejection into the same
      // friendly message as the check above instead of a raw 500.
      if (String(e.message || "").includes("UNIQUE")) return err("You already reposted this", 409);
      throw e;
    }

    await notify(env, ctx, original.user_id, user.id, "repost", { videoId: original.id });

    const row = await env.DB.prepare(FEED_SQL + " WHERE v.id = ?").bind(user.id, user.id, id).first();
    return json({ video: shapeVideo(row) }, 201);
  }

  // Un-repost (toggle off): remove the caller's repost of this video. Works
  // whether they tapped the original or a repost of it — both resolve to the
  // same true original the repost row points at.
  if (repostMatch && method === "DELETE") {
    requireUser(user);
    const target = await env.DB.prepare("SELECT id, repost_of FROM videos WHERE id = ?")
      .bind(repostMatch[1]).first();
    if (!target) return err("Video not found", 404);
    const originalId = target.repost_of || target.id;
    // A repost row points at the same R2 object (no file copy) and carries no
    // sound of its own, so removing it is just deleting that row.
    await env.DB.prepare("DELETE FROM videos WHERE user_id = ? AND repost_of = ?")
      .bind(user.id, originalId).run();
    return json({ ok: true });
  }

  // ----- follows / friend requests -----
  const followMatch = /^\/api\/users\/([\w-]+)\/follow$/.exec(path);
  if (followMatch && (method === "POST" || method === "DELETE")) {
    requireUser(user);
    const targetId = followMatch[1];
    if (targetId === user.id) return err("You can't follow yourself");

    if (method === "POST") {
      // A PRIVATE account has to approve its followers. This wrote 'accepted'
      // unconditionally, so marking an account private did nothing at all —
      // anyone could follow it and immediately see followers-only content. The
      // pending queue and its approve/reject endpoints already existed; nothing
      // was ever putting a row in it.
      const target = await env.DB.prepare("SELECT is_private FROM users WHERE id = ?")
        .bind(targetId).first();
      if (!target) return err("Account not found", 404);
      const status = target.is_private ? "pending" : "accepted";

      await env.DB.prepare(`
        INSERT OR IGNORE INTO follows (follower_id, followee_id, status, created_at)
        VALUES (?, ?, ?, ?)
      `).bind(user.id, targetId, status, now()).run();

      // A request isn't a follow: don't tell them someone started following
      // them, and don't credit the video with a follow that hasn't happened.
      if (status === "accepted") {
        await notify(env, ctx, targetId, user.id, "follow", { username: user.username });
        // Attribute the follow to the creator's last video this viewer saw — that
        // video is what earned it (creator follower-conversion analytics), and it
        // feeds the followCreator ranking signal.
        await markCreatorFollowed(env, { viewerId: user.id, creatorId: targetId });
      }
      return json({ following: status === "accepted", requested: status === "pending" });
    } else {
      await env.DB.prepare(
        "DELETE FROM follows WHERE follower_id = ? AND followee_id = ?"
      ).bind(user.id, targetId).run();
    }
    return json({ following: method === "POST" });
  }

  if (path === "/api/friends/requests" && method === "GET") {
    requireUser(user);
    const { results } = await env.DB.prepare(`
      SELECT u.id, u.username, u.display_name, u.avatar_key
      FROM follows f JOIN users u ON u.id = f.follower_id
      WHERE f.followee_id = ? AND f.status = 'pending'
      ORDER BY f.created_at DESC
    `).bind(user.id).all();
    return json({ requests: results.map(publicUser) });
  }

  if (path === "/api/friends/suggested" && method === "GET") {
    requireUser(user);
    const { results } = await env.DB.prepare(`
      SELECT id, username, display_name, avatar_key FROM users
      WHERE status != 'banned' AND id != ?
        AND id NOT IN (SELECT followee_id FROM follows WHERE follower_id = ?)
      ORDER BY created_at DESC LIMIT 20
    `).bind(user.id, user.id).all();
    return json({ users: results.map(publicUser) });
  }

  // ----- profile -----
  // A user's followers or the accounts they follow. kind is set by the path.
  const followListMatch = /^\/api\/users\/([\w.]+)\/(followers|following)$/.exec(path);
  if (followListMatch && method === "GET") {
    const [, handle, kind] = followListMatch;
    const target = await env.DB.prepare(
      "SELECT id FROM users WHERE username = ? OR id = ?"
    ).bind(handle, handle).first();
    if (!target) return err("User not found", 404);

    // followers  → people who follow this user (follower_id side)
    // following  → people this user follows (followee_id side)
    const sql = kind === "followers"
      ? `SELECT u.id, u.username, u.display_name, u.avatar_key, u.status
           FROM follows f JOIN users u ON u.id = f.follower_id
           WHERE f.followee_id = ? AND f.status = 'accepted' AND u.status != 'banned'
           ORDER BY f.created_at DESC LIMIT 200`
      : `SELECT u.id, u.username, u.display_name, u.avatar_key, u.status
           FROM follows f JOIN users u ON u.id = f.followee_id
           WHERE f.follower_id = ? AND f.status = 'accepted' AND u.status != 'banned'
           ORDER BY f.created_at DESC LIMIT 200`;

    const { results } = await env.DB.prepare(sql).bind(target.id).all();

    // If the viewer is logged in, mark which of these they already follow, so
    // each row can show the right Follow / Following state.
    let followedSet = new Set();
    if (user && results.length) {
      const ids = results.map(r => r.id);
      const placeholders = ids.map(() => "?").join(",");
      const { results: mine } = await env.DB.prepare(
        `SELECT followee_id FROM follows
           WHERE follower_id = ? AND status = 'accepted' AND followee_id IN (${placeholders})`
      ).bind(user.id, ...ids).all();
      followedSet = new Set(mine.map(m => m.followee_id));
    }

    return json({
      kind,
      users: results.map(u => ({
        id: u.id,
        username: u.username,
        displayName: u.display_name,
        avatarUrl: u.avatar_key ? `/api/media/${u.avatar_key}` : null,
        following: followedSet.has(u.id),
        isSelf: user ? u.id === user.id : false,
      })),
    });
  }

  const profileMatch = /^\/api\/users\/([\w.]+)$/.exec(path);
  if (profileMatch && method === "GET") {
    const handle = profileMatch[1];
    const u = await env.DB.prepare(
      "SELECT * FROM users WHERE username = ? OR id = ?"
    ).bind(handle, handle).first();
    if (!u) return err("User not found", 404);

    const stats = await env.DB.prepare(`
      SELECT
        (SELECT COUNT(*) FROM follows f JOIN users fu ON fu.id = f.follower_id
          WHERE f.followee_id = ? AND f.status = 'accepted' AND fu.status != 'banned') AS followers,
        (SELECT COUNT(*) FROM follows f JOIN users fu ON fu.id = f.followee_id
          WHERE f.follower_id = ? AND f.status = 'accepted' AND fu.status != 'banned') AS following,
        (SELECT COUNT(*) FROM likes l JOIN videos v ON v.id = l.video_id
          WHERE v.user_id = ?) +
        (SELECT COUNT(*) FROM post_likes pl JOIN posts p ON p.id = pl.post_id
          WHERE p.user_id = ?)                                                       AS likes,
        EXISTS(SELECT 1 FROM follows WHERE follower_id = ? AND followee_id = ?
          AND status = 'accepted')                                                   AS is_following
    `).bind(u.id, u.id, u.id, u.id, user?.id || "", u.id).first();

    // A private account's videos only show to the owner and accepted
    // followers; everyone else sees the profile without the grid.
    const isOwner = user && user.id === u.id;
    let canSeeVideos = !u.is_private || isOwner;
    if (u.is_private && user && !isOwner) {
      const f = await env.DB.prepare(
        "SELECT 1 FROM follows WHERE follower_id = ? AND followee_id = ? AND status = 'accepted'"
      ).bind(user.id, u.id).first();
      canSeeVideos = !!f;
    }

    // canSeeVideos is an ACCOUNT-level gate (is this profile private, do I
    // follow it). It says nothing about an individual video's own setting, so
    // on its own it published every "Private" and followers-only clip to
    // anyone allowed to view the profile at all. Each video is now checked
    // too — the owner sees all of theirs, everyone else sees only what that
    // video's visibility actually permits.
    const viewerId = user?.id || "";
    const { results } = canSeeVideos
      ? await env.DB.prepare(FEED_SQL + `
          WHERE v.user_id = ? AND (
            v.user_id = ?
            OR (v.visibility = 'public' AND u.is_private = 0)
            OR ((v.visibility = 'followers' OR u.is_private = 1) AND v.visibility != 'private' AND EXISTS(
                  SELECT 1 FROM follows f
                  WHERE f.follower_id = ? AND f.followee_id = v.user_id AND f.status = 'accepted'))
          )
          ORDER BY v.created_at DESC LIMIT 60`)
          .bind(viewerId, viewerId, u.id, viewerId, viewerId).all()
      : { results: [] };

    // Public posts are gated by the SAME rule as videos.
    //
    // They used to be exempt, on the reasoning that "the Public tab is
    // public" — but that is a statement about the tab, not about the person.
    // Marking an account private hid its videos and left every photo and
    // written post of theirs readable by anyone, which is not what anyone
    // means by private. Verified against the live API: a signed-out request
    // for a private profile returned locked=true, videos 0 — and 7 posts.
    const { results: postResults } = !canSeeVideos ? { results: [] } : await env.DB.prepare(`
      SELECT p.id, p.content, p.media_key, p.media_type, p.width, p.height, p.created_at,
             u.id AS user_id, u.username, u.display_name, u.avatar_key, u.role,
             (SELECT COUNT(*) FROM post_likes    WHERE post_id = p.id) AS like_count,
             (SELECT COUNT(*) FROM post_comments WHERE post_id = p.id) AS comment_count,
             (SELECT COUNT(*) FROM post_shares   WHERE post_id = p.id) AS share_count,
             EXISTS(SELECT 1 FROM post_likes WHERE post_id = p.id AND user_id = ?) AS liked,
             EXISTS(SELECT 1 FROM follows f
                     WHERE f.follower_id = ? AND f.followee_id = u.id
                       AND f.status = 'accepted')                       AS following
      FROM posts p JOIN users u ON u.id = p.user_id
      WHERE p.user_id = ?
      ORDER BY p.created_at DESC LIMIT 60
    `).bind(user?.id || "", user?.id || "", u.id).all();

    // Has this viewer already asked to follow a private account? Without it
    // the button had no way to know, so after sending a request it fell
    // straight back to "Follow" and nothing looked like it had happened.
    const pending = (user && !isOwner)
      ? await env.DB.prepare(
          "SELECT 1 FROM follows WHERE follower_id = ? AND followee_id = ? AND status = 'pending'"
        ).bind(user.id, u.id).first()
      : null;

    return json({
      user: publicUser(u),
      // Top-level so the profile's Follow button doesn't have to dig for it.
      following: !!stats.is_following,
      requested: !!pending,
      stats: {
        followers: stats.followers,
        following: stats.following,
        likes: stats.likes,
        isFollowing: !!stats.is_following,
      },
      videos: results.map(shapeVideo),
      posts: postResults.map(shapePost),
      // True when the account is private and the viewer isn't allowed in, so
      // the UI can show a "this account is private" note instead of an empty grid.
      locked: !!u.is_private && !canSeeVideos,
    });
  }

  // ----- search -----
  if (path === "/api/search" && method === "GET") {
    const q = (url.searchParams.get("q") || "").trim();
    if (!q) return json({ accounts: [], videos: [], posts: [] });
    const like = `%${q}%`;

    const [accounts, videos, posts] = await Promise.all([
      env.DB.prepare(`
        SELECT id, username, display_name, avatar_key FROM users
        WHERE status != 'banned' AND (username LIKE ? OR display_name LIKE ?) LIMIT 20
      `).bind(like, like).all(),
      env.DB.prepare(FEED_SQL + ` WHERE ${NOT_BANNED} AND v.caption LIKE ? ORDER BY v.created_at DESC LIMIT 20`)
        .bind(user?.id || "", user?.id || "", like).all(),
      // Public posts are searched by caption too, same as videos — the Public
      // tab's content wasn't reachable from search at all before this.
      env.DB.prepare(`
        SELECT p.id, p.content, p.media_key, p.media_type, p.width, p.height, p.created_at,
               u.id AS user_id, u.username, u.display_name, u.avatar_key, u.role,
               (SELECT COUNT(*) FROM post_likes    WHERE post_id = p.id) AS like_count,
               (SELECT COUNT(*) FROM post_comments WHERE post_id = p.id) AS comment_count,
               (SELECT COUNT(*) FROM post_shares   WHERE post_id = p.id) AS share_count,
               EXISTS(SELECT 1 FROM post_likes WHERE post_id = p.id AND user_id = ?) AS liked,
               EXISTS(SELECT 1 FROM follows f
                       WHERE f.follower_id = ? AND f.followee_id = u.id
                         AND f.status = 'accepted')                       AS following
        FROM posts p JOIN users u ON u.id = p.user_id
        WHERE u.status != 'banned' AND p.content LIKE ?
        ORDER BY p.created_at DESC LIMIT 20
      `).bind(user?.id || "", user?.id || "", like).all(),
    ]);

    return json({
      accounts: accounts.results.map(publicUser),
      videos: videos.results.map(shapeVideo),
      posts: posts.results.map(shapePost),
    });
  }

  // ----- messages -----
  if (path === "/api/messages" && method === "GET") {
    requireUser(user);
    // One row per conversation partner (the latest message with them), not
    // one row per message — a chat with 20 messages back and forth is one
    // person in the inbox, not twenty.
    const { results } = await env.DB.prepare(`
      WITH visible AS (
        SELECT * FROM messages
        WHERE (sender_id = ? OR recipient_id = ?)
          AND NOT ((sender_id = ? AND deleted_for_sender = 1) OR (recipient_id = ? AND deleted_for_recipient = 1))
      ), convo AS (
        SELECT
          CASE WHEN sender_id < recipient_id THEN sender_id ELSE recipient_id END AS a,
          CASE WHEN sender_id < recipient_id THEN recipient_id ELSE sender_id END AS b,
          MAX(created_at) AS last_at
        FROM visible
        GROUP BY a, b
      )
      SELECT m.id, m.sender_id, m.recipient_id, m.body, m.image_key, m.audio_key, m.created_at, m.deleted_everyone,
             u.id AS other_id, u.username, u.display_name, u.avatar_key, u.last_active_at,
             cs.status AS req_status, cs.requested_by AS req_by,
             (SELECT COUNT(*) FROM messages um
               WHERE um.recipient_id = ? AND um.read = 0
                 AND um.sender_id = CASE WHEN m.sender_id = ? THEN m.recipient_id ELSE m.sender_id END
             ) AS unread_count
      FROM convo c
      JOIN visible m ON ((m.sender_id = c.a AND m.recipient_id = c.b) OR (m.sender_id = c.b AND m.recipient_id = c.a))
                      AND m.created_at = c.last_at
      JOIN users u ON u.id = CASE WHEN m.sender_id = ? THEN m.recipient_id ELSE m.sender_id END
      LEFT JOIN conversation_status cs ON cs.user_a = c.a AND cs.user_b = c.b
      ORDER BY m.created_at DESC LIMIT 50
    `).bind(user.id, user.id, user.id, user.id, user.id, user.id, user.id).all();

    return json({
      threads: results.map(m => ({
        id: m.id,
        body: m.deleted_everyone ? null : m.body,
        deleted: !!m.deleted_everyone,
        hasImage: !!m.image_key,
        hasAudio: !!m.audio_key,
        createdAt: m.created_at,
        unreadCount: m.unread_count,
        with: {
          // The id was missing here. Anything that acts on a thread's person
          // rather than just displaying them — the share sheet's Send, which
          // posts to a recipient id — received an empty string for EVERY row,
          // so every send failed and per-row state keyed on the id matched all
          // of them at once (four spinners for one tap).
          id: m.other_id,
          username: m.username,
          displayName: m.display_name,
          avatarUrl: m.avatar_key ? `/api/media/${m.avatar_key}` : null,
          online: !!(m.last_active_at && now() - m.last_active_at < 120000),
        },
        outgoing: m.sender_id === user.id,
        // "pending" + I'm the one who sent the request → waiting on them.
        // "pending" + they sent it → it's a request I need to accept/decline.
        requestStatus: m.req_status || "accepted", // no row = predates this feature, grandfathered in
        requestedByMe: m.req_by === user.id,
      })),
    });
  }

  if (path === "/api/messages/unread-count" && method === "GET") {
    requireUser(user);
    const r = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM messages WHERE recipient_id = ? AND read = 0"
    ).bind(user.id).first();
    return json({ count: r.n });
  }

  if (path === "/api/presence/ping" && method === "POST") {
    requireUser(user);
    await env.DB.prepare("UPDATE users SET last_active_at = ? WHERE id = ?").bind(now(), user.id).run();
    return json({ ok: true });
  }

  // One conversation, oldest first — what the chat screen reads.
  const convoMatch = /^\/api\/messages\/([\w-]+)$/.exec(path);
  if (convoMatch && method === "GET") {
    requireUser(user);
    const other = convoMatch[1];

    const them = await env.DB.prepare(
      "SELECT id, username, display_name, avatar_key, status, last_active_at FROM users WHERE id = ? OR username = ?"
    ).bind(other, other).first();
    if (!them) return err("User not found", 404);

    // Opening the thread is what marks their messages read, same as tapping
    // into any chat app's conversation. Which ones WERE unread has to be
    // captured before that UPDATE runs — otherwise every message already
    // looks read by the time the client sees it, and there's no way left to
    // tell "unread until this exact fetch" apart from "read a while ago",
    // which is what the client needs to place the "Unread messages" divider.
    const firstUnread = await env.DB.prepare(
      "SELECT id FROM messages WHERE sender_id = ? AND recipient_id = ? AND read = 0 ORDER BY created_at ASC LIMIT 1"
    ).bind(them.id, user.id).first();

    await env.DB.prepare(
      "UPDATE messages SET read = 1 WHERE sender_id = ? AND recipient_id = ? AND read = 0"
    ).bind(them.id, user.id).run();

    const { results } = await env.DB.prepare(`
      SELECT id, sender_id, body, video_id, image_key, audio_key, audio_duration, created_at, read, deleted_everyone, reply_to_id FROM messages
      WHERE ((sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?))
        AND NOT ((sender_id = ? AND deleted_for_sender = 1) OR (recipient_id = ? AND deleted_for_recipient = 1))
      ORDER BY created_at ASC LIMIT 200
    `).bind(user.id, them.id, them.id, user.id, user.id, user.id).all();

    const replyToIds = [...new Set(results.map(m => m.reply_to_id).filter(Boolean))];

    const [convo, iBlockedThem, theyBlockedMe, typing, reactions, repliedTo] = await Promise.all([
      getConversationStatus(env, user.id, them.id),
      env.DB.prepare("SELECT 1 FROM blocks WHERE blocker_id = ? AND blocked_id = ?").bind(user.id, them.id).first(),
      env.DB.prepare("SELECT 1 FROM blocks WHERE blocker_id = ? AND blocked_id = ?").bind(them.id, user.id).first(),
      // No "stopped typing" signal exists — the frontend only ever pings
      // while actively composing, so a ping older than a couple of poll
      // cycles just means it hasn't refreshed, i.e. they've stopped.
      env.DB.prepare(
        "SELECT 1 FROM typing_status WHERE sender_id = ? AND recipient_id = ? AND updated_at > ?"
      ).bind(them.id, user.id, now() - 6000).first(),
      results.length
        ? env.DB.prepare(
            `SELECT message_id, user_id, emoji FROM message_reactions WHERE message_id IN (${results.map(() => "?").join(",")})`
          ).bind(...results.map(m => m.id)).all()
        : { results: [] },
      // A quoted message may be one the recipient already deleted-for-me,
      // may belong to either side of the conversation, or may not exist at
      // all anymore — this is a best-effort snippet lookup, not a strict
      // join, so a reply to something since removed just shows nothing
      // instead of breaking the message that quoted it.
      replyToIds.length
        ? env.DB.prepare(
            `SELECT id, sender_id, body, image_key, audio_key, deleted_everyone FROM messages WHERE id IN (${replyToIds.map(() => "?").join(",")})`
          ).bind(...replyToIds).all()
        : { results: [] },
    ]);

    const reactionsByMsg = new Map();
    for (const r of reactions.results) {
      if (!reactionsByMsg.has(r.message_id)) reactionsByMsg.set(r.message_id, []);
      reactionsByMsg.get(r.message_id).push({ emoji: r.emoji, mine: r.user_id === user.id });
    }

    const repliedToById = new Map(repliedTo.results.map(m => [m.id, m]));
    const replySnippet = (m) => {
      if (m.deleted_everyone) return "This message was deleted";
      if (m.body) return m.body;
      if (m.image_key) return "📷 Photo";
      if (m.audio_key) return "🎤 Voice message";
      return "";
    };

    return json({
      with: {
        id: them.id,
        username: them.username,
        displayName: them.display_name,
        avatarUrl: them.avatar_key ? `/api/media/${them.avatar_key}` : null,
        online: !!(them.last_active_at && now() - them.last_active_at < 120000),
      },
      requestStatus: convo?.status || "accepted",
      requestedByMe: convo ? convo.requested_by === user.id : false,
      blocked: !!iBlockedThem,
      blockedByThem: !!theyBlockedMe,
      isTyping: !!typing,
      firstUnreadId: firstUnread?.id || null,
      messages: results.map(m => ({
        id: m.id,
        body: m.deleted_everyone ? null : m.body,
        videoId: m.video_id,
        imageUrl: !m.deleted_everyone && m.image_key ? `/api/media/${m.image_key}` : null,
        audioUrl: !m.deleted_everyone && m.audio_key ? `/api/media/${m.audio_key}` : null,
        audioDuration: m.audio_duration,
        createdAt: m.created_at,
        outgoing: m.sender_id === user.id,
        read: !!m.read,
        deleted: !!m.deleted_everyone,
        reactions: reactionsByMsg.get(m.id) || [],
        replyTo: (() => {
          const q = repliedToById.get(m.reply_to_id);
          if (!q) return null;
          return { id: q.id, mine: q.sender_id === user.id, snippet: replySnippet(q) };
        })(),
      })),
    });
  }

  // Delete for me: hides the message from just this user, any time. Delete
  // for everyone: only the sender, only within 15 minutes of sending (same
  // window WhatsApp uses) — replaces the content with a tombstone both
  // sides see, rather than removing the row (so "This message was deleted"
  // has something to point at).
  const delMsgMatch = /^\/api\/messages\/([\w-]+)\/delete$/.exec(path);
  if (delMsgMatch && method === "POST") {
    requireUser(user);
    const msg = await env.DB.prepare("SELECT * FROM messages WHERE id = ?").bind(delMsgMatch[1]).first();
    if (!msg) return err("Message not found", 404);
    if (msg.sender_id !== user.id && msg.recipient_id !== user.id) return err("Not your message", 403);

    const { scope } = await request.json().catch(() => ({}));
    if (scope === "everyone") {
      if (msg.sender_id !== user.id) return err("Only the sender can delete for everyone", 403);
      if (now() - msg.created_at > 15 * 60 * 1000) return err("Too late to delete for everyone", 400);
      if (msg.image_key) await env.MEDIA.delete(msg.image_key).catch(() => {});
      if (msg.audio_key) await env.MEDIA.delete(msg.audio_key).catch(() => {});
      await env.DB.prepare(
        "UPDATE messages SET deleted_everyone = 1, body = NULL, image_key = NULL, audio_key = NULL WHERE id = ?"
      ).bind(msg.id).run();
    } else {
      const col = msg.sender_id === user.id ? "deleted_for_sender" : "deleted_for_recipient";
      await env.DB.prepare(`UPDATE messages SET ${col} = 1 WHERE id = ?`).bind(msg.id).run();
    }
    return json({ ok: true });
  }

  // Tapping the same emoji again removes the reaction (toggle), same as
  // WhatsApp/most chat apps — one reaction per person per message.
  const msgReactMatch = /^\/api\/messages\/([\w-]+)\/react$/.exec(path);
  if (msgReactMatch && method === "POST") {
    requireUser(user);
    const msg = await env.DB.prepare("SELECT sender_id, recipient_id FROM messages WHERE id = ?").bind(msgReactMatch[1]).first();
    if (!msg) return err("Message not found", 404);
    if (msg.sender_id !== user.id && msg.recipient_id !== user.id) return err("Not your conversation", 403);

    const { emoji } = await request.json();
    if (!emoji) return err("emoji is required");
    const existing = await env.DB.prepare(
      "SELECT emoji FROM message_reactions WHERE message_id = ? AND user_id = ?"
    ).bind(msgReactMatch[1], user.id).first();
    if (existing?.emoji === emoji) {
      await env.DB.prepare("DELETE FROM message_reactions WHERE message_id = ? AND user_id = ?").bind(msgReactMatch[1], user.id).run();
    } else {
      await env.DB.prepare(`
        INSERT INTO message_reactions (message_id, user_id, emoji, created_at) VALUES (?, ?, ?, ?)
        ON CONFLICT(message_id, user_id) DO UPDATE SET emoji = excluded.emoji, created_at = excluded.created_at
      `).bind(msgReactMatch[1], user.id, emoji, now()).run();
    }
    return json({ ok: true });
  }

  // Fire-and-forget from the compose box while typing — no read-back, no
  // preference to respect, just a timestamp the recipient's next poll of
  // GET /api/messages/:id checks against. Upsert rather than insert-or-
  // ignore since the same pair keeps refreshing the same row while typing
  // continues.
  const typingMatch = /^\/api\/messages\/([\w-]+)\/typing$/.exec(path);
  if (typingMatch && method === "POST") {
    requireUser(user);
    const them = await env.DB.prepare(
      "SELECT id FROM users WHERE id = ? OR username = ?"
    ).bind(typingMatch[1], typingMatch[1]).first();
    if (!them) return err("User not found", 404);
    await env.DB.prepare(`
      INSERT INTO typing_status (sender_id, recipient_id, updated_at) VALUES (?, ?, ?)
      ON CONFLICT(sender_id, recipient_id) DO UPDATE SET updated_at = excluded.updated_at
    `).bind(user.id, them.id, now()).run();
    return json({ ok: true });
  }

  if (path === "/api/messages" && method === "POST") {
    requireUser(user);
    const { recipientId, body, videoId, replyToId } = await request.json();
    if (!recipientId) return err("recipientId is required");
    if (!body?.trim() && !videoId) return err("Write a message or attach a video");

    const them = await env.DB.prepare(
      "SELECT id, allow_messages, status FROM users WHERE id = ? OR username = ?"
    ).bind(recipientId, recipientId).first();
    if (!them) return err("User not found", 404);

    await checkMessagePermission(env, user.id, them);
    await applyConversationGate(env, user.id, them.id);

    const id = uid();
    await env.DB.prepare(`
      INSERT INTO messages (id, sender_id, recipient_id, body, video_id, reply_to_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).bind(id, user.id, them.id, body?.trim() || null, videoId || null, replyToId || null, now()).run();

    // Best-effort, like every other push here — messages have no notify_*
    // toggle to check (there isn't one, same as gifts), so this always
    // fires. tag is the sender's id, not a per-message id, so several
    // messages in a row from the same person coalesce into one
    // notification instead of stacking — same as WhatsApp.
    {
      const payload = {
        title: user.display_name || user.username,
        body: (body?.trim() || (videoId ? "Sent a video" : "")).slice(0, 200),
        url: `/?chat=${encodeURIComponent(user.username)}`,
        tag: `message-${user.id}`,
      };
      // Both channels: browsers via Web Push, the installed app via FCM. This
      // used to be sendPush alone, so a message never reached a phone at all.
      ctx.waitUntil(Promise.all([
        sendPush(env, them.id, payload),
        sendFcm(env, them.id, { ...payload, route: `/chat/${user.username}` }),
      ]));
    }

    return json({ ok: true, id }, 201);
  }

  // A photo or voice note in a chat — same permission/request gating as a
  // text message (applyConversationGate/checkMessagePermission), just a
  // file instead of (or alongside) a body.
  if (path === "/api/messages/media" && method === "POST") {
    requireUser(user);
    const form = await request.formData();
    const recipientId = form.get("recipientId");
    const kind = form.get("kind"); // "image" | "audio"
    const file = form.get("file");
    if (!recipientId) return err("recipientId is required");
    if (!["image", "audio"].includes(kind)) return err("kind must be image or audio");
    if (!file || typeof file === "string") return err(`A${kind === "audio" ? "n" : ""} ${kind} file is required`);
    if (kind === "image" && !/^image\//.test(file.type)) return err("That file isn't an image");
    if (kind === "audio" && !/^audio\//.test(file.type)) return err("That file isn't audio");
    if (file.size > 20 * 1024 * 1024) return err("File must be under 20MB", 413);

    const them = await env.DB.prepare(
      "SELECT id, allow_messages, status FROM users WHERE id = ? OR username = ?"
    ).bind(recipientId, recipientId).first();
    if (!them) return err("User not found", 404);

    await checkMessagePermission(env, user.id, them);
    await applyConversationGate(env, user.id, them.id);

    const id = uid();
    const ext = (file.type.split("/")[1] || (kind === "image" ? "jpg" : "webm")).split(";")[0];
    const key = `messages/${user.id}/${id}.${ext}`;
    await env.MEDIA.put(key, file.stream(), { httpMetadata: { contentType: file.type } });
    const duration = kind === "audio" ? (parseFloat(form.get("duration")) || null) : null;
    const caption = (form.get("body") || "").toString().trim().slice(0, 1000) || null;
    const replyToId = (form.get("replyToId") || "").toString().trim() || null;

    await env.DB.prepare(`
      INSERT INTO messages (id, sender_id, recipient_id, body, image_key, audio_key, audio_duration, reply_to_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      id, user.id, them.id, caption,
      kind === "image" ? key : null, kind === "audio" ? key : null, duration, replyToId,
      now()
    ).run();

    ctx.waitUntil(sendPush(env, them.id, {
      title: user.display_name || user.username,
      body: caption || (kind === "image" ? "📷 Photo" : "🎤 Voice message"),
      url: `/?chat=${encodeURIComponent(user.username)}`,
      tag: `message-${user.id}`,
    }));

    return json({ ok: true, id }, 201);
  }

  // Block / unblock. Blocking someone also freezes the message-request
  // state as-is — applyConversationGate checks blocks before it ever looks
  // at conversation_status, so a blocked person can't message their way
  // around it by "replying" to accept.
  const blockMatch = /^\/api\/users\/([\w.-]+)\/block$/.exec(path);
  if (blockMatch && (method === "POST" || method === "DELETE")) {
    requireUser(user);
    const target = await env.DB.prepare(
      "SELECT id FROM users WHERE id = ? OR username = ?"
    ).bind(blockMatch[1], blockMatch[1]).first();
    if (!target) return err("User not found", 404);
    if (target.id === user.id) return err("You can't block yourself");
    if (method === "POST") {
      await env.DB.prepare(
        "INSERT OR IGNORE INTO blocks (blocker_id, blocked_id, created_at) VALUES (?, ?, ?)"
      ).bind(user.id, target.id, now()).run();
    } else {
      await env.DB.prepare(
        "DELETE FROM blocks WHERE blocker_id = ? AND blocked_id = ?"
      ).bind(user.id, target.id).run();
    }
    return json({ blocked: method === "POST" });
  }

  // Unfurls a URL sent in a chat message into a title/description/image
  // card, same idea as WhatsApp/iMessage link previews. Fetched
  // server-side (the browser can't read another site's HTML across
  // origins, and this keeps the target's IP hidden from other users).
  // Cloudflare Workers' own fetch() already can't reach private/internal
  // IP ranges, which is most of what keeps this from being an SSRF hole.
  if (path === "/api/link-preview" && method === "GET") {
    requireUser(user);
    const target = url.searchParams.get("url");
    if (!target) return err("url is required");
    let parsed;
    try { parsed = new URL(target); } catch { return err("That's not a valid URL"); }
    if (!["http:", "https:"].includes(parsed.protocol)) return err("Only http/https links can be previewed");

    try {
      const res = await fetch(parsed.toString(), {
        signal: AbortSignal.timeout(5000),
        headers: { "User-Agent": "Mozilla/5.0 (compatible; GEEREELBot/1.0; +link-preview)" },
      });
      if (!res.ok) return json({ url: parsed.toString(), title: parsed.hostname });

      // Only the <head> is needed and pages can be large — read a capped
      // slice rather than the whole body.
      const reader = res.body.getReader();
      let html = "", bytes = 0;
      const decoder = new TextDecoder();
      while (bytes < 60000) {
        const { done, value } = await reader.read();
        if (done) break;
        bytes += value.length;
        html += decoder.decode(value, { stream: true });
        if (/<\/head>/i.test(html)) break;
      }
      reader.cancel().catch(() => {});

      const meta = (prop) => {
        const re = new RegExp(`<meta[^>]+(?:property|name)=["']${prop}["'][^>]+content=["']([^"']*)["']`, "i");
        return html.match(re)?.[1] || null;
      };
      const titleTag = html.match(/<title[^>]*>([^<]*)<\/title>/i)?.[1];

      return json({
        url: parsed.toString(),
        title: (meta("og:title") || titleTag || parsed.hostname).trim().slice(0, 200),
        description: (meta("og:description") || meta("description") || "").trim().slice(0, 300),
        image: meta("og:image"),
        siteName: (meta("og:site_name") || parsed.hostname).trim(),
      });
    } catch {
      // Unreachable, timed out, or refused — the link still sends fine as
      // plain text, it just won't get a card.
      return json({ url: parsed.toString(), title: parsed.hostname });
    }
  }

  // Accept or decline a pending message request. Only the person who
  // DIDN'T send the first message can act on it.
  const requestActionMatch = /^\/api\/messages\/([\w-]+)\/(accept|decline)$/.exec(path);
  if (requestActionMatch && method === "POST") {
    requireUser(user);
    const [, otherId, action] = requestActionMatch;
    const convo = await getConversationStatus(env, user.id, otherId);
    if (!convo || convo.status !== "pending") return err("No pending request from this person", 404);
    if (convo.requested_by === user.id) return err("You sent this request — nothing to accept", 400);

    await env.DB.prepare(
      "UPDATE conversation_status SET status = ? WHERE user_a = ? AND user_b = ?"
    ).bind(action === "accept" ? "accepted" : "declined", ...pairKey(user.id, otherId)).run();

    return json({ status: action === "accept" ? "accepted" : "declined" });
  }

  // ----- wallet, coins, gifts -----

  // What the wallet chip at the top of the profile reads.
  if (path === "/api/wallet" && method === "GET") {
    requireUser(user);
    const totals = await env.DB.prepare(`
      SELECT
        (SELECT COUNT(*) FROM gifts WHERE recipient_id = ?) AS gifts_received,
        (SELECT COUNT(*) FROM gifts WHERE sender_id = ?)    AS gifts_sent,
        -- Earned, minus everything already requested or paid. Only this can
        -- become money; see the payout handler for why.
        COALESCE((SELECT lifetime_gifts_cents FROM users WHERE id = ?), 0)
          - COALESCE((SELECT SUM(coins) FROM coin_payouts
                      WHERE user_id = ? AND status != 'rejected'), 0)     AS withdrawable
    `).bind(user.id, user.id, user.id, user.id).first();

    return json({
      // One available balance, in coins. Kept as `coins` AND mirrored into
      // giftBalanceCents (1 coin = 1 cent) so older clients that read the
      // separate earnings field still show the right, single number.
      coins: user.coin_balance,
      availableCoins: user.coin_balance,
      availableCents: user.coin_balance * COIN_PRICE_CENTS,
      giftBalanceCents: user.coin_balance * COIN_PRICE_CENTS,
      lifetimeGiftsCents: user.lifetime_gifts_cents,
      giftsReceived: totals.gifts_received,
      giftsSent: totals.gifts_sent,
      coinPacks: COIN_PACKS,
      minPayoutCents: MIN_PAYOUT_CENTS,
      // What can actually leave as money, and what it costs to send. The
      // cash-out screen shows the whole balance otherwise, and only finds out
      // at the last step that most of it was bought and can't be withdrawn.
      withdrawableCoins: Math.max(0, totals.withdrawable || 0),
      payoutFeePercent: PAYOUT_FEE_PERCENT,
    });
  }

  if (path === "/api/gifts/catalog" && method === "GET") {
    return json({
      gifts: GIFTS.map(g => ({ ...g, valueCents: Math.floor(g.coins * COIN_PRICE_CENTS) })),
      creatorShare: CREATOR_SHARE,
    });
  }

  if (path === "/api/wallet/history" && method === "GET") {
    requireUser(user);
    const { results } = await env.DB.prepare(`
      SELECT kind, coins_delta, cents_delta, note, created_at
      FROM wallet_tx WHERE user_id = ? ORDER BY created_at DESC LIMIT 100
    `).bind(user.id).all();
    return json({
      history: results.map(t => ({
        kind: t.kind,
        coinsDelta: t.coins_delta,
        centsDelta: t.cents_delta,
        note: t.note,
        createdAt: t.created_at,
      })),
    });
  }

  // Send a gift on a video.
  if (path === "/api/gifts" && method === "POST") {
    requireUser(user);
    const { videoId: rawVideoId, giftKey } = await request.json();

    const gift = giftByKey(giftKey);
    if (!gift) return err("Unknown gift");

    // Gifting a repost has to pay the actual creator, not whoever reposted
    // it — resolve to the underlying content before anything else touches
    // videoId.
    const videoId = await resolveContentId(env, rawVideoId);
    const video = await env.DB.prepare(`
      SELECT v.id, v.user_id, u.status FROM videos v
      JOIN users u ON u.id = v.user_id WHERE v.id = ?
    `).bind(videoId).first();
    if (!video) return err("Video not found", 404);
    if (video.status === "banned") return err("That account is banned", 403);
    if (video.user_id === user.id) return err("You can't gift your own video");

    // The balance check lives in the WHERE clause, not in JavaScript. If two
    // requests arrive at once, the database — not the app — decides who wins,
    // and neither can push the balance below zero.
    const spend = await env.DB.prepare(
      "UPDATE users SET coin_balance = coin_balance - ? WHERE id = ? AND coin_balance >= ?"
    ).bind(gift.coins, user.id, gift.coins).run();

    if (!spend.meta.changes) {
      return err(`Not enough coins — this gift costs ${gift.coins}`, 402);
    }

    // Creator keeps a share; the rest is the platform's cut.
    const grossCents = Math.floor(gift.coins * COIN_PRICE_CENTS);
    const creatorCents = Math.floor(grossCents * CREATOR_SHARE);

    const giftId = uid();
    await env.DB.batch([
      env.DB.prepare(`
        INSERT INTO gifts (id, sender_id, recipient_id, video_id, gift_key, coins, value_cents, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      `).bind(giftId, user.id, video.user_id, video.id, gift.key, gift.coins, creatorCents, now()),
      // ONE balance. A creator's earnings land as coins in the same wallet the
      // coins they bought live in — 1 coin is 1 cent (COIN_PRICE_CENTS), so
      // this is a rename, not a conversion. Splitting "coins you bought" from
      // "money you earned" meant a creator could be holding a gift they
      // couldn't spend; now every coin is spendable AND withdrawable.
      // lifetime_gifts_cents stays as the earnings record payouts are measured
      // against, and is never spent from.
      env.DB.prepare(`
        UPDATE users SET coin_balance = coin_balance + ?,
                         lifetime_gifts_cents = lifetime_gifts_cents + ?
        WHERE id = ?
      `).bind(creatorCents, creatorCents, video.user_id),
    ]);

    const [me, them] = await Promise.all([
      env.DB.prepare("SELECT coin_balance, gift_balance_cents FROM users WHERE id = ?").bind(user.id).first(),
      env.DB.prepare("SELECT coin_balance, gift_balance_cents FROM users WHERE id = ?").bind(video.user_id).first(),
    ]);

    await recordTx(env, user.id, "gift_sent", -gift.coins, 0,
                   me.coin_balance, me.gift_balance_cents, giftId, `${gift.emoji} ${gift.name}`);
    await recordTx(env, video.user_id, "gift_received", 0, creatorCents,
                   them.coin_balance, them.gift_balance_cents, giftId, `${gift.emoji} ${gift.name}`);

    await notify(env, ctx, video.user_id, user.id, "gift", { videoId: video.id });

    const count = await env.DB.prepare(
      "SELECT COUNT(*) AS n, COALESCE(SUM(coins),0) AS coins FROM gifts WHERE video_id = ?"
    ).bind(video.id).first();

    return json({
      ok: true,
      gift: { key: gift.key, name: gift.name, emoji: gift.emoji, coins: gift.coins },
      coinsLeft: me.coin_balance,
      videoGifts: { count: count.n, coins: count.coins },
    }, 201);
  }

  // Who gifted a video — shown under the video.
  const videoGiftsMatch = /^\/api\/videos\/([\w-]+)\/gifts$/.exec(path);
  if (videoGiftsMatch && method === "GET") {
    const { results } = await env.DB.prepare(`
      SELECT g.gift_key, g.coins, g.created_at,
             u.username, u.display_name, u.avatar_key
      FROM gifts g JOIN users u ON u.id = g.sender_id
      WHERE g.video_id = ? ORDER BY g.created_at DESC LIMIT 50
    `).bind(videoGiftsMatch[1]).all();

    const totals = await env.DB.prepare(
      "SELECT COUNT(*) AS n, COALESCE(SUM(coins),0) AS coins FROM gifts WHERE video_id = ?"
    ).bind(videoGiftsMatch[1]).first();

    return json({
      count: totals.n,
      coins: totals.coins,
      gifts: results.map(g => {
        const meta = giftByKey(g.gift_key);
        return {
          key: g.gift_key,
          emoji: meta?.emoji || "🎁",
          name: meta?.name || g.gift_key,
          coins: g.coins,
          createdAt: g.created_at,
          from: {
            username: g.username,
            displayName: g.display_name,
            avatarUrl: g.avatar_key ? `/api/media/${g.avatar_key}` : null,
          },
        };
      }),
    });
  }

  // Buying coins. There's no card processor wired up, so this files a request
  // an admin confirms after the money actually arrives.
  if (path === "/api/coins/buy" && method === "POST") {
    requireUser(user);
    const { coins, method: payMethod, reference } = await request.json();

    const pack = COIN_PACKS.find(p => p.coins === coins);
    if (!pack) return err("Pick one of the listed coin packs");
    if (!payMethod?.trim()) return err("Choose how you paid");

    const id = uid();
    await env.DB.prepare(`
      INSERT INTO coin_purchases (id, user_id, coins, paid_cents, method, status, reference, created_at)
      VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)
    `).bind(id, user.id, pack.coins, pack.cents, payMethod.trim(),
            reference?.trim() || null, now()).run();

    return json({
      ok: true,
      id,
      status: "pending",
      message: "An admin will add your coins once the payment is confirmed.",
    }, 201);
  }

  // Progress toward the thresholds, plus any application already in flight.
  if (path === "/api/monetization/status" && method === "GET") {
    requireUser(user);
    const stats = await monetizeStats(env, user.id);
    const app = await env.DB.prepare(`
      SELECT id, status, review_note, created_at, reviewed_at
      FROM monetization_applications
      WHERE user_id = ? ORDER BY created_at DESC LIMIT 1
    `).bind(user.id).first();

    const totals = await env.DB.prepare(`
      SELECT COALESCE(SUM(amount_cents), 0) AS total,
             COALESCE(SUM(CASE WHEN paid = 0 THEN amount_cents ELSE 0 END), 0) AS pending
      FROM earnings WHERE user_id = ?
    `).bind(user.id).first();

    return json({
      ...stats,
      monetized: !!user.monetized,
      application: app ? {
        id: app.id, status: app.status, note: app.review_note,
        createdAt: app.created_at, reviewedAt: app.reviewed_at,
      } : null,
      earnings: {
        totalCents: totals.total,
        pendingCents: totals.pending,
        minPayoutCents: MIN_PAYOUT_CENTS,
      },
    });
  }

  if (path === "/api/monetization/apply" && method === "POST") {
    requireUser(user);
    if (user.monetized) return err("Your account is already monetized", 409);

    const existing = await env.DB.prepare(`
      SELECT status FROM monetization_applications
      WHERE user_id = ? AND status = 'pending' LIMIT 1
    `).bind(user.id).first();
    if (existing) return err("You already have an application under review", 409);

    // Re-check against live numbers, never against what the client claims.
    const stats = await monetizeStats(env, user.id);
    if (!stats.eligible) {
      return err(
        `You need ${MONETIZE_RULES.followers.toLocaleString()} followers, ` +
        `${MONETIZE_RULES.likes.toLocaleString()} likes and ` +
        `${MONETIZE_RULES.videos} videos. ` +
        `You have ${stats.followers.toLocaleString()}, ` +
        `${stats.likes.toLocaleString()} and ${stats.videos}.`,
        403
      );
    }

    const { payoutMethod, payoutDetails } = await request.json().catch(() => ({}));
    if (!payoutMethod) return err("Choose how you want to be paid");
    if (!["mobile_money", "bank", "paypal"].includes(payoutMethod)) {
      return err("payoutMethod must be mobile_money, bank or paypal");
    }
    if (!payoutDetails?.trim()) return err("Add your payout details");

    const id = uid();
    await env.DB.prepare(`
      INSERT INTO monetization_applications
        (id, user_id, status, followers_at_apply, likes_at_apply, videos_at_apply,
         payout_method, payout_details, created_at)
      VALUES (?, ?, 'pending', ?, ?, ?, ?, ?, ?)
    `).bind(id, user.id, stats.followers, stats.likes, stats.videos,
            payoutMethod, payoutDetails.trim(), now()).run();

    return json({ ok: true, id, status: "pending" }, 201);
  }

  if (path === "/api/monetization/earnings" && method === "GET") {
    requireUser(user);
    const { results } = await env.DB.prepare(`
      SELECT period, views, amount_cents, paid, paid_at
      FROM earnings WHERE user_id = ? ORDER BY period DESC LIMIT 24
    `).bind(user.id).all();

    return json({
      months: results.map(r => ({
        period: r.period,
        views: r.views,
        amountCents: r.amount_cents,
        paid: !!r.paid,
        paidAt: r.paid_at,
      })),
    });
  }

  // ----- reports (any user can file one) -----

  if (path === "/api/reports" && method === "POST") {
    requireUser(user);
    const { videoId, commentId, reportedUserId, reason, detail } = await request.json();
    if (!reason?.trim()) return err("Tell us what's wrong");
    if (!videoId && !commentId && !reportedUserId) return err("Nothing was reported");

    await env.DB.prepare(`
      INSERT INTO reports (id, reporter_id, video_id, comment_id, reported_user_id,
                           reason, detail, status, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'open', ?)
    `).bind(uid(), user.id, videoId || null, commentId || null, reportedUserId || null,
            reason.trim(), detail?.trim() || null, now()).run();

    return json({ ok: true }, 201);
  }

  // ----- admin -----

  if (path === "/api/admin/coin-purchases" && method === "GET") {
    requireStaff(user);
    const status = url.searchParams.get("status") || "pending";
    const { results } = await env.DB.prepare(`
      SELECT c.*, u.username, u.display_name
      FROM coin_purchases c JOIN users u ON u.id = c.user_id
      WHERE c.status = ? ORDER BY c.created_at DESC LIMIT 100
    `).bind(status).all();

    return json({
      purchases: results.map(p => ({
        id: p.id,
        username: p.username,
        displayName: p.display_name,
        coins: p.coins,
        paidCents: p.paid_cents,
        method: p.method,
        reference: p.reference,
        status: p.status,
        createdAt: p.created_at,
      })),
    });
  }

  const coinApproveMatch = /^\/api\/admin\/coin-purchases\/([\w-]+)\/(approve|reject)$/.exec(path);
  if (coinApproveMatch && method === "POST") {
    requireAdmin(user);
    const [, purchaseId, decision] = coinApproveMatch;

    const p = await env.DB.prepare("SELECT * FROM coin_purchases WHERE id = ?").bind(purchaseId).first();
    if (!p) return err("Purchase not found", 404);
    if (p.status !== "pending") return err("Already handled", 409);

    if (decision === "approve") {
      // Flip the row first, and only credit if this call is the one that
      // changed it. Two admins clicking at once can't credit the coins twice.
      const claim = await env.DB.prepare(
        "UPDATE coin_purchases SET status='approved', approved_by=?, approved_at=? WHERE id=? AND status='pending'"
      ).bind(user.id, now(), purchaseId).run();

      if (!claim.meta.changes) return err("Already handled", 409);

      await env.DB.prepare(
        "UPDATE users SET coin_balance = coin_balance + ? WHERE id = ?"
      ).bind(p.coins, p.user_id).run();

      const fresh = await env.DB.prepare(
        "SELECT coin_balance, gift_balance_cents FROM users WHERE id = ?"
      ).bind(p.user_id).first();

      await recordTx(env, p.user_id, "coins_purchased", p.coins, 0,
                     fresh.coin_balance, fresh.gift_balance_cents, purchaseId,
                     `${p.coins} coins`);
    } else {
      await env.DB.prepare(
        "UPDATE coin_purchases SET status='rejected', approved_by=?, approved_at=? WHERE id=? AND status='pending'"
      ).bind(user.id, now(), purchaseId).run();
    }

    await logAdmin(env, user.id, `coins_${decision}`, "purchase", purchaseId, `${p.coins} coins`);
    return json({ ok: true });
  }

  // Grant coins directly — for support cases and testing.
  const grantMatch = /^\/api\/admin\/users\/([\w-]+)\/coins$/.exec(path);
  if (grantMatch && method === "POST") {
    requireAdmin(user);
    const { coins, note } = await request.json();
    const n = parseInt(coins);
    if (!Number.isFinite(n) || n === 0) return err("coins must be a non-zero number");

    // Guard the subtraction the same way gifting does, so a negative grant
    // can't drive someone below zero.
    const res = n > 0
      ? await env.DB.prepare("UPDATE users SET coin_balance = coin_balance + ? WHERE id = ?")
          .bind(n, grantMatch[1]).run()
      : await env.DB.prepare("UPDATE users SET coin_balance = coin_balance - ? WHERE id = ? AND coin_balance >= ?")
          .bind(-n, grantMatch[1], -n).run();

    if (!res.meta.changes) return err("That would put them below zero", 400);

    const fresh = await env.DB.prepare(
      "SELECT coin_balance, gift_balance_cents FROM users WHERE id = ?"
    ).bind(grantMatch[1]).first();

    await recordTx(env, grantMatch[1], "admin_grant", n, 0,
                   fresh.coin_balance, fresh.gift_balance_cents, null, note || "Admin adjustment");
    await logAdmin(env, user.id, "grant_coins", "user", grantMatch[1], `${n} coins: ${note || ""}`);
    return json({ ok: true, coins: fresh.coin_balance });
  }

  if (path === "/api/admin/stats" && method === "GET") {
    requireStaff(user);
    const s = await env.DB.prepare(`
      SELECT
        (SELECT COUNT(*) FROM users)                                        AS users,
        (SELECT COUNT(*) FROM users WHERE status = 'banned')                AS banned,
        (SELECT COUNT(*) FROM users WHERE monetized = 1)                    AS monetized,
        (SELECT COUNT(*) FROM videos)                                       AS videos,
        (SELECT COUNT(*) FROM comments)                                     AS comments,
        (SELECT COALESCE(SUM(views), 0) FROM videos)                        AS views,
        (SELECT COUNT(*) FROM monetization_applications
          WHERE status = 'pending')                                         AS pending_apps,
        (SELECT COUNT(*) FROM reports WHERE status = 'open')                AS open_reports,
        (SELECT COALESCE(SUM(amount_cents), 0) FROM earnings WHERE paid = 0) AS owed_cents
    `).first();

    const recent = await env.DB.prepare(`
      SELECT COUNT(*) AS n FROM users WHERE created_at > ?
    `).bind(now() - 7 * 864e5).first();

    return json({
      users: s.users,
      banned: s.banned,
      monetized: s.monetized,
      videos: s.videos,
      comments: s.comments,
      views: s.views,
      pendingApplications: s.pending_apps,
      openReports: s.open_reports,
      owedCents: s.owed_cents,
      newUsersThisWeek: recent.n,
    });
  }

  if (path === "/api/admin/users" && method === "GET") {
    requireStaff(user);
    const q = (url.searchParams.get("q") || "").trim();
    const filter = url.searchParams.get("filter") || "all";

    let sql = `
      SELECT u.id, u.username, u.display_name, u.email, u.role, u.status,
             u.monetized, u.avatar_key, u.created_at,
             (SELECT COUNT(*) FROM videos WHERE user_id = u.id) AS videos,
             (SELECT COUNT(*) FROM follows WHERE followee_id = u.id
                AND status = 'accepted') AS followers
      FROM users u WHERE 1=1
    `;
    const binds = [];
    if (q) { sql += " AND (u.username LIKE ? OR u.display_name LIKE ? OR u.email LIKE ?)";
             binds.push(`%${q}%`, `%${q}%`, `%${q}%`); }
    if (filter === "banned") sql += " AND u.status = 'banned'";
    if (filter === "monetized") sql += " AND u.monetized = 1";
    if (filter === "staff") sql += " AND u.role != 'user'";
    sql += " ORDER BY u.created_at DESC LIMIT 100";

    const { results } = await env.DB.prepare(sql).bind(...binds).all();
    return json({
      users: results.map(u => ({
        id: u.id, username: u.username, displayName: u.display_name,
        email: u.email, role: u.role, status: u.status,
        monetized: !!u.monetized, videos: u.videos, followers: u.followers,
        avatarUrl: u.avatar_key ? `/api/media/${u.avatar_key}` : null,
        createdAt: u.created_at,
      })),
    });
  }

  const banMatch = /^\/api\/admin\/users\/([\w-]+)\/ban$/.exec(path);
  if (banMatch && method === "POST") {
    requireStaff(user);
    const target = await env.DB.prepare("SELECT * FROM users WHERE id = ?").bind(banMatch[1]).first();
    if (!target) return err("User not found", 404);
    if (target.id === user.id) return err("You can't ban yourself");
    // A moderator must not be able to remove the person who appointed them.
    if (isAdmin(target) && !isAdmin(user)) return err("Only an admin can ban an admin", 403);

    const { reason } = await request.json().catch(() => ({}));
    await env.DB.prepare(
      "UPDATE users SET status = 'banned', banned_reason = ? WHERE id = ?"
    ).bind(reason?.trim() || "Violated community guidelines", target.id).run();
    // Kill their sessions so the ban is immediate, not eventual.
    await env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(target.id).run();

    await logAdmin(env, user.id, "ban_user", "user", target.id, reason);
    return json({ ok: true });
  }

  const unbanMatch = /^\/api\/admin\/users\/([\w-]+)\/unban$/.exec(path);
  if (unbanMatch && method === "POST") {
    requireStaff(user);
    await env.DB.prepare(
      "UPDATE users SET status = 'active', banned_reason = NULL WHERE id = ?"
    ).bind(unbanMatch[1]).run();
    await logAdmin(env, user.id, "unban_user", "user", unbanMatch[1], null);
    return json({ ok: true });
  }

  const roleMatch = /^\/api\/admin\/users\/([\w-]+)\/role$/.exec(path);
  if (roleMatch && method === "POST") {
    requireAdmin(user);
    const { role } = await request.json();
    if (!["user", "moderator", "admin"].includes(role)) {
      return err("role must be user, moderator or admin");
    }
    if (roleMatch[1] === user.id && role !== "admin") {
      return err("You can't remove your own admin role");
    }
    await env.DB.prepare("UPDATE users SET role = ? WHERE id = ?").bind(role, roleMatch[1]).run();
    await logAdmin(env, user.id, "set_role", "user", roleMatch[1], role);
    return json({ ok: true });
  }

  // Admin review queue for monetization
  if (path === "/api/admin/applications" && method === "GET") {
    requireStaff(user);
    const status = url.searchParams.get("status") || "pending";
    const { results } = await env.DB.prepare(`
      SELECT a.*, u.username, u.display_name, u.avatar_key
      FROM monetization_applications a
      JOIN users u ON u.id = a.user_id
      WHERE a.status = ? ORDER BY a.created_at DESC LIMIT 100
    `).bind(status).all();

    return json({
      applications: results.map(a => ({
        id: a.id,
        status: a.status,
        user: {
          id: a.user_id, username: a.username, displayName: a.display_name,
          avatarUrl: a.avatar_key ? `/api/media/${a.avatar_key}` : null,
        },
        atApply: {
          followers: a.followers_at_apply,
          likes: a.likes_at_apply,
          videos: a.videos_at_apply,
        },
        payoutMethod: a.payout_method,
        payoutDetails: a.payout_details,
        note: a.review_note,
        createdAt: a.created_at,
      })),
    });
  }

  const reviewMatch = /^\/api\/admin\/applications\/([\w-]+)\/(approve|reject)$/.exec(path);
  if (reviewMatch && method === "POST") {
    requireStaff(user);
    const [, appId, decision] = reviewMatch;

    const app = await env.DB.prepare(
      "SELECT * FROM monetization_applications WHERE id = ?"
    ).bind(appId).first();
    if (!app) return err("Application not found", 404);
    if (app.status !== "pending") return err("That application was already reviewed", 409);

    const { note } = await request.json().catch(() => ({}));

    if (decision === "approve") {
      // Numbers can fall between applying and reviewing — check again now.
      const live = await monetizeStats(env, app.user_id);
      if (!live.eligible) {
        return err(
          `They no longer meet the thresholds: ${live.followers} followers, ` +
          `${live.likes} likes, ${live.videos} videos.`,
          409
        );
      }
      await env.DB.batch([
        env.DB.prepare(
          "UPDATE monetization_applications SET status='approved', reviewed_by=?, reviewed_at=?, review_note=? WHERE id=?"
        ).bind(user.id, now(), note?.trim() || null, appId),
        env.DB.prepare("UPDATE users SET monetized = 1 WHERE id = ?").bind(app.user_id),
      ]);
    } else {
      await env.DB.prepare(
        "UPDATE monetization_applications SET status='rejected', reviewed_by=?, reviewed_at=?, review_note=? WHERE id=?"
      ).bind(user.id, now(), note?.trim() || null, appId).run();
    }

    await logAdmin(env, user.id, `${decision}_application`, "application", appId, note);
    return json({ ok: true, status: decision === "approve" ? "approved" : "rejected" });
  }

  const demonetizeMatch = /^\/api\/admin\/users\/([\w-]+)\/demonetize$/.exec(path);
  if (demonetizeMatch && method === "POST") {
    requireStaff(user);
    const { reason } = await request.json().catch(() => ({}));
    await env.DB.prepare("UPDATE users SET monetized = 0 WHERE id = ?").bind(demonetizeMatch[1]).run();
    await logAdmin(env, user.id, "demonetize", "user", demonetizeMatch[1], reason);
    return json({ ok: true });
  }

  // Reports queue
  if (path === "/api/admin/reports" && method === "GET") {
    requireStaff(user);
    const status = url.searchParams.get("status") || "open";
    const { results } = await env.DB.prepare(`
      SELECT r.*, u.username AS reporter_username,
             v.caption AS video_caption, v.r2_key AS video_key, v.thumb_key AS video_thumb,
             vu.username AS video_owner,
             c.body AS comment_body
      FROM reports r
      JOIN users u ON u.id = r.reporter_id
      LEFT JOIN videos v ON v.id = r.video_id
      LEFT JOIN users vu ON vu.id = v.user_id
      LEFT JOIN comments c ON c.id = r.comment_id
      WHERE r.status = ? ORDER BY r.created_at DESC LIMIT 100
    `).bind(status).all();

    return json({
      reports: results.map(r => ({
        id: r.id,
        reason: r.reason,
        detail: r.detail,
        status: r.status,
        reporter: r.reporter_username,
        videoId: r.video_id,
        videoCaption: r.video_caption,
        videoUrl: r.video_key ? `/api/media/${r.video_key}` : null,
        // The poster and owner, so a moderator can see WHAT was reported
        // before deciding — the list used to name a reason with no way to
        // check it against the video.
        videoThumb: r.video_thumb ? `/api/media/${r.video_thumb}` : null,
        videoOwner: r.video_owner || null,
        commentId: r.comment_id,
        commentBody: r.comment_body,
        reportedUserId: r.reported_user_id,
        createdAt: r.created_at,
      })),
    });
  }

  const reportActMatch = /^\/api\/admin\/reports\/([\w-]+)\/resolve$/.exec(path);
  if (reportActMatch && method === "POST") {
    requireStaff(user);
    const { action, note } = await request.json();
    if (!["dismiss", "remove_video", "remove_comment", "ban_user"].includes(action)) {
      return err("Unknown action");
    }

    const r = await env.DB.prepare("SELECT * FROM reports WHERE id = ?").bind(reportActMatch[1]).first();
    if (!r) return err("Report not found", 404);
    if (r.status !== "open") return err("That report was already handled", 409);

    if (action === "remove_video" && r.video_id) {
      const v = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(r.video_id).first();
      if (v) {
        // Only drop the R2 object if no repost still points at it.
        if (!v.repost_of) {
          const reposts = await env.DB.prepare(
            "SELECT COUNT(*) AS n FROM videos WHERE repost_of = ?"
          ).bind(v.id).first();
          if (reposts.n === 0) {
            await env.MEDIA.delete(v.r2_key).catch(() => {});
            if (v.thumb_key) await env.MEDIA.delete(v.thumb_key).catch(() => {});
          }
        }
        // The sound this video created, if it created one. Uploads default to
        // soundShareable, so nearly every video is the source of a `sounds`
        // row pointing back at it — leaving that row behind is what made
        // "Remove video" fail on essentially every report. Unlike the owner's
        // own delete, a moderator is not blocked when other people are using
        // the sound: the video is coming down either way. The sound is only
        // dropped when nothing else references it.
        let orphanedSoundId = null;
        if (v.sound_id) {
          const sound = await env.DB.prepare("SELECT source_video_id FROM sounds WHERE id = ?")
            .bind(v.sound_id).first();
          if (sound && sound.source_video_id === v.id) {
            const stillUsed = await env.DB.prepare(
              "SELECT COUNT(*) AS n FROM videos WHERE sound_id = ? AND id != ?"
            ).bind(v.sound_id, v.id).first();
            if (stillUsed.n === 0) orphanedSoundId = v.sound_id;
          }
        }

        await deleteVideoEverywhere(env, v, { orphanedSoundId, handledBy: user.id });
        // Tell the poster, and say what it was reported for. Their video just
        // vanished from their profile with no explanation anywhere before —
        // the row is written to `notifications` like any other, so it shows in
        // the app's list as well as arriving as a push.
        await notify(env, ctx, v.user_id, user.id, "video_removed", { text: r.reason });
      }
    }

    if (action === "remove_comment" && r.comment_id) {
      await env.DB.batch([
        env.DB.prepare("DELETE FROM comment_reactions WHERE comment_id = ?").bind(r.comment_id),
        env.DB.prepare("DELETE FROM comments WHERE parent_id = ?").bind(r.comment_id),
        env.DB.prepare("DELETE FROM comments WHERE id = ?").bind(r.comment_id),
      ]);
    }

    if (action === "ban_user" && r.reported_user_id) {
      await env.DB.prepare(
        "UPDATE users SET status='banned', banned_reason=? WHERE id = ?"
      ).bind(note?.trim() || r.reason, r.reported_user_id).run();
      await env.DB.prepare("DELETE FROM sessions WHERE user_id = ?").bind(r.reported_user_id).run();
    }

    await env.DB.prepare(
      "UPDATE reports SET status='resolved', handled_by=?, handled_at=?, action_taken=? WHERE id=?"
    ).bind(user.id, now(), action, r.id).run();

    await logAdmin(env, user.id, `report_${action}`, "report", r.id, note);
    return json({ ok: true });
  }

  // Pay out: recalculates from real view counts, never from a client number.
  if (path === "/api/admin/earnings/run" && method === "POST") {
    requireAdmin(user);
    const { period } = await request.json().catch(() => ({}));
    const p = period || new Date().toISOString().slice(0, 7); // YYYY-MM

    const { results } = await env.DB.prepare(`
      SELECT u.id, COALESCE(SUM(v.views), 0) AS views
      FROM users u JOIN videos v ON v.user_id = u.id
      WHERE u.monetized = 1 AND u.status = 'active'
      GROUP BY u.id
    `).all();

    let created = 0;
    for (const row of results) {
      const cents = Math.floor((row.views / 1000) * CENTS_PER_1K_VIEWS);
      if (cents <= 0) continue;
      await env.DB.prepare(`
        INSERT INTO earnings (id, user_id, period, views, amount_cents, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(user_id, period) DO UPDATE SET
          views = excluded.views, amount_cents = excluded.amount_cents
      `).bind(uid(), row.id, p, row.views, cents, now()).run();
      created++;
    }

    await logAdmin(env, user.id, "run_earnings", "period", p, `${created} creators`);
    return json({ ok: true, period: p, creators: created });
  }

  const markPaidMatch = /^\/api\/admin\/earnings\/([\w-]+)\/paid$/.exec(path);
  if (markPaidMatch && method === "POST") {
    requireAdmin(user);
    await env.DB.prepare(
      "UPDATE earnings SET paid = 1, paid_at = ? WHERE id = ?"
    ).bind(now(), markPaidMatch[1]).run();
    await logAdmin(env, user.id, "mark_paid", "earning", markPaidMatch[1], null);
    return json({ ok: true });
  }

  // ----- cash out your coin balance -----
  //
  // Gifts land in coins, and coins could be spent but never withdrawn — the
  // admin payouts view read `earnings` (what the platform owes a monetized
  // creator for views), which is a different thing entirely.
  //
  // Coins leave the balance when the request is MADE, not when it's paid:
  // otherwise the same coins could be requested and then spent before anyone
  // processed it. A rejection puts them back.
  if (path === "/api/wallet/payout" && method === "POST") {
    requireUser(user);
    const { coins, method: payMethod, details } = await request.json().catch(() => ({}));
    const amount = Math.floor(Number(coins) || 0);

    if (amount <= 0) return err("How many coins do you want to cash out?");
    if (!["mobile_money", "bank", "paypal"].includes(payMethod)) {
      return err("Choose how you want to be paid");
    }
    if (!details?.trim()) return err("Add the number or account to pay to");

    const cents = amount * COIN_PRICE_CENTS;
    if (cents < MIN_PAYOUT_CENTS) {
      return err(`The smallest cash-out is $${(MIN_PAYOUT_CENTS / 100).toFixed(2)}`);
    }
    // Re-read the balance rather than trusting anything the client sent.
    const fresh = await env.DB.prepare("SELECT coin_balance FROM users WHERE id = ?")
      .bind(user.id).first();
    if ((fresh?.coin_balance || 0) < amount) return err("You don't have that many coins");

    // ONLY coins that were EARNED can leave as money.
    //
    // Cash-out used to pay out any coin in the balance, so a person could buy
    // 1000 coins for $10 and immediately withdraw the same $10 — the app would
    // take money in and hand it straight back. That is not a gift economy, it
    // is storing value redeemable for cash, which is e-money and needs a BNR
    // licence; and it is a laundering channel besides. Bought coins can be
    // SPENT — that is what they are for — but only gift income turns back into
    // money, which is the same line YouTube and TikTok draw.
    //
    // lifetime_gifts_cents is the earnings record and is never spent from, so
    // it minus everything already taken out is what is genuinely withdrawable.
    const earned = await env.DB.prepare(`
      SELECT COALESCE(u.lifetime_gifts_cents, 0) AS lifetime,
             COALESCE((SELECT SUM(coins) FROM coin_payouts
                       WHERE user_id = ? AND status != 'rejected'), 0) AS taken
      FROM users u WHERE u.id = ?
    `).bind(user.id, user.id).first();
    const withdrawable = (earned?.lifetime || 0) - (earned?.taken || 0);
    if (amount > withdrawable) {
      return err(withdrawable <= 0
        ? "Only coins people gift you can be cashed out. Coins you bought are for sending gifts."
        : `You can cash out ${withdrawable} coins — the rest were bought, and bought coins are for sending gifts.`);
    }

    // One pending request at a time — otherwise a balance can be committed
    // twice over before either is reviewed.
    const open = await env.DB.prepare(
      "SELECT id FROM coin_payouts WHERE user_id = ? AND status = 'pending'"
    ).bind(user.id).first();
    if (open) return err("You already have a cash-out being processed", 409);

    // Currently zero (see PAYOUT_FEE_PERCENT). Stored as the NET regardless,
    // so the admin queue always shows the figure to pay rather than a number
    // to do arithmetic on — and so turning a fee on later changes one constant
    // and nothing else.
    const feeCents = Math.ceil(cents * PAYOUT_FEE_PERCENT / 100);
    const netCents = cents - feeCents;

    const id = uid();
    await env.DB.batch([
      env.DB.prepare("UPDATE users SET coin_balance = coin_balance - ? WHERE id = ?")
        .bind(amount, user.id),
      env.DB.prepare(`
        INSERT INTO coin_payouts (id, user_id, coins, amount_cents, method, details, status, created_at)
        VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
      `).bind(id, user.id, amount, netCents, payMethod, details.trim(), now()),
    ]);

    const after = await env.DB.prepare("SELECT coin_balance FROM users WHERE id = ?")
      .bind(user.id).first();
    await recordTx(env, user.id, "payout_requested", -amount, 0,
                   after.coin_balance, after.coin_balance * COIN_PRICE_CENTS, id, "Cash-out requested");

    return json({
      ok: true,
      payout: {
        id, coins: amount,
        grossCents: cents, feeCents, amountCents: netCents,
        status: "pending",
      },
    });
  }

  // Your own cash-out history, so a request isn't a black hole after sending.
  if (path === "/api/wallet/payouts" && method === "GET") {
    requireUser(user);
    const { results } = await env.DB.prepare(`
      SELECT id, coins, amount_cents, method, status, note, created_at, reviewed_at
      FROM coin_payouts WHERE user_id = ? ORDER BY created_at DESC LIMIT 20
    `).bind(user.id).all();
    return json({
      payouts: results.map(r => ({
        id: r.id, coins: r.coins, amountCents: r.amount_cents, method: r.method,
        status: r.status, note: r.note, createdAt: r.created_at, reviewedAt: r.reviewed_at,
      })),
      minPayoutCents: MIN_PAYOUT_CENTS,
    });
  }

  // ----- admin: the coin cash-out queue -----
  if (path === "/api/admin/coin-payouts" && method === "GET") {
    requireStaff(user);
    const status = url.searchParams.get("status") || "pending";
    const { results } = await env.DB.prepare(`
      SELECT p.*, u.username, u.display_name, u.coin_balance
      FROM coin_payouts p JOIN users u ON u.id = p.user_id
      WHERE p.status = ? ORDER BY p.created_at ASC LIMIT 100
    `).bind(status).all();
    return json({
      payouts: results.map(r => ({
        id: r.id, coins: r.coins, amountCents: r.amount_cents,
        method: r.method, details: r.details, status: r.status, note: r.note,
        username: r.username, displayName: r.display_name,
        balanceAfter: r.coin_balance, createdAt: r.created_at,
      })),
    });
  }

  const coinPayoutMatch = /^\/api\/admin\/coin-payouts\/([\w-]+)$/.exec(path);
  if (coinPayoutMatch && method === "POST") {
    requireStaff(user);
    const { action, note } = await request.json().catch(() => ({}));
    if (!["paid", "rejected"].includes(action)) return err("action must be paid or rejected");

    const p = await env.DB.prepare("SELECT * FROM coin_payouts WHERE id = ?")
      .bind(coinPayoutMatch[1]).first();
    if (!p) return err("Cash-out not found", 404);
    if (p.status !== "pending") return err("That cash-out was already handled", 409);

    const ops = [
      env.DB.prepare(`
        UPDATE coin_payouts SET status = ?, note = ?, reviewed_at = ?, reviewed_by = ? WHERE id = ?
      `).bind(action, note || null, now(), user.id, p.id),
    ];
    // Rejecting hands the coins back — they were taken at request time.
    if (action === "rejected") {
      ops.push(env.DB.prepare("UPDATE users SET coin_balance = coin_balance + ? WHERE id = ?")
        .bind(p.coins, p.user_id));
    }
    await env.DB.batch(ops);

    if (action === "rejected") {
      const after = await env.DB.prepare("SELECT coin_balance FROM users WHERE id = ?")
        .bind(p.user_id).first();
      await recordTx(env, p.user_id, "payout_rejected", p.coins, 0,
                     after.coin_balance, after.coin_balance * COIN_PRICE_CENTS, p.id,
                     note || "Cash-out rejected");
    }
    return json({ ok: true, status: action });
  }

  if (path === "/api/admin/payouts" && method === "GET") {
    requireStaff(user);
    const { results } = await env.DB.prepare(`
      SELECT e.id, e.period, e.views, e.amount_cents, e.paid,
             u.username, u.display_name,
             a.payout_method, a.payout_details
      FROM earnings e
      JOIN users u ON u.id = e.user_id
      LEFT JOIN monetization_applications a
        ON a.user_id = e.user_id AND a.status = 'approved'
      WHERE e.paid = 0 AND e.amount_cents >= ?
      ORDER BY e.amount_cents DESC LIMIT 100
    `).bind(MIN_PAYOUT_CENTS).all();

    return json({
      payouts: results.map(r => ({
        id: r.id, period: r.period, views: r.views,
        amountCents: r.amount_cents,
        username: r.username, displayName: r.display_name,
        method: r.payout_method, details: r.payout_details,
      })),
      minPayoutCents: MIN_PAYOUT_CENTS,
    });
  }

  if (path === "/api/admin/log" && method === "GET") {
    requireAdmin(user);
    const { results } = await env.DB.prepare(`
      SELECT l.*, u.username FROM admin_log l
      JOIN users u ON u.id = l.admin_id
      ORDER BY l.created_at DESC LIMIT 200
    `).all();
    return json({
      log: results.map(l => ({
        id: l.id, admin: l.username, action: l.action,
        targetType: l.target_type, targetId: l.target_id,
        note: l.note, createdAt: l.created_at,
      })),
    });
  }

  // First-run bootstrap: turns the very first account into the admin.
  // Lets the client hide the "Claim admin" button once a site has one,
  // instead of showing it to every new signup and letting the 409 surprise
  // them. Deliberately public — knowing an admin exists reveals nothing.
  if (path === "/api/admin/status" && method === "GET") {
    const existing = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM users WHERE role = 'admin'"
    ).first();
    return json({ hasAdmin: existing.n > 0 });
  }

  // Only works while no admin exists, so it can't be used to seize an
  // established site.
  if (path === "/api/admin/bootstrap" && method === "POST") {
    requireUser(user);
    const existing = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM users WHERE role = 'admin'"
    ).first();
    if (existing.n > 0) return err("An admin already exists", 409);

    await env.DB.prepare("UPDATE users SET role = 'admin' WHERE id = ?").bind(user.id).run();
    await logAdmin(env, user.id, "bootstrap_admin", "user", user.id, "first admin");
    return json({ ok: true, role: "admin" });
  }

  // ============================ LIVE ============================
  //
  // Belople owns the session; Mux is only the video pipe (src/mux.js is the
  // only file that knows it exists). Nothing here hands the app a Mux
  // credential: the creator gets an ingest URL and a stream key for their own
  // broadcast, viewers get a playback id, and neither reaches the account.

  // Go Live: create the Mux stream, open the session, hand back where to push.
  if (path === "/api/live/start" && method === "POST") {
    requireUser(user);

    // Said plainly, before anything else. Without this the missing credential
    // surfaces as a generic 500 — the creator is told "something went wrong on
    // our end" for a thing nobody has set up yet, and the one person who could
    // fix it learns nothing from the message.
    if (!env.MUX_TOKEN_ID || !env.MUX_TOKEN_SECRET) {
      console.error("[LIVE] start refused: MUX_TOKEN_ID / MUX_TOKEN_SECRET are not set");
      return err("Live isn't switched on yet — hang tight", 503);
    }

    // One at a time. Without this a crashed app that reopens starts a second
    // paid encode while the first is still running.
    const open = await env.DB.prepare(
      "SELECT id FROM live_sessions WHERE creator_id = ? AND status IN ('starting','live','ending')"
    ).bind(user.id).first();
    if (open) return err("You already have a live going", 409);

    // The gate the plan asks for. 0 means everyone, which is where it sits
    // until the owner picks a number — every stream costs encoding minutes
    // from the first second whether or not anyone watches.
    const minFollowers = parseInt(env.LIVE_MIN_FOLLOWERS || "0", 10) || 0;
    if (minFollowers > 0) {
      const f = await env.DB.prepare(
        "SELECT COUNT(*) AS n FROM follows WHERE followee_id = ? AND status = 'accepted'"
      ).bind(user.id).first();
      if (f.n < minFollowers) {
        return err(`You need ${minFollowers} followers to go live`, 403);
      }
    }

    const { title } = await request.json().catch(() => ({}));
    const stream = await createLiveStream(env);
    const id = uid();
    const t = now();

    await env.DB.prepare(`
      INSERT INTO live_sessions
        (id, creator_id, title, status, mux_live_stream_id, mux_playback_id, created_at, updated_at)
      VALUES (?, ?, ?, 'starting', ?, ?, ?, ?)
    `).bind(
      id, user.id, (title || "").trim().slice(0, 120) || null,
      stream.liveStreamId, stream.playbackId, t, t
    ).run();

    return json({
      sessionId: id,
      ingestUrl: stream.ingestUrl,
      streamKey: stream.streamKey,
      // The app runs its own countdown from this and stops itself; Mux's
      // max_continuous_duration is the backstop underneath, for when the app
      // is not there to.
      maxSeconds: maxLiveSeconds(env),
    });
  }

  // Discovery: what is on right now. Also the cheapest place to sweep, since
  // it is hit constantly and a stale session must not sit in this list.
  if (path === "/api/live/active" && method === "GET") {
    ctx.waitUntil(sweepAbandonedLives(env));
    const { results: all } = await env.DB.prepare(`
      SELECT l.id, l.title, l.viewer_count, l.started_at,
             u.id AS creator_id, u.username, u.display_name, u.avatar_key, u.country
      FROM live_sessions l
      JOIN users u ON u.id = l.creator_id
      WHERE l.status = 'live' AND u.status = 'active'
      -- Newest first, NOT by audience. viewer_count is recomputed every ten
      -- seconds from who is actually watching, so ordering by it reshuffles
      -- the list under a finger mid-scroll: the live at position 1 when you
      -- tapped is at position 3 by the time the screen opens, and swiping
      -- "down" walks you backwards. started_at never moves.
      ORDER BY l.started_at DESC, l.id
      LIMIT 50
    `).all();

    // Three from home, then one from anywhere, then three from home again.
    //
    // A viewer with no country of their own — plenty never set one — sees the
    // list unchanged rather than an arbitrary "foreign" half, and when one
    // side runs out the other simply continues. Every live still appears
    // exactly once: this orders the list, it does not pad it, so scrolling
    // past the last one reaches the end instead of meeting the same faces
    // again.
    const results = interleaveByCountry(all, user?.country);

    return json({
      lives: results.map(r => ({
        id: r.id,
        title: r.title,
        viewerCount: r.viewer_count,
        startedAt: r.started_at,
        creator: {
          id: r.creator_id,
          username: r.username,
          displayName: r.display_name,
          avatarUrl: r.avatar_key ? `/api/media/${r.avatar_key}` : null,
        },
      })),
    });
  }

  // Mux calling back. Verified before it is believed: this endpoint can end
  // anyone's broadcast.
  if (path === "/api/live/webhook" && method === "POST") {
    // Two different refusals, and they must not look alike in the log. No
    // secret means WE are not set up and cannot check anyone; a bad signature
    // means someone who is not Mux is trying to end a broadcast. Both are
    // rejected, but a 500 for the first would have read as a crash.
    if (!env.MUX_WEBHOOK_SECRET) {
      console.error("[LIVE] webhook rejected: MUX_WEBHOOK_SECRET is not set");
      return err("Live webhooks are not configured", 503);
    }
    const raw = await request.text();
    const ok = await verifyWebhook(env, raw, request.headers.get("Mux-Signature"));
    if (!ok) {
      console.error("[LIVE] webhook rejected: signature did not verify");
      return err("Bad signature", 401);
    }

    let event;
    try { event = JSON.parse(raw); } catch { return err("Bad body", 400); }
    const type = event?.type;
    const data = event?.data || {};

    // A live stream id identifies the session for every event we care about;
    // asset events carry it as data.live_stream_id.
    const liveStreamId = type?.startsWith("video.asset") ? data.live_stream_id : data.id;
    if (!liveStreamId) return json({ ok: true, ignored: type });

    const session = await env.DB.prepare(
      "SELECT * FROM live_sessions WHERE mux_live_stream_id = ?"
    ).bind(liveStreamId).first();
    // Not ours, or already deleted. Acknowledge — retrying helps nobody.
    if (!session) return json({ ok: true, unknown: liveStreamId });

    switch (type) {
      case "video.live_stream.active":
        // The encoder connected: the moment it becomes watchable, and the
        // moment the meter starts.
        if (session.status === "starting" || session.status === "live") {
          await env.DB.prepare(
            "UPDATE live_sessions SET status = 'live', started_at = COALESCE(started_at, ?), updated_at = ? WHERE id = ?"
          ).bind(now(), now(), session.id).run();
          if (session.status === "starting") ctx.waitUntil(notifyFollowersLive(env, session));
        }
        break;

      case "video.live_stream.disconnected":
        // NOT the end. Mux holds the reconnect window open and the creator may
        // walk back into signal; tearing the session down here is what would
        // make a lift ride end someone's broadcast.
        await env.DB.prepare(
          "UPDATE live_sessions SET updated_at = ? WHERE id = ?"
        ).bind(now(), session.id).run();
        break;

      case "video.live_stream.idle":
        // The reconnect window expired. Now it is over.
        await endLiveSession(env, session, session.end_reason || "creator");
        break;

      case "video.asset.live_stream_completed":
        // The recording Mux makes whether we want it or not. Remember which it
        // is, then delete it — storage bills from the moment it exists.
        await env.DB.prepare(
          "UPDATE live_sessions SET mux_asset_id = COALESCE(mux_asset_id, ?), updated_at = ? WHERE id = ?"
        ).bind(data.id, now(), session.id).run();
        ctx.waitUntil(cleanupLiveSession(env, session.id));
        break;
    }

    return json({ ok: true });
  }

  // Everything below is /api/live/<id>/<action>.
  const liveMatch = path.match(/^\/api\/live\/([^/]+)(?:\/([^/]+))?$/);
  if (liveMatch && !["start", "active", "webhook"].includes(liveMatch[1])) {
    const action = liveMatch[2] || "";
    const session = await env.DB.prepare(
      "SELECT * FROM live_sessions WHERE id = ?"
    ).bind(liveMatch[1]).first();
    if (!session) return err("That live has ended", 404);

    const isOwner = user && user.id === session.creator_id;
    const watchable = session.status === "live";

    // The creator ending it themselves.
    if (action === "end" && method === "POST") {
      requireUser(user);
      if (!isOwner) throw new HttpError("That isn't your live", 403);
      // Tell Mux rather than waiting out the reconnect window, then mark it.
      // This is not trusted on its own — the webhook confirms — because an app
      // can be killed between the tap and the request.
      try { await completeLiveStream(env, session.mux_live_stream_id); }
      catch (e) { console.error("[LIVE] complete failed", session.id, e); }
      await endLiveSession(env, session, "creator");
      return json({ ok: true });
    }

    // Watching: the payload the live screen opens with.
    if (action === "" && method === "GET") {
      if (!watchable && !isOwner) return err("That live has ended", 410);
      const creator = await env.DB.prepare(
        "SELECT id, username, display_name, avatar_key FROM users WHERE id = ?"
      ).bind(session.creator_id).first();

      let following = false;
      if (user) {
        const f = await env.DB.prepare(
          "SELECT status FROM follows WHERE follower_id = ? AND followee_id = ?"
        ).bind(user.id, session.creator_id).first();
        following = f?.status === "accepted";
      }

      return json({
        id: session.id,
        title: session.title,
        status: session.status,
        // The LIVE stream's playback id, never the recorded asset's. The
        // asset's is the DVR one and would let a viewer scrub back to the
        // beginning — the replay Belople does not have.
        playbackUrl: session.mux_playback_id ? playbackUrl(session.mux_playback_id) : null,
        startedAt: session.started_at,
        viewerCount: session.viewer_count,
        isOwner,
        following,
        creator: {
          id: creator.id,
          username: creator.username,
          displayName: creator.display_name,
          avatarUrl: creator.avatar_key ? `/api/media/${creator.avatar_key}` : null,
        },
      });
    }

    // The one call the live screen repeats: new comments since `since`, the
    // audience size, and whether it is still on. Presence rides on it, so
    // watching costs one request rather than two.
    if (action === "stream" && method === "GET") {
      const since = parseInt(url.searchParams.get("since") || "0", 10) || 0;
      const t = now();

      if (user && watchable) {
        // Written at most every LIVE_PRESENCE_WRITE_MS per viewer, not every
        // poll — a row per person per 3s is exactly what the plan rules out.
        const seen = await env.DB.prepare(
          "SELECT last_seen FROM live_viewers WHERE live_session_id = ? AND user_id = ?"
        ).bind(session.id, user.id).first();
        if (!seen || t - seen.last_seen > LIVE_PRESENCE_WRITE_MS) {
          await env.DB.prepare(
            "INSERT OR REPLACE INTO live_viewers (live_session_id, user_id, last_seen) VALUES (?, ?, ?)"
          ).bind(session.id, user.id, t).run();
        }
      }

      // And the count is recomputed at most every LIVE_COUNT_CACHE_MS for the
      // whole room, not once per viewer per poll.
      let viewerCount = session.viewer_count;
      if (watchable && t - session.updated_at > LIVE_COUNT_CACHE_MS) {
        const c = await env.DB.prepare(
          "SELECT COUNT(*) AS n FROM live_viewers WHERE live_session_id = ? AND last_seen > ?"
        ).bind(session.id, t - LIVE_PRESENCE_TTL_MS).first();
        viewerCount = c.n;
        await env.DB.prepare(`
          UPDATE live_sessions
             SET viewer_count = ?, peak_viewer_count = MAX(peak_viewer_count, ?), updated_at = ?
           WHERE id = ?
        `).bind(viewerCount, viewerCount, t, session.id).run();
      }

      const { results } = await env.DB.prepare(`
        SELECT c.id, c.body, c.kind, c.created_at,
               u.id AS user_id, u.username, u.display_name, u.avatar_key
        FROM live_comments c
        JOIN users u ON u.id = c.user_id
        WHERE c.live_session_id = ? AND c.created_at > ?
        ORDER BY c.created_at ASC
        LIMIT 100
      `).bind(session.id, since).all();

      return json({
        status: session.status,
        viewerCount,
        // Rising lines only. There is no cursor backwards, on purpose: the
        // comment stream is not scrollable, matching the video that carries it.
        comments: results.map(r => ({
          id: r.id,
          kind: r.kind,
          body: r.body,
          createdAt: r.created_at,
          user: {
            id: r.user_id,
            username: r.username,
            displayName: r.display_name,
            avatarUrl: r.avatar_key ? `/api/media/${r.avatar_key}` : null,
          },
        })),
        since: results.length ? results[results.length - 1].created_at : since,
      });
    }

    // Saying something.
    if (action === "comments" && method === "POST") {
      requireUser(user);
      if (!watchable) return err("That live has ended", 410);
      const { body } = await request.json().catch(() => ({}));
      const text = (body || "").trim();
      if (!text) return err("Say something first", 400);
      await env.DB.prepare(
        "INSERT INTO live_comments (id, live_session_id, user_id, body, kind, created_at) VALUES (?, ?, ?, ?, 'comment', ?)"
      ).bind(uid(), session.id, user.id, text.slice(0, 300), now()).run();
      return json({ ok: true });
    }

    // Reactions. The tap is instant in the UI and the count is approximate by
    // design — a row per tap would be the most expensive thing on the screen,
    // so a burst arrives as one number and lands as one row.
    if (action === "like" && method === "POST") {
      requireUser(user);
      if (!watchable) return json({ ok: true });
      const { count } = await request.json().catch(() => ({}));
      const n = Math.min(Math.max(parseInt(count, 10) || 1, 1), 50);
      await env.DB.prepare(
        "INSERT INTO live_comments (id, live_session_id, user_id, body, kind, created_at) VALUES (?, ?, ?, ?, 'like', ?)"
      ).bind(uid(), session.id, user.id, String(n), now()).run();
      return json({ ok: true });
    }

    // A gift, sent live. The money rules are NOT re-implemented here: same
    // creator share, same atomic balance check in the WHERE clause, same
    // earnings record and same ledger as /api/gifts. Only the target differs —
    // a session instead of a video.
    //
    // [count] is the combo: tapping the gift repeatedly sends ONE request with
    // the number of taps rather than one request per tap. The whole combo is
    // charged in a single UPDATE, so a burst can never half-succeed and leave
    // someone charged for gifts nobody saw.
    if (action === "gift" && method === "POST") {
      requireUser(user);
      if (!watchable) return err("That live has ended", 410);
      if (session.creator_id === user.id) return err("You can't gift your own live");

      const { giftKey, count } = await request.json().catch(() => ({}));
      const gift = giftByKey(giftKey);
      if (!gift) return err("Unknown gift");
      const n = Math.min(Math.max(parseInt(count, 10) || 1, 1), LIVE_GIFT_MAX_COMBO);
      const totalCoins = gift.coins * n;

      const spend = await env.DB.prepare(
        "UPDATE users SET coin_balance = coin_balance - ? WHERE id = ? AND coin_balance >= ?"
      ).bind(totalCoins, user.id, totalCoins).run();
      if (!spend.meta.changes) {
        return err(`Not enough coins — that's ${totalCoins}`, 402);
      }

      const grossCents = Math.floor(totalCoins * COIN_PRICE_CENTS);
      const creatorCents = Math.floor(grossCents * CREATOR_SHARE);
      const giftId = uid();

      await env.DB.batch([
        env.DB.prepare(`
          INSERT INTO gifts (id, sender_id, recipient_id, video_id, live_session_id, gift_key, coins, value_cents, created_at)
          VALUES (?, ?, ?, NULL, ?, ?, ?, ?, ?)
        `).bind(giftId, user.id, session.creator_id, session.id, gift.key, totalCoins, creatorCents, now()),
        env.DB.prepare(`
          UPDATE users SET coin_balance = coin_balance + ?,
                           lifetime_gifts_cents = lifetime_gifts_cents + ?
          WHERE id = ?
        `).bind(creatorCents, creatorCents, session.creator_id),
      ]);

      // Into the same rising stream everyone is already reading, so the room
      // sees it without a second channel. The body carries the key and the
      // combo count; the app turns that into the banner.
      await env.DB.prepare(
        "INSERT INTO live_comments (id, live_session_id, user_id, body, kind, created_at) VALUES (?, ?, ?, ?, 'gift', ?)"
      ).bind(uid(), session.id, user.id, `${gift.key}|${n}`, now()).run();

      const [me, them] = await Promise.all([
        env.DB.prepare("SELECT coin_balance, gift_balance_cents FROM users WHERE id = ?").bind(user.id).first(),
        env.DB.prepare("SELECT coin_balance, gift_balance_cents FROM users WHERE id = ?").bind(session.creator_id).first(),
      ]);
      const label = n > 1 ? `${gift.emoji} ${gift.name} x${n}` : `${gift.emoji} ${gift.name}`;
      await recordTx(env, user.id, "gift_sent", -totalCoins, 0,
                     me.coin_balance, me.gift_balance_cents, giftId, label);
      await recordTx(env, session.creator_id, "gift_received", 0, creatorCents,
                     them.coin_balance, them.gift_balance_cents, giftId, label);

      return json({ ok: true, coins: totalCoins, balance: me.coin_balance });
    }

    // Announcing yourself, so the creator sees the room fill up. Once per
    // person — a viewer whose signal drops shouldn't "join" again and again.
    if (action === "join" && method === "POST") {
      requireUser(user);
      if (!watchable) return json({ ok: true });
      const already = await env.DB.prepare(
        "SELECT 1 AS x FROM live_comments WHERE live_session_id = ? AND user_id = ? AND kind = 'join'"
      ).bind(session.id, user.id).first();
      if (!already) {
        await env.DB.prepare(
          "INSERT INTO live_comments (id, live_session_id, user_id, body, kind, created_at) VALUES (?, ?, ?, '', 'join', ?)"
        ).bind(uid(), session.id, user.id, now()).run();
      }
      return json({ ok: true });
    }
  }

  return err("Not found", 404);
}

// ---------- live: presence tuning ----------
//
// How long a viewer counts as present after their last poll, how rarely that
// presence is actually written, and how rarely the room is recounted. Viewers
// poll every ~3s; writing on every poll would be a database write per person
// per 3s, which is exactly what the plan rules out.
const LIVE_PRESENCE_TTL_MS = 30_000;
const LIVE_PRESENCE_WRITE_MS = 15_000;
const LIVE_COUNT_CACHE_MS = 10_000;

/// How far a gift combo can run. The owner set this at 1000 deliberately: a
/// supporter who wants to send a thousand should be able to keep tapping and
/// have it land.
///
/// The ceiling is not what protects the wallet — the balance is. Every combo
/// is charged in one UPDATE with `WHERE coin_balance >= ?`, so a run longer
/// than someone can afford is refused whole rather than partly taken. This
/// number only bounds a single request.
const LIVE_GIFT_MAX_COMBO = 1000;

/// The mix in Live discovery: this many from the viewer's own country, then
/// one from anywhere else, repeating. Home first because that is who you can
/// actually talk to; the outsider so the feed is not a village.
const LIVE_HOME_RUN = 3;

/// Orders live sessions as LIVE_HOME_RUN from the viewer's own country, then
/// one from anywhere else, repeating.
///
/// Countries are compared by NAME, the same way ad targeting does it — the
/// column holds a name, not a code, and the two must not start disagreeing.
///
/// Nothing is duplicated and nothing is dropped: both queues drain, and when
/// one empties the other finishes the list on its own. That is what makes
/// scrolling to the bottom of Live actually end.
function interleaveByCountry(sessions, viewerCountry) {
  if (!viewerCountry) return sessions;

  const home = sessions.filter(s => s.country === viewerCountry);
  const away = sessions.filter(s => s.country !== viewerCountry);
  if (!home.length || !away.length) return sessions;

  const out = [];
  let h = 0, a = 0;
  while (h < home.length || a < away.length) {
    for (let i = 0; i < LIVE_HOME_RUN && h < home.length; i++) out.push(home[h++]);
    if (a < away.length) out.push(away[a++]);
    // Home is exhausted — the rest of the world finishes the list rather than
    // the list finishing early.
    if (h >= home.length) {
      while (a < away.length) out.push(away[a++]);
    }
  }
  return out;
}

// ---------- live: ending, cleanup, and the sweeper ----------

/// Closes a session and starts cleanup. Safe to call twice: a session that has
/// already ended is left alone, which matters because the creator's tap and
/// Mux's webhook both arrive and either may be first.
async function endLiveSession(env, session, reason) {
  if (session.status === "ended") return;
  const t = now();
  await env.DB.prepare(`
    UPDATE live_sessions
       SET status = 'ended', ended_at = COALESCE(ended_at, ?), end_reason = COALESCE(end_reason, ?), updated_at = ?
     WHERE id = ? AND status != 'ended'
  `).bind(t, reason, t, session.id).run();

  // Presence rows have nothing left to describe.
  await env.DB.prepare("DELETE FROM live_viewers WHERE live_session_id = ?").bind(session.id).run();

  await cleanupLiveSession(env, session.id);
}

/// Deletes what Mux made. This is the one that costs money if it is skipped:
/// every RTMP session creates a recorded asset, there is no way to turn that
/// off, and storage bills from the moment it exists until it is deleted.
///
/// Idempotent in both directions — `cleaned_at` stops a second pass, and
/// src/mux.js treats a 404 from Mux as success.
async function cleanupLiveSession(env, sessionId) {
  const s = await env.DB.prepare("SELECT * FROM live_sessions WHERE id = ?").bind(sessionId).first();
  if (!s || s.cleaned_at) return;

  try {
    await deleteAsset(env, s.mux_asset_id);
    await deleteLiveStream(env, s.mux_live_stream_id);
    await env.DB.prepare(
      "UPDATE live_sessions SET mux_asset_id = NULL, cleaned_at = ?, updated_at = ? WHERE id = ?"
    ).bind(now(), now(), sessionId).run();
  } catch (e) {
    // Deliberately NOT swallowed, and deliberately not marked clean: an asset
    // we failed to delete is a bill that keeps running, so it stays on the
    // books for the sweeper to retry.
    console.error("[LIVE] cleanup failed for", sessionId, e);
  }
}

/// The safety net. Ends sessions nobody closed — a creator whose phone died,
/// an app killed mid-broadcast — and retries cleanups that failed. Mux's own
/// max_continuous_duration sits underneath as the last backstop; this exists
/// so the bill stops at OUR limit rather than at Mux's.
async function sweepAbandonedLives(env) {
  const t = now();
  const maxMs = maxLiveSeconds(env) * 1000;

  // Live past its allowed length, or never got an encoder at all.
  const { results: stale } = await env.DB.prepare(`
    SELECT * FROM live_sessions
     WHERE status IN ('starting','live','ending')
       AND ((started_at IS NOT NULL AND started_at < ?) OR (started_at IS NULL AND created_at < ?))
     LIMIT 20
  `).bind(t - maxMs, t - 10 * 60 * 1000).all();

  for (const s of stale) {
    try { await completeLiveStream(env, s.mux_live_stream_id); }
    catch (e) { console.error("[LIVE] sweeper complete failed", s.id, e); }
    await endLiveSession(env, s, s.started_at ? "max_duration" : "abandoned");
  }

  // Cleanups that failed earlier still owe Mux a delete.
  const { results: dirty } = await env.DB.prepare(`
    SELECT id FROM live_sessions
     WHERE cleaned_at IS NULL AND status = 'ended' AND ended_at < ?
     LIMIT 20
  `).bind(t - 60_000).all();
  for (const d of dirty) await cleanupLiveSession(env, d.id);
}

/// Tells the creator's followers they are on. Capped and run after the
/// response — on a growing account this is the one part of going live whose
/// cost scales with the audience rather than with the broadcast.
async function notifyFollowersLive(env, session) {
  try {
    const { results } = await env.DB.prepare(`
      SELECT follower_id FROM follows
       WHERE followee_id = ? AND status = 'accepted'
       ORDER BY created_at DESC LIMIT 500
    `).bind(session.creator_id).all();
    for (const f of results) {
      await notify(env, null, f.follower_id, session.creator_id, "live", {});
    }
  } catch (e) {
    console.error("[LIVE] notifying followers failed", session.id, e);
  }
}

export default {
  async fetch(request, env, ctx) {
    // CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: {
          "Access-Control-Allow-Origin": "*",
          "Access-Control-Allow-Methods": "GET,POST,PATCH,DELETE,OPTIONS",
          "Access-Control-Allow-Headers": "Content-Type,Authorization",
        },
      });
    }

    try {
      const res = await handle(request, env, ctx);
      if (res) {
        // Some responses this handler returns (notably a Cache API hit) have
        // immutable headers — wrapping in a fresh Response before mutating
        // is the only way that works for every response shape uniformly.
        const out = new Response(res.body, res);
        out.headers.set("Access-Control-Allow-Origin", "*");
        return out;
      }
      return env.ASSETS.fetch(request);
    } catch (e) {
      if (e instanceof HttpError) return err(e.message, e.status);
      console.error(e);
      return err("Something went wrong on our end", 500);
    }
  },

  // A live that nobody closes still bills. /api/live/active sweeps too, but
  // that only runs while somebody is looking — and the worst case is precisely
  // the quiet one: a forgotten broadcast at 3am with no viewers, no app, and
  // an encoder still running. This runs whether anyone is there or not.
  async scheduled(event, env, ctx) {
    ctx.waitUntil(sweepAbandonedLives(env));
  },
};
