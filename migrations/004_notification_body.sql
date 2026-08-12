-- ============================================================================
-- Notifications need somewhere to keep their own text.
--
-- Every other notification type derives its wording from the actor and the
-- thing acted on ("X liked your video"), so the table never needed a body.
-- An admin announcement has no such thing to derive from — its text IS the
-- notification. It was being sent in the push and then thrown away, so the
-- Activity list showed a row with nothing in it.
-- Idempotent guard: SQLite has no ADD COLUMN IF NOT EXISTS, so re-running this
-- errors harmlessly ("duplicate column name") rather than corrupting anything.
-- ============================================================================

ALTER TABLE notifications ADD COLUMN body TEXT;
