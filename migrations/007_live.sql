-- Live streaming. Belople owns the session; Mux is only the video pipe, and
-- every column that names Mux is a foreign id we can drop if the provider ever
-- changes.
--
-- Run with:
--   npx wrangler d1 execute video-app-db --remote --file=migrations/007_live.sql

CREATE TABLE IF NOT EXISTS live_sessions (
  id TEXT PRIMARY KEY,
  creator_id TEXT NOT NULL REFERENCES users(id),
  title TEXT,

  -- starting → live → ending → ended, or failed. 'starting' is the window
  -- between creating the Mux stream and the encoder actually connecting; a
  -- session that never leaves it is an abandoned one and gets swept.
  status TEXT NOT NULL DEFAULT 'starting',

  -- Mux's ids. mux_playback_id is the LIVE stream's own playback id, which is
  -- what holds a viewer to the live edge. The ASSET's playback id is the DVR
  -- one and must never be handed out — that is the replay we are not building.
  mux_live_stream_id TEXT,
  mux_playback_id TEXT,
  -- The recording Mux creates whether we want it or not: every RTMP session
  -- makes an asset, and there is no setting that turns it off. Kept only so
  -- cleanup knows what to delete, and nulled once it is gone.
  mux_asset_id TEXT,
  -- Set when the asset has actually been deleted, so cleanup can run twice
  -- without a second DELETE to Mux and without treating an already-clean
  -- session as unfinished.
  cleaned_at INTEGER,

  started_at INTEGER,
  ended_at INTEGER,
  -- Rough, and deliberately so: written from an aggregate, not a row per
  -- heartbeat.
  viewer_count INTEGER NOT NULL DEFAULT 0,
  peak_viewer_count INTEGER NOT NULL DEFAULT 0,

  -- Why it ended, for the cost log: 'creator' | 'max_duration' | 'abandoned'
  -- | 'error'. An unexplained end is how a bill becomes a mystery.
  end_reason TEXT,

  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- Discovery reads exactly one shape: the live ones, newest first.
CREATE INDEX IF NOT EXISTS idx_live_active
  ON live_sessions (status, started_at DESC);
-- The sweeper reads the other: anything still open past its limit.
CREATE INDEX IF NOT EXISTS idx_live_open
  ON live_sessions (status, updated_at);
-- Cleanup looks for sessions that ended but still own a Mux asset.
CREATE INDEX IF NOT EXISTS idx_live_uncleaned
  ON live_sessions (cleaned_at, mux_asset_id);
CREATE INDEX IF NOT EXISTS idx_live_creator
  ON live_sessions (creator_id, created_at DESC);

-- Live comments are NOT the `comments` table: that one hangs off videos(id)
-- and a live session is not a video. They also die with the session — nobody
-- reads them back, so they carry no thread, no replies and no reactions.
CREATE TABLE IF NOT EXISTS live_comments (
  id TEXT PRIMARY KEY,
  live_session_id TEXT NOT NULL REFERENCES live_sessions(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  body TEXT NOT NULL,
  -- 'comment' is what a person typed. 'join' and 'like' are the system lines
  -- that share the same rising stream on screen, so they share the table and
  -- come back in one query instead of three.
  kind TEXT NOT NULL DEFAULT 'comment',
  created_at INTEGER NOT NULL
);

-- The only read: everything in this session newer than what I already have.
CREATE INDEX IF NOT EXISTS idx_live_comments_poll
  ON live_comments (live_session_id, created_at);

-- Who is watching right now. One row per viewer per session, REPLACEd rather
-- than appended, so the table stays the size of the audience and not the size
-- of the broadcast.
--
-- The spec says not to write to the database on every heartbeat. This is the
-- compromise it asks for instead: viewers already poll for comments every few
-- seconds, and presence rides on that poll but is only WRITTEN every 15s
-- (LIVE_PRESENCE_WRITE_MS), so a 300-person audience costs about 20 small
-- upserts a second rather than one per poll per person. The count itself is
-- never computed per request either — it is cached onto
-- live_sessions.viewer_count at most once every 10s.
--
-- If this ever becomes the bottleneck the upgrade is KV or a Durable Object;
-- neither is worth adding before there is an audience to need it.
CREATE TABLE IF NOT EXISTS live_viewers (
  live_session_id TEXT NOT NULL REFERENCES live_sessions(id),
  user_id TEXT NOT NULL REFERENCES users(id),
  last_seen INTEGER NOT NULL,
  PRIMARY KEY (live_session_id, user_id)
);

-- Counting the audience: everyone in this session seen recently.
CREATE INDEX IF NOT EXISTS idx_live_viewers_recent
  ON live_viewers (live_session_id, last_seen);
