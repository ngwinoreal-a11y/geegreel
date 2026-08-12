-- ============================================================================
-- Targeting: a video's own category, and the countries it (or an ad) is aimed at.
--
-- Belo Flow already learns topics from captions and hashtags, which works but
-- guesses. A creator picking a category states it outright, and the same list
-- people choose their interests from at signup is used here — so "Music" on a
-- video and "Music" in a viewer's interests are the same token and can be
-- matched directly instead of inferred.
--
-- Countries are stored as a JSON array of names, empty/NULL meaning "everywhere".
-- Names, not codes, because that's what signup already stores in users.country;
-- a code would need a mapping table on both sides to compare the two.
-- Idempotent-ish: SQLite has no ADD COLUMN IF NOT EXISTS, so re-running errors
-- harmlessly ("duplicate column name") rather than changing anything.
-- ============================================================================

-- One category per video, drawn from the signup interest list.
ALTER TABLE videos ADD COLUMN category TEXT;

-- Up to 3 country names, JSON array. NULL/'[]' = shown everywhere.
ALTER TABLE videos ADD COLUMN countries TEXT;

-- Same for ads, for both the self-serve and admin flows.
ALTER TABLE ads ADD COLUMN countries TEXT;

-- Category lookups when scoring candidates for a viewer's interests.
CREATE INDEX IF NOT EXISTS idx_videos_category ON videos(category);
