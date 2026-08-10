// ============================================================================
// Belo Flow — Belople's own recommendation engine.
//
// Philosophy: "Every creator deserves a chance. Every user deserves variety.
// Every good video deserves to be discovered." This is NOT a popularity feed.
// It is a deterministic, explainable engine tuned for a SMALL-DATA platform:
// it works with 30 users and stays extensible to millions.
//
// Pipeline (see buildBeloFeed):
//   Candidate Generation -> Hard Filters (in SQL) -> Scoring ->
//   Bucketing (60/20/10/10) -> Diversity Re-ranking (creator cooldown,
//   video-recency penalty, topic diversity, exploration) -> Final Feed.
//
// The pure functions (extractTopics, recencyPenalty, scoreCandidate, reRank,
// classifyBucket, mulberry32) carry the algorithm and are unit-tested without a
// database. The async functions wrap them with D1 access.
// ============================================================================

// ---------------------------------------------------------------------------
// Configuration. Every weight/ratio here is tunable at runtime via the
// reco_config table (see loadConfig) so production data can retune the system
// WITHOUT a redeploy and WITHOUT touching code. Treat these as defaults, never
// as permanent constants.
// ---------------------------------------------------------------------------
export const DEFAULT_CONFIG = {
  // Feed composition — the target share of each slot type per session.
  composition: {
    personalized: 0.60, // strongly related to the viewer's demonstrated taste
    discovery:    0.20, // creators the viewer never / rarely watches
    trending:     0.10, // currently performing (but never popularity-only)
    exploration:  0.10, // deliberately unexpected, anti-bubble
  },

  // Ranking-score weights (sum ~= 1.0). Watch behaviour dominates; likes are
  // deliberately small — Belo Flow learns from what people actually watch.
  weights: {
    watchQuality:     0.25,
    completion:       0.15,
    rewatch:          0.10,
    share:            0.10,
    comment:          0.08,
    followCreator:    0.07,
    like:             0.05,
    personalization:  0.08,
    freshness:        0.07,
    creatorDiscovery: 0.05,
  },

  creatorCooldown: {
    // How many feed positions before the same creator may reappear. Relaxed
    // automatically when few creators exist (see effectiveSeparation).
    minSeparation: 3,
    // Multiplicative score penalty while a creator is still "cooling down".
    // Not zero, so a tiny catalogue still fills gracefully instead of emptying.
    penalty: 0.15,
    // Extra penalty per video already shown from this creator this session.
    perPriorPenalty: 0.12,
  },

  topicDiversity: {
    minSeparation: 2,   // avoid two same-topic videos back to back
    penalty: 0.6,       // milder than creator cooldown
  },

  recency: {
    // Video-repetition penalty half-lives (ms). "engaged" videos (completed /
    // replayed / shared / followed) become eligible again sooner.
    halfLifeDefaultMs: 7  * 24 * 3600 * 1000, // ~7 days
    halfLifeEngagedMs: 2  * 24 * 3600 * 1000, // ~2 days
    // Below this age a just-watched video is effectively excluded.
    hardBlockMs: 60 * 1000, // 1 minute
  },

  freshness: {
    halfLifeMs: 72 * 3600 * 1000, // engagement-independent age decay, ~3 days
  },

  coldStart: {
    // A new video with fewer unique viewers than this is still "under test":
    // it gets a discovery boost so it earns a real test audience instead of
    // being buried at zero views.
    testAudience: 50,
    boost: 0.35,
  },

  smallCreator: {
    // Creators at/under this follower count get a discovery bonus — gated by
    // measured viewer response so it never blindly promotes bad content.
    followerCeiling: 500,
    bonus: 0.30,
  },

  interests: {
    // Behavioural interest profile decay (half-life) so tastes can evolve.
    halfLifeMs: 21 * 24 * 3600 * 1000, // ~3 weeks
  },

  exploration: {
    epsilon: 0.12, // seeded jitter magnitude — keeps the feed fresh each open
  },

  antiManipulation: {
    // A genuine viewer might legitimately replay a few times; beyond this
    // multiple of DISTINCT viewers, extra raw views are treated as noise.
    maxViewsPerViewer: 5,
  },

  candidatePool: 400, // max candidates pulled per feed build (small-data safe)
};

// Deep-merges a partial runtime override onto DEFAULT_CONFIG.
export function mergeConfig(override) {
  const base = structuredCloneSafe(DEFAULT_CONFIG);
  if (!override || typeof override !== "object") return base;
  for (const k of Object.keys(override)) {
    if (override[k] && typeof override[k] === "object" && !Array.isArray(override[k])) {
      base[k] = { ...(base[k] || {}), ...override[k] };
    } else {
      base[k] = override[k];
    }
  }
  return base;
}

