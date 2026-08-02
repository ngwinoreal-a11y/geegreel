// Video app API — Cloudflare Worker
// Bindings: DB (D1), MEDIA (R2)

const JSON_HEADERS = { "Content-Type": "application/json" };

const json = (data, status = 200, extra = {}) =>
  new Response(JSON.stringify(data), { status, headers: { ...JSON_HEADERS, ...extra } });

const err = (message, status = 400) => json({ error: message }, status);

const uid = () => crypto.randomUUID();
const now = () => Date.now();

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

// ---------- gifts and coins ----------
//
// Two currencies, deliberately:
//   coins  — what a viewer buys and spends. No cash value going out.
//   cents  — what a creator receives and can withdraw.
// They're separate so a creator can't buy coins, gift themselves, and cash out
// the same money in a loop.

const COIN_PRICE_CENTS = 1;          // 1 coin costs $0.01 to buy
const CREATOR_SHARE = 0.5;           // creator keeps 50% of a gift's value

// Nothing below 2 coins: at 50% share, a 1-coin gift floors to zero for the
// creator — the viewer pays and the creator gets nothing, which is indefensible.
const GIFTS = [
  { key: "rose",     name: "Rose",        coins: 2,    emoji: "🌹" },
  { key: "heart",    name: "Heart",       coins: 6,    emoji: "❤️" },
  { key: "star",     name: "Star",        coins: 10,   emoji: "⭐" },
  { key: "fire",     name: "Fire",        coins: 26,   emoji: "🔥" },
  { key: "crown",    name: "Crown",       coins: 50,   emoji: "👑" },
  { key: "diamond",  name: "Diamond",     coins: 100,  emoji: "💎" },
  { key: "rocket",   name: "Rocket",      coins: 500,  emoji: "🚀" },
  { key: "trophy",   name: "Trophy",      coins: 1000, emoji: "🏆" },
];

const COIN_PACKS = [
  { coins: 100,   cents: 100 },
  { coins: 500,   cents: 500 },
  { coins: 1000,  cents: 1000 },
  { coins: 5000,  cents: 5000 },
];

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
  const jwk = JSON.parse(env.VAPID_PRIVATE_JWK);
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
          "TTL": "60",
          "Authorization": authHeader,
        },
        body,
      });
      if (res.status === 404 || res.status === 410) {
        await env.DB.prepare("DELETE FROM push_subscriptions WHERE id = ?").bind(sub.id).run();
      }
    } catch {}
  }));
}

const NOTIF_TEXT = {
  like: (name) => [`${name} liked your video`, ""],
  comment: (name, text) => [`${name} commented`, text || ""],
  reply: (name, text) => [`${name} replied to your comment`, text || ""],
  follow: (name) => [`${name} started following you`, ""],
  gift: (name) => [`${name} sent you a gift`, ""],
};

// Writes the in-app notification (always) and fires a push (best-effort),
// respecting the recipient's existing notify_* toggles — gifts are the one
// exception, since money landing on your video shouldn't be optional.
async function notify(env, ctx, userId, actorId, type, extra = {}) {
  if (!userId || userId === actorId) return;
  const recipient = await env.DB.prepare(
    "SELECT notify_likes, notify_comments, notify_follows FROM users WHERE id = ?"
  ).bind(userId).first();
  if (!recipient) return;

  const pref = type === "follow" ? recipient.notify_follows
             : type === "like" ? recipient.notify_likes
             : type === "gift" ? 1
             : recipient.notify_comments; // comment, reply
  if (!pref) return;

  const id = uid();
  await env.DB.prepare(`
    INSERT INTO notifications (id, user_id, actor_id, type, video_id, comment_id, read, created_at)
    VALUES (?, ?, ?, ?, ?, ?, 0, ?)
  `).bind(id, userId, actorId, type, extra.videoId || null, extra.commentId || null, now()).run();

  ctx.waitUntil((async () => {
    const actor = await env.DB.prepare("SELECT username, display_name FROM users WHERE id = ?").bind(actorId).first();
    const name = actor?.display_name || actor?.username || "Someone";
    const build = NOTIF_TEXT[type];
    if (!build) return;
    const [title, body] = build(name, extra.text);
    await sendPush(env, userId, {
      title, body,
      url: extra.videoId ? `/?video=${extra.videoId}` : extra.username ? `/?user=${extra.username}` : "/",
      tag: type,
    });
  })().catch(() => {}));
}

