-- Gifts sent during a live.
--
-- The gifts table already exists and already carries the money rules — the
-- creator's share, the earnings record, the wallet ledger. A live gift is the
-- same transaction pointed at a session instead of a video, so it reuses the
-- table rather than starting a second one where those rules would have to be
-- written out again and could drift.
--
-- Run with:
--   npx wrangler d1 execute video-app-db --remote --file=migrations/008_live_gifts.sql

ALTER TABLE gifts ADD COLUMN live_session_id TEXT REFERENCES live_sessions(id);

-- Reading a session's gifts back: who gave what, newest first.
CREATE INDEX IF NOT EXISTS idx_gifts_live
  ON gifts (live_session_id, created_at DESC);
