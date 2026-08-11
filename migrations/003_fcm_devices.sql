-- ============================================================================
-- FCM device tokens — push notifications for the native app.
--
-- Separate from push_subscriptions, which holds W3C Web Push endpoints for the
-- browser (VAPID + aes128gcm). A native Android install can only be reached
-- through FCM, so it needs its own registration table; a user can legitimately
-- have both (web on a laptop, app on a phone) and should be notified on each.
-- Idempotent (IF NOT EXISTS) so it's safe to re-run.
-- ============================================================================

CREATE TABLE IF NOT EXISTS fcm_devices (
  token      TEXT PRIMARY KEY,          -- the FCM registration token
  user_id    TEXT    NOT NULL,
  platform   TEXT    NOT NULL DEFAULT 'android',
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- The only lookup that matters at send time: every device for one recipient.
CREATE INDEX IF NOT EXISTS idx_fcm_devices_user ON fcm_devices(user_id);