function structuredCloneSafe(o) {
  return JSON.parse(JSON.stringify(o));
}

// ===========================================================================
// Pure helpers (unit-tested, no I/O)
// ===========================================================================

// Deterministic PRNG (mulberry32). Same seed => same sequence, so a feed is
// reproducible for pagination yet varies per viewer/session ("fresh each open").
export function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// Cheap 32-bit string hash for seeding.
export function hashSeed(str) {
  let h = 2166136261 >>> 0;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

// Squash any non-negative count/rate into 0..1 with diminishing returns.
function squash(x, k = 1) {
  if (!(x > 0)) return 0;
  return 1 - Math.exp(-x / k);
}

const clamp01 = (x) => (x < 0 ? 0 : x > 1 ? 1 : x);

// A curated lexicon mapping common keywords to topics — used to derive topics
// from captions when creators don't add hashtags. Extend freely; unknown words
// simply don't contribute (hashtags always do).
const TOPIC_LEXICON = {
  music: ["music", "song", "beat", "afrobeat", "gospel", "rap", "singer", "cover", "dance", "amakuru"],
  comedy: ["comedy", "funny", "joke", "prank", "lol", "skit", "seko"],
  football: ["football", "soccer", "goal", "match", "messi", "ronaldo", "apr", "rayon"],
  sports: ["sport", "gym", "fitness", "workout", "run", "boxing"],
  technology: ["tech", "coding", "phone", "ai", "computer", "app", "software"],
  education: ["learn", "study", "school", "tutorial", "howto", "tip", "lesson"],
  food: ["food", "cook", "recipe", "eat", "kitchen"],
  fashion: ["fashion", "outfit", "style", "cloth", "makeup", "beauty"],
  news: ["news", "amakuru", "update", "politics"],
  faith: ["god", "jesus", "prayer", "church", "imana", "gospel"],
  travel: ["travel", "trip", "tour", "visit", "kigali", "rwanda"],
};

// Extracts a small set of lowercase topic tokens from a caption plus any
// declared interests. Hashtags are authoritative; lexicon fills the gaps.
export function extractTopics(caption, declaredInterests = []) {
  const topics = new Set();
  const text = (caption || "").toLowerCase();

  // Hashtags first.
  const tags = text.match(/#([a-z0-9_]{2,30})/g);
  if (tags) for (const t of tags) topics.add(t.slice(1));

  // Lexicon keyword hits — whole-word match (so "beat" doesn't hit "eat").
  const wordSet = new Set((text.match(/[a-z0-9]{2,}/g) || []));
  for (const [topic, words] of Object.entries(TOPIC_LEXICON)) {
    if (words.some((w) => wordSet.has(w))) topics.add(topic);
  }

  // Declared interests (from signup) always count as topics.
  for (const it of declaredInterests || []) {
    const t = String(it || "").toLowerCase().trim();
    if (t) topics.add(t.replace(/\s+/g, "_"));
  }

  return [...topics].slice(0, 8);
}

// Video-repetition recency penalty in 0..1 (1 = just seen, exclude; 0 = fresh
// or never seen). Strongly-engaged videos decay faster so a video the viewer
// loved can become eligible again sooner (Scenario E).
export function recencyPenalty(msSinceSeen, engaged, cfg = DEFAULT_CONFIG) {
  if (msSinceSeen == null || !isFinite(msSinceSeen)) return 0; // never seen
  if (msSinceSeen < 0) msSinceSeen = 0;
  if (msSinceSeen < cfg.recency.hardBlockMs) return 1; // just watched — block
  const halfLife = engaged ? cfg.recency.halfLifeEngagedMs : cfg.recency.halfLifeDefaultMs;
  // Exponential decay from ~1 toward 0 as time passes.
  return clamp01(Math.pow(0.5, msSinceSeen / halfLife));
}

// Dynamic creator separation: never demand more spacing than the catalogue can
// support, so a 2-creator platform still produces a full, non-empty feed.
export function effectiveSeparation(minSeparation, activeCreators) {
  if (!activeCreators || activeCreators < 2) return 0;
  return Math.max(1, Math.min(minSeparation, activeCreators - 1));
}

// Length-aware completion: a fully-watched 10s clip is worth less than a
// fully-watched 60s clip, so short videos can't game completion rate.
function lengthAwareCompletion(avgCompletion, durationSec) {
  const c = clamp01(avgCompletion || 0);
  const d = durationSec > 0 ? durationSec : 15;
  // Reference length 45s: shorter clips get a gentle discount, longer ones full.
  const lengthFactor = clamp01(Math.min(1, 0.5 + 0.5 * Math.min(1, d / 45)));
  return c * lengthFactor;
}

// -------------------------------------------------------------------------
// scoreCandidate — the explainable per-video ranking score.
//
// `cand` (all fields optional / default 0) carries the raw signals:
//   uniqViewers, avgCompletion, avgWatchMs, replays, skips, rawViews,
//   likeCount, commentCount, shareCount, repostCount, followsFromViewers,
//   durationSec, ageMs, creatorFollowers, topics[], creatorId,
//   viewerFollowsCreator (bool), viewerCreatorFamiliarity (0..1),
//   viewerLastSeenMs (ms since viewer last saw THIS video, or null),
//   viewerEngagedThis (bool)
// `profile` = { topics: {topic: score}, followsCreator(id)->bool }
// Returns { base, signals, reasons, buckets }.
// -------------------------------------------------------------------------
export function scoreCandidate(cand, profile, cfg = DEFAULT_CONFIG, nowTs = Date.now()) {
  const w = cfg.weights;
  const reasons = [];

  const uniq = Math.max(0, cand.uniqViewers || 0);
  // Anti-manipulation: cap raw views at a sane multiple of DISTINCT viewers,
  // so an inflated view counter can't buy ranking.
  const cappedViews = Math.min(
    cand.rawViews || 0,
    Math.max(uniq, 1) * cfg.antiManipulation.maxViewsPerViewer
  );
  const denom = Math.max(uniq, 1);

  // --- watch quality: normalized average watch seconds (log-diminishing) ---
  const avgWatchSec = (cand.avgWatchMs || 0) / 1000;
  const watchQuality = uniq > 0 ? squash(avgWatchSec, 12) : 0.4; // neutral prior when unproven

  // --- completion (length-aware) ---
  const completion = uniq > 0
    ? lengthAwareCompletion(cand.avgCompletion, cand.durationSec)
    : 0.4;

  // --- rewatch / share / comment / like — engagement PER unique viewer ---
  const rewatch = squash((cand.replays || 0) / denom, 0.5);
  const share   = squash((cand.shareCount || 0) / denom, 0.15);
  const comment = squash((cand.commentCount || 0) / denom, 0.4);
  const like    = squash((cand.likeCount || 0) / denom, 0.6);
  const followCreator = squash((cand.followsFromViewers || 0) / denom, 0.1);

  // --- personalization: topic affinity + follow + prior creator affinity ---
  let topicMatch = 0;
  if (profile && profile.topics) {
    for (const t of cand.topics || []) {
      if (profile.topics[t]) topicMatch += profile.topics[t];
    }
  }
  topicMatch = clamp01(topicMatch);
  const followBonus = cand.viewerFollowsCreator ? 1 : 0;
  const familiarity = clamp01(cand.viewerCreatorFamiliarity || 0);
  const personalization = clamp01(0.6 * topicMatch + 0.3 * followBonus + 0.1 * familiarity);

  // --- freshness: age decay, but new videos are NOT buried ---
  const ageMs = cand.ageMs != null ? cand.ageMs : (nowTs - (cand.createdAt || nowTs));
  const freshness = clamp01(Math.pow(0.5, Math.max(0, ageMs) / cfg.freshness.halfLifeMs));

  // --- creator discovery bonus: rewards under-exposed / small creators, but
  //     GATED by measured quality once any data exists (no blind promotion) ---
  const smallCreator = (cand.creatorFollowers || 0) <= cfg.smallCreator.followerCeiling ? 1 : 0;
  const unfamiliar = 1 - familiarity; // viewer rarely/never watched this creator
  const qualityGate = uniq > 0 ? clamp01(0.5 * completion + 0.5 * watchQuality) : 1; // untested => full chance
  const creatorDiscovery = clamp01((0.6 * smallCreator + 0.4 * unfamiliar) * qualityGate);

  // Weighted sum.
  let base =
    w.watchQuality * watchQuality +
    w.completion * completion +
    w.rewatch * rewatch +
    w.share * share +
    w.comment * comment +
    w.followCreator * followCreator +
    w.like * like +
    w.personalization * personalization +
    w.freshness * freshness +
    w.creatorDiscovery * creatorDiscovery;

  // --- cold start: give unproven videos a real test-audience lift ---
  let coldStart = 0;
  if (uniq < cfg.coldStart.testAudience) {
    coldStart = cfg.coldStart.boost * (1 - uniq / cfg.coldStart.testAudience);
    base += coldStart;
  }

  // --- small-creator boost (quality-gated) ---
  if (smallCreator && qualityGate > 0.35) {
    base += cfg.smallCreator.bonus * qualityGate;
  }

  // --- negative signals (viewer-specific): they skipped or hid this before ---
  if (cand.viewerSkips > 0) base *= Math.pow(0.7, Math.min(cand.viewerSkips, 3));
  if (cand.viewerNotInterested) base *= 0.15;

  // ---- explainability: why did this surface? ----
  if (personalization > 0.5 && topicMatch > 0.3) reasons.push("Matches topics you watch");
  if (cand.viewerFollowsCreator) reasons.push("From a creator you follow");
  if (completion > 0.6 && uniq > 0) reasons.push("Similar viewers watched it to the end");
  if (freshness > 0.6) reasons.push("Fresh upload");
  if (coldStart > 0.05) reasons.push("New video getting its first audience");
  if (smallCreator && creatorDiscovery > 0.3) reasons.push("Discovering a small creator");
  if (share > 0.3) reasons.push("People are sharing it");
  if (reasons.length === 0) reasons.push("Adding variety to your feed");

  const signals = {
    watchQuality, completion, rewatch, share, comment, like, followCreator,
    personalization, freshness, creatorDiscovery, coldStart,
    topicMatch, smallCreator: !!smallCreator, unfamiliar,
    effectiveViews: cappedViews, uniqViewers: uniq,
  };

  return { base: Math.max(0, base), signals, reasons, buckets: classifyBucket(cand, signals, cfg) };
}

// Classify a candidate into the composition buckets it QUALIFIES for. A
// candidate can qualify for several; the re-ranker fills quotas from these.
export function classifyBucket(cand, signals, cfg = DEFAULT_CONFIG) {
  const buckets = new Set();
  const familiarity = clamp01(cand.viewerCreatorFamiliarity || 0);

  if (signals.personalization > 0.45 || cand.viewerFollowsCreator) buckets.add("personalized");
  // Discovery: creators the viewer never/rarely watches (esp. small/new).
  if (familiarity < 0.2 || signals.coldStart > 0.05) buckets.add("discovery");
  // Trending: strong global engagement right now.
  const trendingScore = 0.5 * signals.share + 0.3 * signals.completion + 0.2 * signals.like;
  if (trendingScore > 0.4 && signals.uniqViewers >= 3) buckets.add("trending");
  // Exploration: low topic overlap with the profile (anti-bubble).
  if (signals.topicMatch < 0.15) buckets.add("exploration");

  // Everything is at least exploration-eligible so quotas can always be met.
  if (buckets.size === 0) buckets.add("exploration");
  return [...buckets];
}

// -------------------------------------------------------------------------
// reRank — turns scored candidates into the final ordered feed, applying
// creator cooldown, video-recency penalty, topic diversity, bucket quotas and
// seeded exploration. Recomputes context after EVERY pick (Session Diversity,
// requirement #13) so simple top-score clustering can't happen.
//
// `scored` = [{ id, creatorId, topics[], base, signals, buckets[], reasons[],
//               viewerLastSeenMs, viewerEngagedThis }]
// `ctx` = { activeCreators, seed, limit }
// Returns ordered [{ ...candidate, finalScore, reasons }].
// -------------------------------------------------------------------------
export function reRank(scored, cfg = DEFAULT_CONFIG, ctx = {}) {
  const limit = ctx.limit || scored.length;
  const rng = mulberry32((ctx.seed || 1) >>> 0);
  const sep = effectiveSeparation(cfg.creatorCooldown.minSeparation, ctx.activeCreators || countCreators(scored));
  const topicSep = cfg.topicDiversity.minSeparation;

  const targets = bucketTargets(cfg.composition, limit);
  const placedBucket = { personalized: 0, discovery: 0, trending: 0, exploration: 0 };

  const remaining = scored.slice();
  const out = [];
  const creatorPos = new Map(); // creatorId -> last placed position
  const creatorCount = new Map(); // creatorId -> times placed
  const topicPos = new Map(); // topic -> last placed position

  for (let pos = 0; pos < limit && remaining.length; pos++) {
    let bestIdx = -1;
    let bestScore = -Infinity;

    for (let i = 0; i < remaining.length; i++) {
      const c = remaining[i];
      let s = c.base;

      // Video-recency penalty (viewer already saw THIS video recently).
      const rp = recencyPenalty(c.viewerLastSeenMs, c.viewerEngagedThis, cfg);
      s *= (1 - rp);

      // Creator cooldown — multiplicative, dynamic, graceful.
      const lastCPos = creatorPos.get(c.creatorId);
      if (lastCPos != null && pos - lastCPos <= sep) {
        s *= cfg.creatorCooldown.penalty;
      }
      const priorC = creatorCount.get(c.creatorId) || 0;
      if (priorC > 0) s *= Math.pow(1 - cfg.creatorCooldown.perPriorPenalty, priorC);

      // Topic diversity — mild, avoids same-topic runs.
      for (const t of c.topics || []) {
        const lastTPos = topicPos.get(t);
        if (lastTPos != null && pos - lastTPos < topicSep) { s *= cfg.topicDiversity.penalty; break; }
      }

      // Bucket quota steering: boost under-filled buckets, damp overfull ones.
      s *= bucketMultiplier(c.buckets, placedBucket, targets);

      // Seeded exploration jitter — keeps the feed fresh each open.
      s *= 1 + cfg.exploration.epsilon * (rng() - 0.5) * 2;

      if (s > bestScore) { bestScore = s; bestIdx = i; }
    }

    if (bestIdx < 0) break;
    const chosen = remaining.splice(bestIdx, 1)[0];
    chosen.finalScore = bestScore;
    // Attribute the slot to the highest-priority bucket it still helps fill.
    const slotBucket = pickSlotBucket(chosen.buckets, placedBucket, targets);
    placedBucket[slotBucket] = (placedBucket[slotBucket] || 0) + 1;
    chosen.slotBucket = slotBucket;
    creatorPos.set(chosen.creatorId, pos);
    creatorCount.set(chosen.creatorId, (creatorCount.get(chosen.creatorId) || 0) + 1);
    for (const t of chosen.topics || []) topicPos.set(t, pos);
    out.push(chosen);
  }

  return out;
}

function countCreators(scored) {
  return new Set(scored.map((c) => c.creatorId)).size;
}

function bucketTargets(composition, limit) {
  return {
    personalized: Math.round((composition.personalized || 0) * limit),
    discovery:    Math.round((composition.discovery || 0) * limit),
    trending:     Math.round((composition.trending || 0) * limit),
    exploration:  Math.round((composition.exploration || 0) * limit),
  };
}

// Multiplier that nudges selection toward buckets still below their target and
// away from buckets already at/over target. Uses the candidate's best-fitting
// eligible bucket.
function bucketMultiplier(buckets, placed, targets) {
  let best = 0.85; // default slight damp for uncategorized fit
  for (const b of buckets) {
    const t = targets[b] || 0;
    const p = placed[b] || 0;
    const need = t > 0 ? (t - p) / t : 0; // 1 => empty, <=0 => full
    const m = need > 0 ? 1 + 0.6 * need : 0.5; // reward need, damp overfull
    if (m > best) best = m;
  }
  return best;
}

function pickSlotBucket(buckets, placed, targets) {
  let bestB = buckets[0] || "exploration";
  let bestNeed = -Infinity;
  for (const b of buckets) {
    const t = targets[b] || 0;
    const p = placed[b] || 0;
    const need = t > 0 ? (t - p) / t : -1;
    if (need > bestNeed) { bestNeed = need; bestB = b; }
  }
  return bestB;
}

// ===========================================================================
// DB-backed services (Cloudflare D1)
// ===========================================================================

// Loads the merged runtime config (defaults + reco_config JSON override).
export async function loadConfig(env) {
  try {
    const row = await env.DB.prepare("SELECT json FROM reco_config WHERE id = 1").first();
    if (row && row.json) return mergeConfig(JSON.parse(row.json));
  } catch (_) { /* table may not exist yet — fall back to defaults */ }
  return structuredCloneSafe(DEFAULT_CONFIG);
}

// The candidate-generation SQL. Pulls eligible videos with all display columns
// (so index.js's shapeVideo works unchanged) PLUS the extra signals Belo Flow
// needs: DISTINCT-viewer aggregates (manipulation-resistant), the viewer's own
// exposure row (recency/negative signals), creator familiarity and follower
// count. `?` binds, in order: [viewerId x many] — see buildBeloFeed.
function candidateSql(cfg) {
  return `
  SELECT
    v.id, v.caption, v.song, v.r2_key, v.thumb_key, v.width, v.height,
    v.duration, v.views, v.created_at, v.repost_of, v.sound_id,
    u.id AS user_id, u.username, u.display_name, u.avatar_key, u.interests AS creator_interests,
    ru.id AS repost_of_user_id, ru.username AS repost_of_username,
    ru.display_name AS repost_of_display_name, ru.avatar_key AS repost_of_avatar_key,
    (SELECT COUNT(*) FROM likes    l WHERE l.video_id = COALESCE(v.repost_of, v.id)) AS like_count,
    (SELECT COUNT(*) FROM comments c WHERE c.video_id = COALESCE(v.repost_of, v.id)) AS comment_count,
    (SELECT COUNT(*) FROM shares   s WHERE s.video_id = COALESCE(v.repost_of, v.id) AND s.completed = 1) AS share_count,
    (SELECT COUNT(*) FROM videos   r WHERE r.repost_of = COALESCE(v.repost_of, v.id)) AS repost_count,
    (SELECT COALESCE(SUM(g.coins), 0) FROM gifts g WHERE g.video_id = COALESCE(v.repost_of, v.id)) AS gift_coins,
    EXISTS(SELECT 1 FROM likes l WHERE l.video_id = COALESCE(v.repost_of, v.id) AND l.user_id = ?) AS liked,
    EXISTS(SELECT 1 FROM follows f
            WHERE f.follower_id = ? AND f.followee_id = COALESCE(ru.id, u.id)
              AND f.status = 'accepted') AS following,
    -- Global, manipulation-resistant signals (distinct viewers etc.)
    (SELECT COUNT(*)        FROM video_exposures e WHERE e.video_id = v.id) AS uniq_viewers,
    (SELECT AVG(e.completion) FROM video_exposures e WHERE e.video_id = v.id) AS avg_completion,
    (SELECT AVG(e.watch_ms)   FROM video_exposures e WHERE e.video_id = v.id) AS avg_watch_ms,
    (SELECT COALESCE(SUM(e.replay_count),0) FROM video_exposures e WHERE e.video_id = v.id) AS replays,
    (SELECT COALESCE(SUM(e.skipped),0)      FROM video_exposures e WHERE e.video_id = v.id) AS skips,
    (SELECT COALESCE(SUM(e.followed_creator),0) FROM video_exposures e WHERE e.video_id = v.id) AS follows_from_viewers,
    -- Creator follower count (for the small-creator boost).
    (SELECT COUNT(*) FROM follows cf WHERE cf.followee_id = COALESCE(ru.id, u.id) AND cf.status = 'accepted') AS creator_followers,
    -- The viewer's OWN history with this exact video (recency / negative).
    me.last_seen_at AS my_last_seen, me.completion AS my_completion,
    me.liked AS my_liked, me.shared AS my_shared, me.replay_count AS my_replays,
    me.followed_creator AS my_followed, me.skipped AS my_skips, me.not_interested AS my_not_interested,
    -- How familiar the viewer is with this creator (how much they've watched).
    (SELECT COUNT(*) FROM video_exposures ce WHERE ce.user_id = ? AND ce.creator_id = COALESCE(ru.id, u.id)) AS creator_seen_count,
    (SELECT MAX(ce.last_seen_at) FROM video_exposures ce WHERE ce.user_id = ? AND ce.creator_id = COALESCE(ru.id, u.id)) AS creator_last_seen
  FROM videos v
  JOIN users u ON u.id = v.user_id
  LEFT JOIN videos rv ON rv.id = v.repost_of
  LEFT JOIN users ru ON ru.id = rv.user_id
  LEFT JOIN video_exposures me ON me.video_id = v.id AND me.user_id = ?
  WHERE u.status != 'banned'
    AND (
      v.user_id = ?
      OR (v.visibility = 'public' AND u.is_private = 0)
      OR ((v.visibility = 'followers' OR u.is_private = 1) AND v.visibility != 'private' AND EXISTS(
            SELECT 1 FROM follows f WHERE f.follower_id = ? AND f.followee_id = v.user_id AND f.status = 'accepted'))
    )
  ORDER BY v.created_at DESC
  LIMIT ${Number(cfg.candidatePool) || 400}
  `;
}

// Loads the viewer's behavioural interest profile (topic -> decayed score) plus
// their declared interests, merged. Empty for anonymous / brand-new users, in
// which case the engine leans on freshness + diversity + exploration.
export async function loadUserProfile(env, viewerId, cfg = DEFAULT_CONFIG, nowTs = Date.now()) {
  const topics = {};
  if (!viewerId) return { topics };

  try {
    const { results } = await env.DB.prepare(
      "SELECT topic, score, updated_at FROM user_topics WHERE user_id = ?"
    ).bind(viewerId).all();
    for (const r of results || []) {
      // Lazy time-decay so stale interests fade without a cron job.
      const age = Math.max(0, nowTs - (r.updated_at || nowTs));
      const decayed = r.score * Math.pow(0.5, age / cfg.interests.halfLifeMs);
      if (decayed > 0.02) topics[r.topic] = clamp01(decayed);
    }
  } catch (_) { /* table may not exist yet */ }

  // Fold in declared interests as a soft prior if behaviour is thin.
  try {
    const u = await env.DB.prepare("SELECT interests FROM users WHERE id = ?").bind(viewerId).first();
    if (u && u.interests) {
      for (const raw of String(u.interests).split(/[,;]/)) {
        const t = raw.toLowerCase().trim().replace(/\s+/g, "_");
        if (t) topics[t] = Math.max(topics[t] || 0, 0.4);
      }
    }
  } catch (_) {}

  return { topics };
}

// Builds the ordered Belo feed. Returns { rows, reasons, nextOffset, total },
// where rows are raw DB rows (shapeVideo-compatible) in final order, each
// carrying `recoReason` and `recoBucket`. index.js maps + interleaves ads.
export async function buildBeloFeed(env, { viewerId = "", limit = 15, cursor, seed } = {}) {
  const cfg = await loadConfig(env);
  const nowTs = Date.now();
  const offset = cursor ? Math.max(0, parseInt(cursor, 10) || 0) : 0;

  const vid = viewerId || "";
  const sql = candidateSql(cfg);
  // Bind order mirrors the `?`s in candidateSql.
  const binds = [
    vid, // liked
    vid, // following
    vid, // creator_seen_count
    vid, // creator_last_seen
    vid, // me join
    vid, // v.user_id = ? (own videos)
    vid, // followers-only EXISTS
  ];

  let results = [];
  try {
    ({ results } = await env.DB.prepare(sql).bind(...binds).all());
  } catch (e) {
    // If the tracking tables aren't migrated yet, fail soft: caller falls back.
    throw e;
  }

  const profile = await loadUserProfile(env, vid, cfg, nowTs);

  // Score every candidate.
  const scored = (results || []).map((r) => {
    const creatorId = r.repost_of_user_id || r.user_id;
    const durationSec = r.duration || 0;
    const seenCount = r.creator_seen_count || 0;
    // Familiarity saturates after ~5 watched videos from the creator.
    const familiarity = clamp01(seenCount / 5);
    const declared = safeInterests(r.creator_interests);
    const topics = extractTopics(r.caption, declared);

    const cand = {
      uniqViewers: r.uniq_viewers || 0,
      avgCompletion: r.avg_completion || 0,
      avgWatchMs: r.avg_watch_ms || 0,
      replays: r.replays || 0,
      skips: r.skips || 0,
      rawViews: r.views || 0,
      likeCount: r.like_count || 0,
      commentCount: r.comment_count || 0,
      shareCount: r.share_count || 0,
      repostCount: r.repost_count || 0,
      followsFromViewers: r.follows_from_viewers || 0,
      durationSec,
      createdAt: r.created_at,
      ageMs: nowTs - (r.created_at || nowTs),
      creatorFollowers: r.creator_followers || 0,
      creatorId,
      topics,
      viewerFollowsCreator: !!r.following,
      viewerCreatorFamiliarity: familiarity,
      viewerLastSeenMs: r.my_last_seen != null ? nowTs - r.my_last_seen : null,
      viewerEngagedThis: !!(r.my_liked || r.my_shared || r.my_followed || (r.my_completion || 0) > 0.8 || (r.my_replays || 0) > 0),
      viewerSkips: r.my_skips || 0,
      viewerNotInterested: !!r.my_not_interested,
    };

    const sc = scoreCandidate(cand, profile, cfg, nowTs);
    return {
      row: r,
      id: r.id,
      creatorId,
      topics,
      base: sc.base,
      signals: sc.signals,
      buckets: sc.buckets,
      reasons: sc.reasons,
      viewerLastSeenMs: cand.viewerLastSeenMs,
      viewerEngagedThis: cand.viewerEngagedThis,
    };
  });

  const activeCreators = new Set(scored.map((c) => c.creatorId)).size;
  // Seed: stable within a viewer's ~30-min session (fresh next open), and
  // stable across pages of the same session so pagination stays coherent.
  const sessionSeed = seed != null
    ? hashSeed(String(seed))
    : hashSeed(`${vid}:${Math.floor(nowTs / (30 * 60 * 1000))}`);

  // Re-rank the WHOLE pool once, deterministically, then page by slicing —
  // so page 2 continues the same diverse ordering instead of re-clustering.
  const ordered = reRank(scored, cfg, {
    activeCreators,
    seed: sessionSeed,
    limit: scored.length,
  });

  const pageItems = ordered.slice(offset, offset + limit);
  const rows = pageItems.map((c) => {
    c.row.recoReason = c.reasons;
    c.row.recoBucket = c.slotBucket;
    return c.row;
  });

  const hasMore = offset + limit < ordered.length;
  return { rows, nextOffset: hasMore ? offset + limit : null, total: ordered.length };
}

function safeInterests(raw) {
  if (!raw) return [];
  try {
    const v = JSON.parse(raw);
    if (Array.isArray(v)) return v;
  } catch (_) {}
  return String(raw).split(/[,;]/).map((s) => s.trim()).filter(Boolean);
}

// ---------------------------------------------------------------------------
// Exposure recording ("I just saw this" memory) + interest learning.
// Called from POST /api/videos/:id/view. Upserts the per-(user,video) row and
// nudges the behavioural interest profile from real watch behaviour.
// ---------------------------------------------------------------------------
export async function recordExposure(env, {
  viewerId, videoId, creatorId, caption = "", declaredInterests = [],
  watchMs = 0, durationMs = 0, completed = false, replayed = false, skipped = false,
  notInterested = false,
} = {}, nowTs = Date.now()) {
  if (!viewerId || !videoId) return;
  const completion = durationMs > 0 ? Math.min(1, watchMs / durationMs) : (completed ? 1 : 0);
  const isReplay = replayed ? 1 : 0;
  const isSkip = skipped ? 1 : 0;
  const notInt = notInterested ? 1 : 0;

  await env.DB.prepare(`
    INSERT INTO video_exposures
      (user_id, video_id, creator_id, first_seen_at, last_seen_at, watch_ms,
       total_watch_ms, duration_ms, completion, watch_count, replay_count,
       skipped, not_interested)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?, ?)
    ON CONFLICT(user_id, video_id) DO UPDATE SET
      last_seen_at   = excluded.last_seen_at,
      watch_ms       = MAX(video_exposures.watch_ms, excluded.watch_ms),
      total_watch_ms = video_exposures.total_watch_ms + excluded.watch_ms,
      duration_ms    = MAX(video_exposures.duration_ms, excluded.duration_ms),
      completion     = MAX(video_exposures.completion, excluded.completion),
      watch_count    = video_exposures.watch_count + 1,
      replay_count   = video_exposures.replay_count + ?,
      skipped        = video_exposures.skipped + ?,
      not_interested = MAX(video_exposures.not_interested, ?)
  `).bind(
    viewerId, videoId, creatorId || "", nowTs, nowTs, watchMs,
    watchMs, durationMs, completion, isReplay, isSkip, notInt,
    isReplay, isSkip, notInt
  ).run();

  // Learn interests from behaviour. Positive when watched well / replayed;
  // negative on an early swipe or "not interested".
  const topics = extractTopics(caption, declaredInterests);
  if (topics.length) {
    let delta = 0;
    if (notInterested) delta = -0.4;
    else if (isSkip && completion < 0.2) delta = -0.15;
    else delta = -0.05 + 0.5 * completion + (isReplay ? 0.2 : 0); // -0.05..~0.7
    if (Math.abs(delta) > 0.001) {
      await updateInterests(env, viewerId, topics, delta, nowTs, env.__reco_cfg || DEFAULT_CONFIG);
    }
  }
}

// Bumps the viewer's affinity for a set of topics by `delta` (can be negative),
// applying lazy time-decay to the existing score. Scores are clamped to 0..1.
export async function updateInterests(env, viewerId, topics, delta, nowTs = Date.now(), cfg = DEFAULT_CONFIG) {
  if (!viewerId || !topics || !topics.length) return;
  for (const topic of topics) {
    const existing = await env.DB.prepare(
      "SELECT score, updated_at FROM user_topics WHERE user_id = ? AND topic = ?"
    ).bind(viewerId, topic).first();
    let score = 0;
    if (existing) {
      const age = Math.max(0, nowTs - (existing.updated_at || nowTs));
      score = existing.score * Math.pow(0.5, age / cfg.interests.halfLifeMs);
    }
    score = clamp01(score + delta);
    await env.DB.prepare(`
      INSERT INTO user_topics (user_id, topic, score, updated_at)
      VALUES (?, ?, ?, ?)
      ON CONFLICT(user_id, topic) DO UPDATE SET score = ?, updated_at = ?
    `).bind(viewerId, topic, score, nowTs, score, nowTs).run();
  }
}