// Real follower/like/video counts for a user, used by both the applicant's
// progress screen and the admin review — the same numbers either way.
async function monetizeStats(env, userId) {
  const row = await env.DB.prepare(`
    SELECT
      (SELECT COUNT(*) FROM follows WHERE followee_id = ? AND status = 'accepted') AS followers,
      (SELECT COUNT(*) FROM likes l JOIN videos v ON v.id = l.video_id
         WHERE v.user_id = ?) AS likes,
      (SELECT COUNT(*) FROM videos WHERE user_id = ? AND repost_of IS NULL) AS videos,
      (SELECT COALESCE(SUM(views), 0) FROM videos WHERE user_id = ?) AS views
  `).bind(userId, userId, userId, userId).first();

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
  "Gaming", "Movies & TV", "Travel", "Technology", "Education", "Art & Design",
  "Fitness", "News", "Animals & Pets", "Family",
];

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
const FEED_SQL = `
  SELECT
    v.id, v.caption, v.song, v.r2_key, v.thumb_key, v.width, v.height,
    v.duration, v.views, v.created_at, v.repost_of, v.sound_id,
    u.id AS user_id, u.username, u.display_name, u.avatar_key,
    ru.username AS repost_of_username,
    (SELECT COUNT(*) FROM likes    l WHERE l.video_id = v.id) AS like_count,
    (SELECT COUNT(*) FROM comments c WHERE c.video_id = v.id) AS comment_count,
    (SELECT COUNT(*) FROM shares   s WHERE s.video_id = v.id AND s.completed = 1) AS share_count,
    (SELECT COUNT(*) FROM videos   r WHERE r.repost_of = v.id) AS repost_count,
    (SELECT COALESCE(SUM(g.coins), 0) FROM gifts g WHERE g.video_id = v.id) AS gift_coins,
    EXISTS(SELECT 1 FROM likes l WHERE l.video_id = v.id AND l.user_id = ?) AS liked,
    EXISTS(SELECT 1 FROM follows f
            WHERE f.follower_id = ? AND f.followee_id = v.user_id
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
  views: r.views,
  createdAt: r.created_at,
  user: {
    id: r.user_id,
    username: r.username,
    displayName: r.display_name,
    avatarUrl: r.avatar_key ? `/api/media/${r.avatar_key}` : null,
  },
  repostOf: r.repost_of ? { id: r.repost_of, username: r.repost_of_username } : null,
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
  adType: r.type,
  mediaUrl: `/api/media/${r.media_key}`,
  sponsorName: r.sponsor_name,
  caption: r.caption,
  ctaText: r.cta_text,
  linkUrl: r.link_url,
});

// ---------- routes ----------

async function handle(request, env, ctx) {
  const url = new URL(request.url);
  const path = url.pathname;
  const method = request.method;

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
      if (!Array.isArray(interests) || interests.some(i => typeof i !== "string" || !INTERESTS.includes(i))) {
        return err("Invalid interests");
      }
      interestsJson = JSON.stringify(interests.slice(0, 10));
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
    const tab = url.searchParams.get("tab") || "foryou";
    const limit = Math.min(parseInt(url.searchParams.get("limit") || "15"), 30);
    const cursor = url.searchParams.get("cursor");
    const viewerId = user?.id || "";

    let sql = FEED_SQL;
    const binds = [viewerId, viewerId];

    // Visibility gate, applied to every tab: your own videos always show;
    // public shows to all UNLESS the owner's account is private; followers-only
    // (or any video from a private account) needs an accepted follow; private
    // videos never show to anyone else. The account-level "Private account"
    // switch effectively downgrades that user's public videos to followers-only.
    const visible = `(
      v.user_id = ?
      OR (v.visibility = 'public' AND u.is_private = 0)
      OR ((v.visibility = 'followers' OR u.is_private = 1) AND v.visibility != 'private' AND EXISTS(
            SELECT 1 FROM follows f
            WHERE f.follower_id = ? AND f.followee_id = v.user_id AND f.status = 'accepted'
          ))
    )`;

    let offset = 0;

    if (tab === "following") {
      requireUser(user);
      sql += ` WHERE ${NOT_BANNED} AND ${visible} AND v.user_id IN (
                 SELECT followee_id FROM follows
                 WHERE follower_id = ? AND status = 'accepted'
               )`;
      binds.push(viewerId, viewerId, user.id);
      if (cursor) { sql += " AND v.created_at < ?"; binds.push(parseInt(cursor)); }
      sql += " ORDER BY v.created_at DESC LIMIT ?";
      binds.push(limit);
    } else {
      sql += ` WHERE ${NOT_BANNED} AND ${visible}`;
      binds.push(viewerId, viewerId);

      // "For you" ranks by recent engagement decayed by age (a small "hot"
      // score) with a flat boost for creators the viewer follows, instead of
      // pure recency — a feed that's only ever "newest first" never
      // resurfaces something good that's an hour old. created_at stays as
      // the tiebreaker so ties don't reorder between requests.
      offset = cursor ? Math.max(0, parseInt(cursor)) : 0;
      sql += `
        ORDER BY (
          (COALESCE(like_count,0) * 3 + COALESCE(comment_count,0) * 4 +
           COALESCE(share_count,0) * 5 + COALESCE(repost_count,0) * 3 +
           v.views * 0.05 + 1)
          / pow((? - v.created_at) / 3600000.0 + 2, 1.5)
          + (CASE WHEN EXISTS(
               SELECT 1 FROM follows f2
               WHERE f2.follower_id = ? AND f2.followee_id = v.user_id AND f2.status = 'accepted'
             ) THEN 80 ELSE 0 END)
        ) DESC, v.created_at DESC
        LIMIT ? OFFSET ?
      `;
      binds.push(now(), viewerId, limit, offset);
    }

    const { results } = await env.DB.prepare(sql).bind(...binds).all();
    const videos = results.map(shapeVideo);

    let nextCursor;
    if (tab === "following") {
      nextCursor = videos.length === limit ? String(results[results.length - 1].created_at) : null;
    } else {
      nextCursor = results.length === limit ? String(offset + limit) : null;
      // One ad woven into each batch, a few videos in rather than first thing —
      // never on the (ad-free) following tab.
      if (videos.length >= 3) {
        const ad = await env.DB.prepare(
          "SELECT * FROM ads WHERE status = 'active' ORDER BY RANDOM() LIMIT 1"
        ).first();
        if (ad) videos.splice(Math.min(4, videos.length), 0, shapeAd(ad));
      }
    }

    return json({ videos, nextCursor });
  }

  // ----- ads: public view/click tracking -----
  const adViewMatch = /^\/api\/ads\/([\w-]+)\/view$/.exec(path);
  if (adViewMatch && method === "POST") {
    await env.DB.prepare("UPDATE ads SET impressions = impressions + 1 WHERE id = ?")
      .bind(adViewMatch[1]).run();
    return json({ ok: true });
  }

  const adClickMatch = /^\/api\/ads\/([\w-]+)\/click$/.exec(path);
  if (adClickMatch && method === "POST") {
    await env.DB.prepare("UPDATE ads SET clicks = clicks + 1 WHERE id = ?")
      .bind(adClickMatch[1]).run();
    return json({ ok: true });
  }

  // ----- admin: ads -----
  if (path === "/api/admin/ads" && method === "GET") {
    requireStaff(user);
    const { results } = await env.DB.prepare(
      "SELECT * FROM ads ORDER BY created_at DESC"
    ).all();
    return json({ ads: results.map(a => ({ ...shapeAd(a), status: a.status, impressions: a.impressions, clicks: a.clicks, createdAt: a.created_at })) });
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
      INSERT INTO ads (id, type, media_key, sponsor_name, caption, cta_text, link_url, status, created_by, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
    `).bind(
      id, type, key, sponsorName,
      (form.get("caption") || "").trim(),
      (form.get("ctaText") || "Learn more").trim(),
      linkUrl, user.id, now()
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
      SELECT n.id, n.type, n.video_id, n.comment_id, n.read, n.created_at,
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
      INSERT INTO videos (id, user_id, r2_key, thumb_key, caption, song, width, height, duration, visibility, sound_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      id, user.id, key, thumbKey,
      form.get("caption") || "",
      form.get("song") || `Original sound - ${user.username}`,
      parseInt(form.get("width")) || null,
      parseInt(form.get("height")) || null,
      duration,
      visibility,
      soundId,
      now()
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

    const row = await env.DB.prepare(FEED_SQL + " WHERE v.id = ?").bind(user.id, user.id, id).first();
    return json({ video: shapeVideo(row) }, 201);
  }

  // ----- single video -----
  const videoMatch = /^\/api\/videos\/([\w-]+)$/.exec(path);
  if (videoMatch && method === "GET") {
    const row = await env.DB.prepare(FEED_SQL + " WHERE v.id = ?")
      .bind(user?.id || "", user?.id || "", videoMatch[1]).first();
    if (!row) return err("Video not found", 404);
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
    await env.DB.batch([
      env.DB.prepare("DELETE FROM likes WHERE video_id = ?").bind(v.id),
      env.DB.prepare("DELETE FROM comments WHERE video_id = ?").bind(v.id),
      env.DB.prepare("DELETE FROM shares WHERE video_id = ?").bind(v.id),
      env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(v.id),
      ...(orphanedSoundId
        ? [env.DB.prepare("DELETE FROM sounds WHERE id = ?").bind(orphanedSoundId)]
        // This video only used the sound, didn't own it — its own reuse
        // count needs to come back down so the owner's video isn't
        // permanently stuck once this one's gone.
        : v.sound_id
          ? [env.DB.prepare("UPDATE sounds SET uses = MAX(0, uses - 1) WHERE id = ?").bind(v.sound_id)]
          : []),
    ]);
    return json({ ok: true });
  }

  // ----- view counter -----
  const viewMatch = /^\/api\/videos\/([\w-]+)\/view$/.exec(path);
  if (viewMatch && method === "POST") {
    await env.DB.prepare("UPDATE videos SET views = views + 1 WHERE id = ?").bind(viewMatch[1]).run();
    return json({ ok: true });
  }

  // ----- likes -----
  const likeMatch = /^\/api\/videos\/([\w-]+)\/like$/.exec(path);
  if (likeMatch && (method === "POST" || method === "DELETE")) {
    requireUser(user);
    const videoId = likeMatch[1];

    if (method === "POST") {
      await env.DB.prepare(
        "INSERT OR IGNORE INTO likes (user_id, video_id, created_at) VALUES (?, ?, ?)"
      ).bind(user.id, videoId, now()).run();
      const owner = await env.DB.prepare("SELECT user_id FROM videos WHERE id = ?").bind(videoId).first();
      if (owner) await notify(env, ctx, owner.user_id, user.id, "like", { videoId });
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
    `).bind(viewerId, commentMatch[1]).all();

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

    // Respect the video owner's "who can comment" choice. The owner can always
    // comment on their own video; otherwise nobody blocks everyone, and
    // followers limits it to people who follow the owner.
    const vid = await env.DB.prepare(
      "SELECT v.user_id, u.allow_comments FROM videos v JOIN users u ON u.id = v.user_id WHERE v.id = ?"
    ).bind(commentMatch[1]).first();
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
      if (parent.video_id !== commentMatch[1]) return err("Comment doesn't belong to this video");
      rootId = parent.parent_id || parent.id;
      parentAuthorId = parent.user_id;
    }

    const id = uid();
    await env.DB.prepare(
      "INSERT INTO comments (id, video_id, user_id, body, parent_id, created_at) VALUES (?, ?, ?, ?, ?, ?)"
    ).bind(id, commentMatch[1], user.id, body.trim(), rootId, now()).run();

    await notify(env, ctx, vid.user_id, user.id, "comment", { videoId: commentMatch[1], commentId: id, text: body.trim() });
    if (parentAuthorId && parentAuthorId !== vid.user_id) {
      await notify(env, ctx, parentAuthorId, user.id, "reply", { videoId: commentMatch[1], commentId: id, text: body.trim() });
    }

    const c = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM comments WHERE video_id = ?"
    ).bind(commentMatch[1]).first();

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
    // Row starts uncompleted — this only means a share link was generated,
    // not that it went anywhere. The count below (and everywhere else that
    // shows a share count) only counts completed=1, so tapping Share and
    // then cancelling the native share sheet — or never picking an app in
    // the "More" sheet — doesn't move the number. POST /shares/:id/complete
    // is what actually counts it, once the share genuinely happens.
    await env.DB.prepare(
      "INSERT INTO shares (id, video_id, user_id, created_at, completed) VALUES (?, ?, ?, ?, 0)"
    ).bind(shareId, shareMatch[1], user.id, now()).run();

    const c = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM shares WHERE video_id = ? AND completed = 1"
    ).bind(shareMatch[1]).first();
    // ?s= is this specific share event, not just the video — it's how the
    // person who opens the link finds out who sent it to them.
    return json({ count: c.n, shareId, url: `${url.origin}/v/${shareMatch[1]}?s=${shareId}` });
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
    if (!q) return json({ sounds: [] });
    const { results } = await env.DB.prepare(`
      SELECT snd.id, snd.title, snd.uses, snd.r2_key,
             u.username AS author_username, u.display_name AS author_display_name
      FROM sounds snd JOIN users u ON u.id = snd.author_user_id
      WHERE snd.title LIKE ? OR u.username LIKE ?
      ORDER BY snd.uses DESC LIMIT 30
    `).bind(`%${q}%`, `%${q}%`).all();
    return json({
      sounds: results.map(s => ({
        id: s.id, title: s.title, uses: s.uses,
        author: { username: s.author_username, displayName: s.author_display_name },
      })),
    });
  }

  const soundMatch = /^\/api\/sounds\/([\w-]+)$/.exec(path);
  if (soundMatch && method === "GET") {
    const sound = await env.DB.prepare(`
      SELECT snd.id, snd.title, snd.uses, snd.created_at, snd.r2_key, snd.source_video_id,
             u.id AS author_id, u.username AS author_username, u.display_name AS author_display_name,
             u.avatar_key AS author_avatar_key
      FROM sounds snd JOIN users u ON u.id = snd.author_user_id
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
    const original = await env.DB.prepare("SELECT * FROM videos WHERE id = ?").bind(repostMatch[1]).first();
    if (!original) return err("Video not found", 404);

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

    const row = await env.DB.prepare(FEED_SQL + " WHERE v.id = ?").bind(user.id, user.id, id).first();
    return json({ video: shapeVideo(row) }, 201);
  }

  // ----- follows / friend requests -----
  const followMatch = /^\/api\/users\/([\w-]+)\/follow$/.exec(path);
  if (followMatch && (method === "POST" || method === "DELETE")) {
    requireUser(user);
    const targetId = followMatch[1];
    if (targetId === user.id) return err("You can't follow yourself");

    if (method === "POST") {
      await env.DB.prepare(`
        INSERT OR IGNORE INTO follows (follower_id, followee_id, status, created_at)
        VALUES (?, ?, 'accepted', ?)
      `).bind(user.id, targetId, now()).run();
      await notify(env, ctx, targetId, user.id, "follow", { username: user.username });
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
          WHERE v.user_id = ?)                                                       AS likes,
        EXISTS(SELECT 1 FROM follows WHERE follower_id = ? AND followee_id = ?
          AND status = 'accepted')                                                   AS is_following
    `).bind(u.id, u.id, u.id, user?.id || "", u.id).first();

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

    const { results } = canSeeVideos
      ? await env.DB.prepare(FEED_SQL + " WHERE v.user_id = ? ORDER BY v.created_at DESC LIMIT 60")
          .bind(user?.id || "", user?.id || "", u.id).all()
      : { results: [] };

    return json({
      user: publicUser(u),
      // Top-level so the profile's Follow button doesn't have to dig for it.
      following: !!stats.is_following,
      stats: {
        followers: stats.followers,
        following: stats.following,
        likes: stats.likes,
        isFollowing: !!stats.is_following,
      },
      videos: results.map(shapeVideo),
      // True when the account is private and the viewer isn't allowed in, so
      // the UI can show a "this account is private" note instead of an empty grid.
      locked: !!u.is_private && !canSeeVideos,
    });
  }

  // ----- search -----
  if (path === "/api/search" && method === "GET") {
    const q = (url.searchParams.get("q") || "").trim();
    if (!q) return json({ accounts: [], videos: [] });
    const like = `%${q}%`;

    const [accounts, videos] = await Promise.all([
      env.DB.prepare(`
        SELECT id, username, display_name, avatar_key FROM users
        WHERE status != 'banned' AND (username LIKE ? OR display_name LIKE ?) LIMIT 20
      `).bind(like, like).all(),
      env.DB.prepare(FEED_SQL + ` WHERE ${NOT_BANNED} AND v.caption LIKE ? ORDER BY v.created_at DESC LIMIT 20`)
        .bind(user?.id || "", user?.id || "", like).all(),
    ]);

    return json({
      accounts: accounts.results.map(publicUser),
      videos: videos.results.map(shapeVideo),
    });
  }

  // ----- messages -----
  if (path === "/api/messages" && method === "GET") {
    requireUser(user);
    // One row per conversation partner (the latest message with them), not
    // one row per message — a chat with 20 messages back and forth is one
    // person in the inbox, not twenty.
    const { results } = await env.DB.prepare(`
      WITH convo AS (
        SELECT
          CASE WHEN sender_id < recipient_id THEN sender_id ELSE recipient_id END AS a,
          CASE WHEN sender_id < recipient_id THEN recipient_id ELSE sender_id END AS b,
          MAX(created_at) AS last_at
        FROM messages
        WHERE sender_id = ? OR recipient_id = ?
        GROUP BY a, b
      )
      SELECT m.id, m.sender_id, m.recipient_id, m.body, m.created_at,
             u.username, u.display_name, u.avatar_key, u.last_active_at,
             (SELECT COUNT(*) FROM messages um
               WHERE um.recipient_id = ? AND um.read = 0
                 AND um.sender_id = CASE WHEN m.sender_id = ? THEN m.recipient_id ELSE m.sender_id END
             ) AS unread_count
      FROM convo c
      JOIN messages m ON ((m.sender_id = c.a AND m.recipient_id = c.b) OR (m.sender_id = c.b AND m.recipient_id = c.a))
                      AND m.created_at = c.last_at
      JOIN users u ON u.id = CASE WHEN m.sender_id = ? THEN m.recipient_id ELSE m.sender_id END
      ORDER BY m.created_at DESC LIMIT 50
    `).bind(user.id, user.id, user.id, user.id, user.id).all();

    return json({
      threads: results.map(m => ({
        id: m.id,
        body: m.body,
        createdAt: m.created_at,
        unreadCount: m.unread_count,
        with: {
          username: m.username,
          displayName: m.display_name,
          avatarUrl: m.avatar_key ? `/api/media/${m.avatar_key}` : null,
          online: !!(m.last_active_at && now() - m.last_active_at < 120000),
        },
        outgoing: m.sender_id === user.id,
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
    // into any chat app's conversation — done before the select so the
    // response the opener gets back is already consistent with it.
    await env.DB.prepare(
      "UPDATE messages SET read = 1 WHERE sender_id = ? AND recipient_id = ? AND read = 0"
    ).bind(them.id, user.id).run();

    const { results } = await env.DB.prepare(`
      SELECT id, sender_id, body, video_id, created_at, read FROM messages
      WHERE (sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?)
      ORDER BY created_at ASC LIMIT 200
    `).bind(user.id, them.id, them.id, user.id).all();

    return json({
      with: {
        id: them.id,
        username: them.username,
        displayName: them.display_name,
        avatarUrl: them.avatar_key ? `/api/media/${them.avatar_key}` : null,
        online: !!(them.last_active_at && now() - them.last_active_at < 120000),
      },
      messages: results.map(m => ({
        id: m.id,
        body: m.body,
        videoId: m.video_id,
        createdAt: m.created_at,
        outgoing: m.sender_id === user.id,
        read: !!m.read,
      })),
    });
  }

  if (path === "/api/messages" && method === "POST") {
    requireUser(user);
    const { recipientId, body, videoId } = await request.json();
    if (!recipientId) return err("recipientId is required");
    if (!body?.trim() && !videoId) return err("Write a message or attach a video");

    const them = await env.DB.prepare(
      "SELECT id, allow_messages, status FROM users WHERE id = ? OR username = ?"
    ).bind(recipientId, recipientId).first();
    if (!them) return err("User not found", 404);
    if (them.status === "banned") return err("That account is banned", 403);

    // The "who can message you" setting has to be enforced here, or it's just
    // decoration in the settings screen.
    const pref = them.allow_messages || "everyone";
    if (pref === "nobody" && them.id !== user.id) {
      return err("This person isn't accepting messages", 403);
    }
    if (pref === "followers" && them.id !== user.id) {
      const follows = await env.DB.prepare(`
        SELECT 1 FROM follows WHERE follower_id = ? AND followee_id = ? AND status = 'accepted'
      `).bind(them.id, user.id).first();
      if (!follows) return err("Only people they follow can message them", 403);
    }

    const id = uid();
    await env.DB.prepare(`
      INSERT INTO messages (id, sender_id, recipient_id, body, video_id, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
    `).bind(id, user.id, them.id, body?.trim() || null, videoId || null, now()).run();

    return json({ ok: true, id }, 201);
  }

  // ----- wallet, coins, gifts -----

  // What the wallet chip at the top of the profile reads.
  if (path === "/api/wallet" && method === "GET") {
    requireUser(user);
    const totals = await env.DB.prepare(`
      SELECT
        (SELECT COUNT(*) FROM gifts WHERE recipient_id = ?) AS gifts_received,
        (SELECT COUNT(*) FROM gifts WHERE sender_id = ?)    AS gifts_sent
    `).bind(user.id, user.id).first();

    return json({
      coins: user.coin_balance,
      giftBalanceCents: user.gift_balance_cents,
      lifetimeGiftsCents: user.lifetime_gifts_cents,
      giftsReceived: totals.gifts_received,
      giftsSent: totals.gifts_sent,
      coinPacks: COIN_PACKS,
      minPayoutCents: MIN_PAYOUT_CENTS,
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
    const { videoId, giftKey } = await request.json();

    const gift = giftByKey(giftKey);
    if (!gift) return err("Unknown gift");

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
      env.DB.prepare(`
        UPDATE users SET gift_balance_cents = gift_balance_cents + ?,
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
             v.caption AS video_caption, v.r2_key AS video_key,
             c.body AS comment_body
      FROM reports r
      JOIN users u ON u.id = r.reporter_id
      LEFT JOIN videos v ON v.id = r.video_id
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
        await env.DB.batch([
          env.DB.prepare("DELETE FROM likes WHERE video_id = ?").bind(v.id),
          env.DB.prepare("DELETE FROM comments WHERE video_id = ?").bind(v.id),
          env.DB.prepare("DELETE FROM shares WHERE video_id = ?").bind(v.id),
          env.DB.prepare("DELETE FROM videos WHERE repost_of = ?").bind(v.id),
          env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(v.id),
        ]);
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

  return err("Not found", 404);
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
};
