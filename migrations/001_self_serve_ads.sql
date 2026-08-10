-- Self-serve ads (Phase 2). Run against the D1 database before deploying the
-- Worker changes:
--   npx wrangler d1 execute video-app-db --remote --file=migrations/001_self_serve_ads.sql
--
-- Extends the existing `ads` table (admin ads keep working unchanged: they are
-- kind='admin', already 'active') and adds a comments table for user ads.

ALTER TABLE ads ADD COLUMN kind TEXT NOT NULL DEFAULT 'admin';       -- 'admin' | 'user'
ALTER TABLE ads ADD COLUMN reach_target INTEGER;                     -- viewers the ad is paid to reach (user ads)
ALTER TABLE ads ADD COLUMN price_cents INTEGER NOT NULL DEFAULT 0;   -- amount charged
ALTER TABLE ads ADD COLUMN paid INTEGER NOT NULL DEFAULT 0;          -- 0 until checkout completes
-- status values: admin ads use 'active'/'paused'; user ads use
-- 'pending' (awaiting payment/review) -> 'active' -> 'complete' (reach hit),
-- or 'rejected'.

CREATE TABLE IF NOT EXISTS ad_comments (
  id         TEXT PRIMARY KEY,
  ad_id      TEXT NOT NULL,
  user_id    TEXT NOT NULL,
  body       TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ad_comments_ad ON ad_comments (ad_id, created_at);
