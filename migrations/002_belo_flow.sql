-- ============================================================================
-- Belo Flow — Belople's own recommendation engine.
-- Adds the tracking tables the engine needs. Nothing here rewrites existing
-- data: videos.views stays as the raw counter; scoring reads DISTINCT viewers
-- from video_exposures instead, so inflated raw views can't dominate ranking.
-- Idempotent (IF NOT EXISTS) so it's safe to re-run.
-- ============================================================================

-- The "I just saw this" memory + per-(user,video) watch history. One row per
-- viewer per video, upserted on every view. This powers both the video-recency
-- penalty (don't re-show what you just watched) and the global per-video
-- quality signals (AVG completion, DISTINCT viewers) used for ranking.
CREATE TABLE IF NOT EXISTS video_exposures (
  user_id          TEXT    NOT NULL,
  video_id         TEXT    NOT NULL,
  creator_id       TEXT    NOT NULL,          -- original creator (repost-aware)
  first_seen_at    INTEGER NOT NULL,
  last_seen_at     INTEGER NOT NULL,
  watch_ms         INTEGER NOT NULL DEFAULT 0, -- best single watch (ms)
  total_watch_ms   INTEGER NOT NULL DEFAULT 0, -- summed across replays (ms)
  duration_ms      INTEGER NOT NULL DEFAULT 0, -- the video's length when seen
  completion       REAL    NOT NULL DEFAULT 0, -- best completion, 0..1
  watch_count      INTEGER NOT NULL DEFAULT 0,
  replay_count     INTEGER NOT NULL DEFAULT 0,
  liked            INTEGER NOT NULL DEFAULT 0,
  commented        INTEGER NOT NULL DEFAULT 0,
  shared           INTEGER NOT NULL DEFAULT 0,
  followed_creator INTEGER NOT NULL DEFAULT 0,
  skipped          INTEGER NOT NULL DEFAULT 0, -- early-swipe count
  not_interested   INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, video_id)
);

-- Recency penalty & "don't repeat" lookups: newest exposures for a viewer.
CREATE INDEX IF NOT EXISTS idx_exposure_user_seen
  ON video_exposures(user_id, last_seen_at);

-- Creator-level recent-exposure lookups (how recently/often a viewer has seen
-- a given creator) — drives the creator cooldown across sessions.
CREATE INDEX IF NOT EXISTS idx_exposure_user_creator
  ON video_exposures(user_id, creator_id, last_seen_at);

-- Per-video aggregates (DISTINCT viewers, AVG completion) for candidate scoring.
CREATE INDEX IF NOT EXISTS idx_exposure_video
  ON video_exposures(video_id);

-- ----------------------------------------------------------------------------
-- Behavioural interest profile: per-user topic affinity, learned from actual
-- watch behaviour and decayed over time so tastes can evolve. Topics come from
-- caption hashtags and declared interests (see extractTopics in belo_flow.js).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS user_topics (
  user_id    TEXT    NOT NULL,
  topic      TEXT    NOT NULL,
  score      REAL    NOT NULL DEFAULT 0,   -- affinity, ~0..1 after normalise
  updated_at INTEGER NOT NULL,             -- last touch, for time decay
  PRIMARY KEY (user_id, topic)
);
CREATE INDEX IF NOT EXISTS idx_user_topics ON user_topics(user_id, score);

-- ----------------------------------------------------------------------------
-- Runtime-tunable configuration. A single JSON row holds weights, the feed
-- composition (60/20/10/10), cooldowns and half-lives so they can be adjusted
-- in production without a redeploy. Missing row => code defaults (DEFAULT_CONFIG).
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS reco_config (
  id         INTEGER PRIMARY KEY CHECK (id = 1),
  json       TEXT    NOT NULL,
  updated_at INTEGER NOT NULL
);
