-- What each person has already been shown on Public.
--
-- Public served strictly newest-first, so pulling to refresh returned the same
-- fifteen posts it had just returned. The refresh worked — it really did go and
-- ask — and looked broken, because the answer never changed.
--
-- With this, the feed can show what you have NOT seen before anything you have,
-- which is what makes a refresh produce something.
--
-- Run with:
--   npx wrangler d1 execute video-app-db --remote --file=migrations/009_post_exposures.sql

CREATE TABLE IF NOT EXISTS post_exposures (
  user_id TEXT NOT NULL REFERENCES users(id),
  post_id TEXT NOT NULL REFERENCES posts(id),
  -- When it was last put in front of them. Used to decide what comes back
  -- FIRST once everything has been seen: the thing you saw longest ago.
  seen_at INTEGER NOT NULL,
  PRIMARY KEY (user_id, post_id)
);

-- The two reads: "have I seen this" and "what did I see longest ago".
CREATE INDEX IF NOT EXISTS idx_post_exposures_recent
  ON post_exposures (user_id, seen_at);
