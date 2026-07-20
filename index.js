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
});

// One query returns every video with real counts + whether the viewer liked it.
const FEED_SQL = `
  SELECT
    v.id, v.caption, v.song, v.r2_key, v.thumb_key, v.width, v.height,
    v.duration, v.views, v.created_at, v.repost_of,
    u.id AS user_id, u.username, u.display_name, u.avatar_key,
    ru.username AS repost_of_username,
    (SELECT COUNT(*) FROM likes    l WHERE l.video_id = v.id) AS like_count,
    (SELECT COUNT(*) FROM comments c WHERE c.video_id = v.id) AS comment_count,
    (SELECT COUNT(*) FROM shares   s WHERE s.video_id = v.id) AS share_count,
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
    const cache = caches.default;
    const cacheKey = new Request(new URL(request.url).toString(), {
      method: "GET",
      headers: range ? { Range: range } : {},
    });

    const hit = await cache.match(cacheKey);
    if (hit) return hit;

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
    ctx.waitUntil(cache.put(cacheKey, response.clone()));
    return response;
  }

  const user = await getUser(request, env);

  // ----- auth -----
  if (path === "/api/auth/signup" && method === "POST") {
    const { username, email, password, displayName } = await request.json();
    if (!username || !email || !password) return err("username, email and password are required");
    if (password.length < 8) return err("Password must be at least 8 characters");
    if (!/^[a-z0-9_]{3,20}$/i.test(username)) return err("Username must be 3-20 letters, numbers or underscores");

    const existing = await env.DB.prepare(
      "SELECT id FROM users WHERE username = ? OR email = ?"
    ).bind(username, email).first();
    if (existing) return err("That username or email is already taken", 409);

    const id = uid();
    await env.DB.prepare(`
      INSERT INTO users (id, username, email, password_hash, display_name, bio, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?)
    `).bind(id, username, email, await hashPassword(password), displayName || username, "", now()).run();

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

    await env.DB.batch([
      env.DB.prepare("DELETE FROM likes WHERE user_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM comments WHERE user_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM shares WHERE user_id = ?").bind(user.id),
      env.DB.prepare("DELETE FROM follows WHERE follower_id = ? OR followee_id = ?").bind(user.id, user.id),
      env.DB.prepare("DELETE FROM messages WHERE sender_id = ? OR recipient_id = ?").bind(user.id, user.id),
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

    if (tab === "following") {
      requireUser(user);
      sql += ` WHERE ${NOT_BANNED} AND ${visible} AND v.user_id IN (
                 SELECT followee_id FROM follows
                 WHERE follower_id = ? AND status = 'accepted'
               )`;
      binds.push(viewerId, viewerId, user.id);
      if (cursor) { sql += " AND v.created_at < ?"; binds.push(parseInt(cursor)); }
    } else {
      sql += ` WHERE ${NOT_BANNED} AND ${visible}`;
      binds.push(viewerId, viewerId);
      if (cursor) { sql += " AND v.created_at < ?"; binds.push(parseInt(cursor)); }
    }

    sql += " ORDER BY v.created_at DESC LIMIT ?";
    binds.push(limit);

    const { results } = await env.DB.prepare(sql).bind(...binds).all();
    const videos = results.map(shapeVideo);
    return json({
      videos,
      nextCursor: videos.length === limit ? String(results[results.length - 1].created_at) : null,
    });
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

    await env.DB.prepare(`
      INSERT INTO videos (id, user_id, r2_key, thumb_key, caption, song, width, height, duration, visibility, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      id, user.id, key, thumbKey,
      form.get("caption") || "",
      form.get("song") || `Original sound - ${user.username}`,
      parseInt(form.get("width")) || null,
      parseInt(form.get("height")) || null,
      duration,
      visibility,
      now()
    ).run();

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

    await env.MEDIA.delete(v.r2_key);
    if (v.thumb_key) await env.MEDIA.delete(v.thumb_key);
    await env.DB.batch([
      env.DB.prepare("DELETE FROM likes WHERE video_id = ?").bind(v.id),
      env.DB.prepare("DELETE FROM comments WHERE video_id = ?").bind(v.id),
      env.DB.prepare("DELETE FROM shares WHERE video_id = ?").bind(v.id),
      env.DB.prepare("DELETE FROM videos WHERE id = ?").bind(v.id),
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
    if (parentId) {
      const parent = await env.DB.prepare(
        "SELECT id, parent_id, video_id FROM comments WHERE id = ?"
      ).bind(parentId).first();
      if (!parent) return err("That comment no longer exists", 404);
      if (parent.video_id !== commentMatch[1]) return err("Comment doesn't belong to this video");
      rootId = parent.parent_id || parent.id;
    }

    const id = uid();
    await env.DB.prepare(
      "INSERT INTO comments (id, video_id, user_id, body, parent_id, created_at) VALUES (?, ?, ?, ?, ?, ?)"
    ).bind(id, commentMatch[1], user.id, body.trim(), rootId, now()).run();

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
    await env.DB.prepare(
      "INSERT INTO shares (id, video_id, user_id, created_at) VALUES (?, ?, ?, ?)"
    ).bind(uid(), shareMatch[1], user.id, now()).run();

    const c = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM shares WHERE video_id = ?"
    ).bind(shareMatch[1]).first();
    return json({ count: c.n, url: `${url.origin}/v/${shareMatch[1]}` });
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
    // Reposts point at the same R2 object — no file is copied.
    await env.DB.prepare(`
      INSERT INTO videos (id, user_id, r2_key, thumb_key, caption, song, width, height, duration, repost_of, created_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `).bind(
      id, user.id, original.r2_key, original.thumb_key,
      original.caption, original.song, original.width, original.height,
      original.duration, original.id, now()
    ).run();

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
      ? await env.DB.prepare(FEED_SQL + " WHERE v.user_id = ? ORDER BY v.created_at DESC")
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
    const { results } = await env.DB.prepare(`
      SELECT m.*, u.username, u.display_name, u.avatar_key FROM messages m
      JOIN users u ON u.id = CASE WHEN m.sender_id = ? THEN m.recipient_id ELSE m.sender_id END
      WHERE m.sender_id = ? OR m.recipient_id = ?
      ORDER BY m.created_at DESC LIMIT 50
    `).bind(user.id, user.id, user.id).all();

    return json({
      threads: results.map(m => ({
        id: m.id,
        body: m.body,
        createdAt: m.created_at,
        with: {
          username: m.username,
          displayName: m.display_name,
          avatarUrl: m.avatar_key ? `/api/media/${m.avatar_key}` : null,
        },
        outgoing: m.sender_id === user.id,
      })),
    });
  }

  // One conversation, oldest first — what the chat screen reads.
  const convoMatch = /^\/api\/messages\/([\w-]+)$/.exec(path);
  if (convoMatch && method === "GET") {
    requireUser(user);
    const other = convoMatch[1];

    const them = await env.DB.prepare(
      "SELECT id, username, display_name, avatar_key, status FROM users WHERE id = ? OR username = ?"
    ).bind(other, other).first();
    if (!them) return err("User not found", 404);

    const { results } = await env.DB.prepare(`
      SELECT id, sender_id, body, video_id, created_at FROM messages
      WHERE (sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?)
      ORDER BY created_at ASC LIMIT 200
    `).bind(user.id, them.id, them.id, user.id).all();

    return json({
      with: {
        id: them.id,
        username: them.username,
        displayName: them.display_name,
        avatarUrl: them.avatar_key ? `/api/media/${them.avatar_key}` : null,
      },
      messages: results.map(m => ({
        id: m.id,
        body: m.body,
        videoId: m.video_id,
        createdAt: m.created_at,
        outgoing: m.sender_id === user.id,
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
        res.headers.set("Access-Control-Allow-Origin", "*");
        return res;
      }
      return env.ASSETS.fetch(request);
    } catch (e) {
      if (e instanceof HttpError) return err(e.message, e.status);
      console.error(e);
      return err("Something went wrong on our end", 500);
    }
  },
};
