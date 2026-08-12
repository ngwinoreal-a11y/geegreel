-- ============================================================================
-- Cash-out requests for a user's coin balance.
--
-- The admin dashboard already had a payouts view, but it read the `earnings`
-- table — money the platform owes a monetized creator for views. There was no
-- way for someone to ask for their own COIN balance in cash, which is what
-- gifts land in. So coins could be received and spent but never withdrawn.
--
-- Coins are deducted when the request is made, not when it's paid: otherwise
-- someone could request a payout and spend the same coins before it's
-- processed. A rejected request puts them back.
-- ============================================================================

CREATE TABLE IF NOT EXISTS coin_payouts (
  id             TEXT PRIMARY KEY,
  user_id        TEXT    NOT NULL,
  coins          INTEGER NOT NULL,          -- deducted at request time
  amount_cents   INTEGER NOT NULL,          -- 1 coin = 1 cent
  method         TEXT    NOT NULL,          -- mobile_money | bank | paypal
  details        TEXT    NOT NULL,          -- phone / account, as typed
  status         TEXT    NOT NULL DEFAULT 'pending', -- pending|paid|rejected
  note           TEXT,                      -- admin's reason, on rejection
  created_at     INTEGER NOT NULL,
  reviewed_at    INTEGER,
  reviewed_by    TEXT
);

-- The admin queue reads pending-first; a user reads their own history.
CREATE INDEX IF NOT EXISTS idx_coin_payouts_status ON coin_payouts(status, created_at);
CREATE INDEX IF NOT EXISTS idx_coin_payouts_user ON coin_payouts(user_id, created_at);
